import Foundation
import Photos
import CryptoKit

// 只讀取照片圖庫。整個 App 沒有呼叫 PHPhotoLibrary.performChanges，不會刪除或修改任何照片。

/// 一個要備份的原始檔（一張 Live Photo 會有照片＋影片兩個）
struct BackupResource {
    let key: String          // 去重用：assetId|類型|原始檔名
    let assetId: String
    let typeName: String
    let filename: String     // 存到電腦上的檔名
    let created: Date?
    let resource: PHAssetResource
}

struct AssetEntry {
    let assetId: String
    let created: Date?
    let displayName: String
    let resources: [BackupResource]
}

enum PhotoLibrary {
    static func authorize() async -> PHAuthorizationStatus {
        // 讀取完整圖庫只有 readWrite 這個等級可選；App 本身只讀不寫
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        if status == .notDetermined {
            return await PHPhotoLibrary.requestAuthorization(for: .readWrite)
        }
        return status
    }

    static func fetchAll() -> PHFetchResult<PHAsset> {
        let opts = PHFetchOptions()
        opts.includeHiddenAssets = true      // 隱藏相簿也要備份
        opts.includeAllBurstAssets = true    // 連拍每一張都要
        opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
        return PHAsset.fetchAssets(with: opts)
    }

    static func entry(for asset: PHAsset) -> AssetEntry {
        let all = PHAssetResource.assetResources(for: asset)
        // 原始檔的主檔名，給編輯後版本命名用
        let primary = all.first { [.photo, .video, .audio].contains($0.type) } ?? all.first
        let primaryBase = (primary?.originalFilename as NSString?)?.deletingPathExtension ?? "IMG"
        var out: [BackupResource] = []
        for r in all {
            guard let name = typeName(r.type) else { continue }
            var filename = r.originalFilename
            if isEdited(r.type) {
                // 編輯後版本系統常叫 FullSizeRender.jpg，改成 IMG_0001_edited.jpg
                let ext = (r.originalFilename as NSString).pathExtension
                filename = "\(primaryBase)_edited" + (ext.isEmpty ? "" : ".\(ext)")
            }
            out.append(BackupResource(
                key: "\(asset.localIdentifier)|\(name)|\(r.originalFilename)",
                assetId: asset.localIdentifier, typeName: name, filename: filename,
                created: asset.creationDate, resource: r))
        }
        return AssetEntry(assetId: asset.localIdentifier, created: asset.creationDate,
                          displayName: primary?.originalFilename ?? asset.localIdentifier, resources: out)
    }

    /// 要備份哪些類型：原始檔全部，加上編輯過的版本。縮圖、調整參數不備份。
    static func typeName(_ t: PHAssetResourceType) -> String? {
        switch t {
        case .photo: return "photo"
        case .video: return "video"
        case .audio: return "audio"
        case .alternatePhoto: return "alternatePhoto"   // RAW+JPEG 的另一個檔
        case .pairedVideo: return "pairedVideo"         // Live Photo 的影片
        case .fullSizePhoto: return "fullSizePhoto"     // 編輯後
        case .fullSizeVideo: return "fullSizeVideo"
        case .fullSizePairedVideo: return "fullSizePairedVideo"
        default: return nil
        }
    }

    static func isEdited(_ t: PHAssetResourceType) -> Bool {
        t == .fullSizePhoto || t == .fullSizeVideo || t == .fullSizePairedVideo
    }
}

enum ExportError: LocalizedError {
    case iCloudOnly
    case localDiskFull
    case empty
    case read(String)

    var errorDescription: String? {
        switch self {
        case .iCloudOnly: return "原始檔只在 iCloud，手機上沒有"
        case .localDiskFull: return "手機空間不足，無法暫存這個檔案"
        case .empty: return "讀到的檔案是空的"
        case let .read(m): return "讀取失敗：\(m)"
        }
    }
}

/// 把一個原始檔從圖庫串流寫到暫存檔，同時算 SHA-256。不會從 iCloud 下載。
enum ResourceExporter {
    private final class Sink: @unchecked Sendable {
        var hasher = SHA256()
        var size: Int64 = 0
        var writeError: Error?
        let handle: FileHandle
        init(handle: FileHandle) { self.handle = handle }
    }

    /// allowICloud = true 時，手機上沒有的原始檔會先從 iCloud 下載（較慢、要網路）
    static func export(_ res: BackupResource, to url: URL, allowICloud: Bool = false,
                       progress: (@Sendable (Double) -> Void)? = nil) async throws -> (size: Int64, sha256: String) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let handle = try FileHandle(forWritingTo: url)
        let sink = Sink(handle: handle)
        let opts = PHAssetResourceRequestOptions()
        opts.isNetworkAccessAllowed = allowICloud
        if allowICloud, let progress { opts.progressHandler = { p in progress(p) } }

        do {
            try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
                PHAssetResourceManager.default().requestData(for: res.resource, options: opts, dataReceivedHandler: { data in
                    guard sink.writeError == nil else { return }
                    do {
                        try sink.handle.write(contentsOf: data)
                        sink.hasher.update(data: data)
                        sink.size += Int64(data.count)
                    } catch {
                        sink.writeError = error
                    }
                }, completionHandler: { error in
                    if let error { cont.resume(throwing: error) } else { cont.resume() }
                })
            }
        } catch {
            try? handle.close()
            let e = classify(error)
            if allowICloud, case ExportError.iCloudOnly = e { throw ExportError.read("iCloud 下載失敗，請確認網路後重試") }
            throw e
        }
        try handle.close()
        if let w = sink.writeError { throw classify(w) }
        if sink.size == 0 { throw ExportError.empty }
        let hex = sink.hasher.finalize().map { String(format: "%02x", $0) }.joined()
        return (sink.size, hex)
    }

    static func classify(_ error: Error) -> Error {
        let ns = error as NSError
        if ns.domain == PHPhotosErrorDomain, ns.code == PHPhotosError.networkAccessRequired.rawValue {
            return ExportError.iCloudOnly
        }
        if ns.domain.localizedCaseInsensitiveContains("cloud") { return ExportError.iCloudOnly }
        if ns.domain == NSCocoaErrorDomain, ns.code == NSFileWriteOutOfSpaceError { return ExportError.localDiskFull }
        if ns.domain == NSPOSIXErrorDomain, ns.code == Int(ENOSPC) { return ExportError.localDiskFull }
        return ExportError.read("\(ns.domain) \(ns.code) \(ns.localizedDescription)")
    }
}
