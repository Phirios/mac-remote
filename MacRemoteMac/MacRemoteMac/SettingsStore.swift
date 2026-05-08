import Foundation
import Combine

/// Persisted server settings: port + auth token. Token is generated on
/// first launch and cached. "Regenerate" replaces it (forces clients to
/// reconnect with the new value).
@MainActor
final class SettingsStore: ObservableObject {
    @Published var port: Int { didSet { defaults.set(port, forKey: Keys.port) } }
    @Published var token: String { didSet { defaults.set(token, forKey: Keys.token) } }
    @Published var startAtLogin: Bool { didSet { defaults.set(startAtLogin, forKey: Keys.startAtLogin) } }

    private let defaults = UserDefaults.standard

    private enum Keys {
        static let port = "mr.port"
        static let token = "mr.token"
        static let startAtLogin = "mr.startAtLogin"
    }

    init() {
        let savedPort = defaults.integer(forKey: Keys.port)
        self.port = savedPort > 0 ? savedPort : 8765
        if let t = defaults.string(forKey: Keys.token), !t.isEmpty {
            self.token = t
        } else {
            let t = Self.generateToken()
            defaults.set(t, forKey: Keys.token)
            self.token = t
        }
        self.startAtLogin = defaults.bool(forKey: Keys.startAtLogin)
    }

    func regenerateToken() {
        token = Self.generateToken()
    }

    static func generateToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
