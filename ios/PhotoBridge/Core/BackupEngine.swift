import Foundation
import Photos
import UIKit

struct Problem: Codable, Identifiable, Hashable {
    enum Status: String, Codable { case failed, icloud }
    var id: String { assetId }
    let assetId: String
    let status: Status
    let filename: String
    let created: Date?
    let reason: String
}

struct Summary: Codable, Equatable {
    var total = 0      // 照片／影片項目數
    var files = 0      // 掃描到的原始檔數
    var done = 0       // 所有原始檔都已在電腦上驗證過
    var failed = 0
    var icloud = 0     // 至少一個原始檔只在 iCloud
    var pending: Int { max(0, total - done - failed - icloud) }

    enum CodingKeys: String, CodingKey { case total, files, done, failed, icloud, pending }
    init() {}
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        total = try c.decode(Int.self, forKey: .total); files = try c.decode(Int.self, forKey: .files)
        done = try c.decode(Int.self, forKey: .done); failed = try c.decode(Int.self, forKey: .failed)
        icloud = try c.decode(Int.self, forKey: .icloud)
    }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(total, forKey: .total); try c.encode(files, forKey: .files); try c.encode(done, forKey: .done)
        try c.encode(failed, forKey: .failed); try c.encode(icloud, forKey: .icloud); try c.encode(pending, forKey: .pending)
    }
}

struct LastRun: Codable {
    var summary: Summary
    var problems: [Problem]
    var finishedAt: Date
    var completed: Bool   // false = 中途停止
    var computerName: String
}

@MainActor
final class BackupEngine: ObservableObject {
    enum Phase: Equatable { case idle, connecting, running, stopping, finished, stopped, failed(String) }

    @Published var phase: Phase = .idle
    @Published var summary = Summary()
    @Published var processed = 0           // 已處理完（不論結果）的項目數
    @Published var uploadedFiles = 0       // 這次新傳的檔案
    @Published var skippedFiles = 0        // 電腦上已有、略過
    @Published var bytesSent: Int64 = 0
    @Published var current: String = ""
    @Published var problems: [Problem] = []
    @Published var limitedAccess = false
    @Published var lastRun: LastRun? = LastRunStore.load()

    private var task: Task<Void, Never>?
    private var bgTask: UIBackgroundTaskIdentifier = .invalid
    private let batchSize = 200
    private let concurrency = 2

    var isBusy: Bool { phase == .connecting || phase == .running || phase == .stopping }

    func start(pairing: Pairing) {
        guard !isBusy else { return }
        task = Task { await run(pairing: pairing) }
    }

    func stop() {
        guard isBusy else { return }
        phase = .stopping
        task?.cancel()
    }

    private func run(pairing: Pairing) async {
        phase = .connecting
        summary = Summary(); processed = 0; uploadedFiles = 0; skippedFiles = 0; bytesSent = 0
        problems = []; current = ""

        let status = await PhotoLibrary.authorize()
        guard status == .authorized || status == .limited else {
            phase = .failed("沒有照片存取權限。請到「設定 > 隱私權 > 照片 > 照片備份」選「完整存取」。")
            return
        }
        limitedAccess = status == .limited

        let client = ReceiverClient(pairing: pairing)
        let hello: HelloResponse
        do { hello = try await client.connect() } catch {
            phase = .failed(error.localizedDescription); return
        }
        guard hello.ready else { phase = .failed(ReceiverError.notReady.localizedDescription); return }

        UIApplication.shared.isIdleTimerDisabled = true
        bgTask = UIApplication.shared.beginBackgroundTask(withName: "backup") { [weak self] in
            // 被切到背景太久：停下來，下次從頭檢查補傳
            Task { @MainActor in self?.stop() }
        }
        defer {
            UIApplication.shared.isIdleTimerDisabled = false
            if bgTask != .invalid { UIApplication.shared.endBackgroundTask(bgTask); bgTask = .invalid }
        }

        phase = .running
        let fetch = PhotoLibrary.fetchAll()
        summary.total = fetch.count
        let tmpDir = FileManager.default.temporaryDirectory.appendingPathComponent("export", isDirectory: true)
        try? FileManager.default.removeItem(at: tmpDir)
        try? FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)

        var fatal: Error?
        var index = 0
        batches: while index < fetch.count {
            if Task.isCancelled { break }
            let range = index..<min(index + batchSize, fetch.count)
            // 分批讀資源清單，不一次把幾萬張都載進記憶體
            let entries: [AssetEntry] = await Task.detached(priority: .userInitiated) {
                range.map { i in autoreleasepool { PhotoLibrary.entry(for: fetch.object(at: i)) } }
            }.value
            summary.files += entries.reduce(0) { $0 + $1.resources.count }

            let have: Set<String>
            do { have = try await withReconnect(client) { try await client.check(keys: entries.flatMap { $0.resources.map(\.key) }) } }
            catch { fatal = error; break }

            do {
                try await withThrowingTaskGroup(of: Void.self) { group in
                    var it = entries.makeIterator()
                    func addNext() -> Bool {
                        guard let e = it.next() else { return false }
                        group.addTask { [weak self] in try await self?.process(e, have: have, client: client, tmpDir: tmpDir) }
                        return true
                    }
                    for _ in 0..<concurrency { if !addNext() { break } }
                    while try await group.next() != nil {
                        if Task.isCancelled { group.cancelAll(); break }
                        _ = addNext()
                    }
                }
            } catch is CancellationError {
                break batches
            } catch {
                fatal = error; break
            }
            index = range.upperBound
            try? await client.report(ReportBody(final: false, summary: summary, problems: nil, limitedAccess: limitedAccess))
        }

