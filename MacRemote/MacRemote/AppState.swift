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

struct NowPlayingInfo {
    var title: String = ""
    var artist: String = ""
    var duration: Double = 0
    var elapsed: Double = 0
    var playing: Bool = false
}

@MainActor
final class AppState: ObservableObject {
    @Published var settings: ConnectionSettings {
        didSet { persist(); reconnectIfNeeded() }
    }
    @Published var status: ConnectionStatus = .disconnected
    @Published var heldMods: Set<String> = []
    @Published var nowPlaying: NowPlayingInfo = NowPlayingInfo()

    private var client: WebSocketClient?
    private var elapsedTicker: Timer?
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
        c.onMessage = { [weak self] text in
            Task { @MainActor in self?.handleIncoming(text) }
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
    func media(_ key: String) { send(["t": "media", "key": key]) }

    private func handleIncoming(_ text: String) {
        guard let msg = try? MRCodec.decode(text) else { return }
        if case .nowPlaying(let title, let artist, let duration, let elapsed, let playing) = msg {
            nowPlaying = NowPlayingInfo(title: title, artist: artist,
                                        duration: duration, elapsed: elapsed, playing: playing)
            elapsedTicker?.invalidate()
            if playing && duration > 0 {
                var current = elapsed
                elapsedTicker = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                    current += 1
                    Task { @MainActor in
                        guard let self, self.nowPlaying.playing else { return }
                        self.nowPlaying.elapsed = min(current, self.nowPlaying.duration)
                    }
                }
            }
        }
    }
}
