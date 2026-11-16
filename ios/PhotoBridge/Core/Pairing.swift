import Foundation

/// 從電腦端 QR Code 讀到的配對資訊：photobridge://pair?v=1&hosts=a,b&port=8765&token=...&name=...
struct Pairing: Codable, Equatable {
    var hosts: [String]
    var port: Int
    var token: String
    var name: String
    /// 上次成功連上的位址，下次先試
    var lastHost: String?

    init?(url: URL) {
        guard url.scheme?.lowercased() == "photobridge",
              let comps = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        var q: [String: String] = [:]
        for item in comps.queryItems ?? [] { q[item.name] = item.value }
        guard let token = q["token"], !token.isEmpty,
              let hostList = q["hosts"], let port = Int(q["port"] ?? "") else { return nil }
        let hosts = hostList.split(separator: ",").map(String.init).filter { !$0.isEmpty }
        guard !hosts.isEmpty else { return nil }
        self.hosts = hosts
        self.port = port
        self.token = token
        self.name = q["name"] ?? "電腦"
    }

    init?(text: String) {
        guard let url = URL(string: text.trimmingCharacters(in: .whitespacesAndNewlines)) else { return nil }
        self.init(url: url)
    }

    var orderedHosts: [String] {
        guard let last = lastHost else { return hosts }
        return [last] + hosts.filter { $0 != last }
    }

    private static let key = "pairing.v1"

    static func load() -> Pairing? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(Pairing.self, from: data)
    }

    func save() {
        UserDefaults.standard.set(try? JSONEncoder().encode(self), forKey: Self.key)
    }

    static func clear() {
        UserDefaults.standard.removeObject(forKey: key)
    }
}