        try? FileManager.default.removeItem(at: tmpDir)
        current = ""
        let completed = fatal == nil && !Task.isCancelled && index >= fetch.count
        // 不論怎麼結束都回報一次，電腦端會更新清單
        try? await client.report(ReportBody(final: true, summary: summary, problems: problems, limitedAccess: limitedAccess))
        let run = LastRun(summary: summary, problems: problems, finishedAt: Date(), completed: completed, computerName: hello.name)
        LastRunStore.save(run)
        lastRun = run
        if let fatal { phase = .failed(fatal.localizedDescription) }
        else { phase = completed ? .finished : .stopped }
    }

    /// 處理一個照片／影片項目：傳它所有還沒在電腦上的原始檔
    nonisolated private func process(_ entry: AssetEntry, have: Set<String>, client: ReceiverClient, tmpDir: URL) async throws {
        if entry.resources.isEmpty {
            await record(entry, .failed("找不到原始檔"))
            return
        }
        var icloud = false
        var failure: String?
        var skipped = 0
        for res in entry.resources {
            if have.contains(res.key) { skipped += 1; continue }
            try Task.checkCancellation()
            await MainActor.run { self.current = res.filename }
            let tmp = tmpDir.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: tmp) }
            do {
                let (size, sha) = try await ResourceExporter.export(res, to: tmp)
                let meta = UploadMeta(key: res.key, filename: res.filename, sha256: sha, size: size,
                                      created: res.created, assetId: res.assetId, resourceType: res.typeName)
                try await uploadWithRetry(client: client, file: tmp, meta: meta)
                await MainActor.run { self.uploadedFiles += 1; self.bytesSent += size }
            } catch ExportError.iCloudOnly {
                icloud = true
            } catch let e as ReceiverError where e.isFatal {
                throw e
            } catch is CancellationError {
                throw CancellationError()
            } catch {
                failure = error.localizedDescription
            }
        }
        if skipped > 0 { let n = skipped; await MainActor.run { self.skippedFiles += n } }
        if let failure { await record(entry, .failed(failure)) }
        else if icloud { await record(entry, .icloud) }
        else { await record(entry, .done) }
    }

    nonisolated private func uploadWithRetry(client: ReceiverClient, file: URL, meta: UploadMeta) async throws {
        var attempt = 0
        while true {
            attempt += 1
            do {
                try await withReconnect(client) { try await client.upload(file: file, meta: meta) }
                return
            } catch let e as ReceiverError where e.isFatal {
                throw e
            } catch {
                if attempt >= 3 || Task.isCancelled { throw error }
                try await Task.sleep(nanoseconds: UInt64(attempt) * 1_000_000_000)
            }
        }
    }

    /// Wi-Fi 短暫斷線時，等一下再重連，最多三次
    nonisolated private func withReconnect<T>(_ client: ReceiverClient, _ op: () async throws -> T) async throws -> T {
        var tries = 0
        while true {
            do { return try await op() } catch ReceiverError.unreachable {
                tries += 1
                if tries > 3 || Task.isCancelled { throw ReceiverError.unreachable }
                try await Task.sleep(nanoseconds: 3_000_000_000)
                _ = try? await client.connect()
            }
        }
    }

    private enum Outcome { case done, icloud, failed(String) }

    private func record(_ e: AssetEntry, _ o: Outcome) {
        processed += 1
        switch o {
        case .done: summary.done += 1
        case .icloud:
            summary.icloud += 1
            problems.append(Problem(assetId: e.assetId, status: .icloud, filename: e.displayName, created: e.created,
                                    reason: "原始檔只在 iCloud（最佳化儲存空間），這次沒有下載"))
        case .failed(let msg):
            summary.failed += 1
            problems.append(Problem(assetId: e.assetId, status: .failed, filename: e.displayName, created: e.created, reason: msg))
        }
    }
}

struct ReportBody: Encodable {
    let final: Bool
    let summary: Summary
    let problems: [Problem]?
    let limitedAccess: Bool
    let device = UIDevice.current.name
    let at = Date()

    enum CodingKeys: String, CodingKey { case final, summary, problems, limitedAccess, device, at }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: CodingKeys.self)
        try c.encode(final, forKey: .final); try c.encode(summary, forKey: .summary)
        try c.encodeIfPresent(problems.map { $0.map(ProblemOut.init) }, forKey: .problems)
        try c.encode(limitedAccess, forKey: .limitedAccess); try c.encode(device, forKey: .device)
        try c.encode(ReceiverClient.iso.string(from: at), forKey: .at)
    }
    private struct ProblemOut: Encodable {
        let status: String, filename: String, created: String?, reason: String, assetId: String
        init(_ p: Problem) {
            status = p.status.rawValue; filename = p.filename; reason = p.reason; assetId = p.assetId
            created = p.created.map { ReceiverClient.iso.string(from: $0) }
        }
    }
}

enum LastRunStore {
    private static var url: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("last-run.json")
    }
    static func load() -> LastRun? {
        guard let d = try? Data(contentsOf: url) else { return nil }
        return try? JSONDecoder().decode(LastRun.self, from: d)
    }
    static func save(_ r: LastRun) {
        if let d = try? JSONEncoder().encode(r) { try? d.write(to: url, options: .atomic) }
    }
}
