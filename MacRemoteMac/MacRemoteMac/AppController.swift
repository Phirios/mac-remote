import Foundation
import Combine
import AppKit

/// Owns the WebSocket server, settings, injector, and live state shown in
/// the menu bar. Restarts the server when the port or token changes.
@MainActor
final class AppController: ObservableObject {
    @Published private(set) var serverRunning = false
    @Published private(set) var connectionCount = 0
    @Published private(set) var addresses: [DetectedAddress] = []
    @Published private(set) var accessibilityTrusted: Bool = AccessibilityHelper.isTrusted

    let settings: SettingsStore
    private let injector = EventInjector()
    private var server: WSServer?
    private var cancellables = Set<AnyCancellable>()
    private var refreshTimer: Timer?

    init(settings: SettingsStore) {
        self.settings = settings
        addresses = IPDetector.detect()
        // Restart server on config changes
        settings.$port
            .dropFirst()
            .sink { [weak self] _ in self?.restart() }
            .store(in: &cancellables)
        settings.$token
            .dropFirst()
            .sink { [weak self] _ in self?.restart() }
            .store(in: &cancellables)
        // Refresh IPs and trust state every 5s while menu is up
        refreshTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.addresses = IPDetector.detect()
                self.accessibilityTrusted = AccessibilityHelper.isTrusted
            }
        }
    }

    func start() {
        guard server == nil else { return }
        let s = WSServer(
            port: UInt16(settings.port),
            token: settings.token,
            onMessage: { [weak self] msg in self?.injector.handle(msg) },
            onConnectionChange: { [weak self] count in self?.connectionCount = count }
        )
        do {
            try s.start()
            server = s
            serverRunning = true
            NSLog("[AppController] server started on :\(settings.port)")
        } catch {
            NSLog("[AppController] start failed: \(error)")
            serverRunning = false
        }
    }

    func stop() {
        server?.stop()
        server = nil
        serverRunning = false
        connectionCount = 0
    }

    func restart() {
        stop()
        start()
    }

    func regenerateToken() {
        settings.regenerateToken()
        // Settings publisher triggers restart
    }

    /// Build the URL a client should connect to for `addr` (HTTP form, used
    /// for QR code; the iOS app upgrades the same URL to WS).
    func clientURL(for addr: DetectedAddress) -> URL {
        URL(string: "http://\(addr.address):\(settings.port)/\(settings.token)/")!
    }
}
