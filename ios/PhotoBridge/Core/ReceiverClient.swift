import Foundation
import UIKit

enum ReceiverError: LocalizedError {
    case unreachable
    case unauthorized
    case notReady
    case diskFull
    case verifyFailed
    case server(Int, String)

    var errorDescription: String? {
        switch self {
        case .unreachable: return "連不到電腦。請確認電腦的接收程式開著，而且手機和電腦連同一個 Wi-Fi。"
        case .unauthorized: return "配對已失效，請重新掃描電腦上的 QR Code。"
        case .notReady: return "電腦端還沒選備份資料夾。"
        case .diskFull: return "電腦的備份磁碟空間不足。"
        case .verifyFailed: return "電腦收到的檔案驗證不符"
        case let .server(code, msg): return "電腦回應錯誤（\(code)）：\(msg)"
        }
    }

    /// 這類錯誤代表整個備份要停下來，重試單一檔案沒用
    var isFatal: Bool {
        switch self {
        case .unauthorized, .notReady, .diskFull, .unreachable: return true
        default: return false
        }
    }
}

struct HelloResponse: Decodable {
    let name: String
    let version: String
    let ready: Bool
    let count: Int
}

struct UploadMeta {
    let key: String
    let filename: String
    let sha256: String
    let size: Int64
    let created: Date?
    let assetId: String
    let resourceType: String
}

/// 跟電腦端接收程式溝通（區網 HTTP，每個請求帶配對 token）
final class ReceiverClient {
    private(set) var pairing: Pairing
    private(set) var baseURL: URL?
    private let session: URLSession
    private let quickSession: URLSession
    private let deviceName = UIDevice.current.name

    init(pairing: Pairing) {
        self.pairing = pairing
        let cfg = URLSessionConfiguration.default
        cfg.timeoutIntervalForRequest = 120      // 兩分鐘完全沒資料才算斷
        cfg.timeoutIntervalForResource = 6 * 3600 // 大影片
        cfg.waitsForConnectivity = false
        cfg.httpMaximumConnectionsPerHost = 4
        session = URLSession(configuration: cfg)
        let quick = URLSessionConfiguration.default
        quick.timeoutIntervalForRequest = 4
        quickSession = URLSession(configuration: quick)
    }

    /// 依序試 QR Code 上的每個位址，找到能連的那個
    func connect() async throws -> HelloResponse {
        var lastError: Error = ReceiverError.unreachable
        for host in pairing.orderedHosts {
            guard let base = URL(string: "http://\(host):\(pairing.port)") else { continue }
            do {
                let hello: HelloResponse = try await getJSON(base.appendingPathComponent("api/hello"), session: quickSession)
                baseURL = base
                if pairing.lastHost != host {
                    pairing.lastHost = host
                    pairing.save()
                }
                return hello
            } catch let e as ReceiverError where e == .unauthorized {
                throw e
            } catch {
                lastError = error
            }
        }
        if lastError is ReceiverError { throw lastError }
        throw ReceiverError.unreachable
    }

    func check(keys: [String]) async throws -> Set<String> {
        struct Body: Encodable { let keys: [String] }
        struct Res: Decodable { let have: [String] }
        let res: Res = try await postJSON("api/check", Body(keys: keys))
        return Set(res.have)
    }

    func upload(file: URL, meta: UploadMeta) async throws {
        guard let base = baseURL else { throw ReceiverError.unreachable }
        var req = URLRequest(url: base.appendingPathComponent("api/upload"))
        req.httpMethod = "PUT"
        applyAuth(&req)
        req.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        req.setValue(enc(meta.key), forHTTPHeaderField: "X-Key")
        req.setValue(enc(meta.filename), forHTTPHeaderField: "X-Filename")
        req.setValue(meta.sha256, forHTTPHeaderField: "X-Sha256")
        req.setValue(String(meta.size), forHTTPHeaderField: "X-Size")
        req.setValue(enc(meta.assetId), forHTTPHeaderField: "X-Asset-Id")
        req.setValue(meta.resourceType, forHTTPHeaderField: "X-Res-Type")
        if let c = meta.created { req.setValue(Self.iso.string(from: c), forHTTPHeaderField: "X-Created") }
        let (data, resp) = try await mapNetwork { try await self.session.upload(for: req, fromFile: file) }
        try check(resp, data)
    }

    private struct OkResponse: Decodable { let ok: Bool }

    func report<T: Encodable>(_ body: T) async throws {
        let _: OkResponse = try await postJSON("api/report", body)
    }

    // MARK: - plumbing

    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    private func enc(_ s: String) -> String {
        s.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? s
    }

    private func applyAuth(_ req: inout URLRequest) {
        req.setValue(pairing.token, forHTTPHeaderField: "X-Token")
        req.setValue(enc(deviceName), forHTTPHeaderField: "X-Device")
    }

    private func getJSON<T: Decodable>(_ url: URL, session: URLSession) async throws -> T {
        var req = URLRequest(url: url)
        applyAuth(&req)
        let (data, resp) = try await mapNetwork { try await session.data(for: req) }
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func postJSON<B: Encodable, T: Decodable>(_ path: String, _ body: B) async throws -> T {
        guard let base = baseURL else { throw ReceiverError.unreachable }
        var req = URLRequest(url: base.appendingPathComponent(path))
        req.httpMethod = "POST"
        applyAuth(&req)
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try JSONEncoder().encode(body)
        let (data, resp) = try await mapNetwork { try await self.session.data(for: req) }
        try check(resp, data)
        return try JSONDecoder().decode(T.self, from: data)
    }

    private func mapNetwork<T>(_ op: () async throws -> T) async throws -> T {
        do { return try await op() } catch let e as URLError {
            switch e.code {
            case .cannotConnectToHost, .cannotFindHost, .notConnectedToInternet, .networkConnectionLost, .timedOut, .dnsLookupFailed:
                throw ReceiverError.unreachable
            default: throw e
            }
        }
    }

    private struct ErrorResponse: Decodable { let error: String }

    private func check(_ resp: URLResponse, _ data: Data) throws {
        guard let http = resp as? HTTPURLResponse else { throw ReceiverError.unreachable }
        switch http.statusCode {
        case 200..<300: return
        case 401: throw ReceiverError.unauthorized
        case 409 where String(data: data, encoding: .utf8)?.contains("資料夾") == true: throw ReceiverError.notReady
        case 422: throw ReceiverError.verifyFailed
        case 507: throw ReceiverError.diskFull
        default:
            let msg = (try? JSONDecoder().decode(ErrorResponse.self, from: data).error) ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode)
            throw ReceiverError.server(http.statusCode, msg)
        }
    }
}

extension ReceiverError: Equatable {
    static func == (a: ReceiverError, b: ReceiverError) -> Bool {
        switch (a, b) {
        case (.unreachable, .unreachable), (.unauthorized, .unauthorized), (.notReady, .notReady),
             (.diskFull, .diskFull), (.verifyFailed, .verifyFailed): return true
        case let (.server(x, _), .server(y, _)): return x == y
        default: return false
        }
    }
}
