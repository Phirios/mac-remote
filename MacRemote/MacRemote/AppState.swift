import Foundation
import Combine
import SwiftUI

struct ConnectionSettings: Codable, Equatable {
    var host: String = ""        // e.g. "100.64.0.2" (Tailscale) or "192.168.0.14"
    var port: Int = 8765
    var token: String = ""
    var sensitivity: Double = 1.6
    var scrollSensitivity: Double = 0.6
    var smoothScroll: Bool = true
    var threeFingerGestures: Bool = true
}

enum ConnectionStatus {
    case disconnected, connecting, connected, failed(String)
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ConnectionSettings {
        didSet { persist(); reconnectIfNeeded() }
    }
    @Published var status: ConnectionStatus = .disconnected
    @Published var heldMods: Set<String> = []   // sticky modifiers, cleared after one use

    private var client: WebSocketClient?
    private static let key = "mac-remote-settings-v1"

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.key),
           let s = try? JSONDecoder().decode(ConnectionSettings.self, from: data) {
            self.settings = s
        } else {
            self.settings = ConnectionSettings()
        }
        if !settings.host.isEmpty && !settings.token.isEmpty {
            connect()
        }
    }

    private func persist() {
        if let data = try? JSONEncoder().encode(settings) {
            UserDefaults.standard.set(data, forKey: Self.key)
        }
    }

    func connect() {
        guard !settings.host.isEmpty, !settings.token.isEmpty else { return }
        client?.disconnect()
        let url = URL(string: "ws://\(settings.host):\(settings.port)/\(settings.token)")!
        let c = WebSocketClient(url: url) { [weak self] s in
            Task { @MainActor in self?.status = s }
        }
        client = c
        c.connect()
    }

    func disconnect() {
        client?.disconnect()
        client = nil
        status = .disconnected
    }

    private func reconnectIfNeeded() {
        if !settings.host.isEmpty && !settings.token.isEmpty {
            connect()
        }
    }

    // ---------- send helpers ----------
    func send(_ msg: [String: Any]) {
        client?.send(msg)
    }

    func consumeMods() -> [String] {
        let mods = Array(heldMods)
        heldMods.removeAll()
        return mods
    }

    func toggleMod(_ name: String) {
        if heldMods.contains(name) { heldMods.remove(name) } else { heldMods.insert(name) }
    }

    func mouseMove(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        send(["t": "mv", "dx": Int(dx.rounded()), "dy": Int(dy.rounded())])
    }
    func mouseDown(_ b: String) { send(["t": "down", "b": b]) }
    func mouseUp(_ b: String) { send(["t": "up", "b": b]) }
    func click(_ b: String, count: Int = 1) { send(["t": "click", "b": b, "count": count]) }
    func scroll(dx: CGFloat, dy: CGFloat) {
        guard dx != 0 || dy != 0 else { return }
        send(["t": "scroll", "dx": Int(dx.rounded()), "dy": Int(dy.rounded())])
    }
    func combo(_ key: String, mods: [String]? = nil) {
        send(["t": "combo", "key": key, "mods": mods ?? consumeMods()])
    }
    func text(_ s: String) { send(["t": "text", "s": s]) }
}
