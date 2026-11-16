import SwiftUI

@main
struct PhotoBridgeApp: App {
    @StateObject private var model = AppModel()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.engine)
                // 用系統相機掃 QR Code 也會直接打開 App 完成配對
                .onOpenURL { model.pair(url: $0) }
                .preferredColorScheme(.light)
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var pairing: Pairing? = Pairing.load()
    @Published var pairError: String?
    let engine = BackupEngine()

    func pair(url: URL) {
        guard let p = Pairing(url: url) else { pairError = "這不是 PhotoBridge 的配對碼"; return }
        pairError = nil
        p.save()
        pairing = p
    }

    func pair(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            pairError = "這不是 PhotoBridge 的配對碼"; return
        }
        pair(url: url)
    }

    func unpair() {
        engine.stop()
        Pairing.clear()
        pairing = nil
    }
}
