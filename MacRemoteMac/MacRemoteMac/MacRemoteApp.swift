import SwiftUI
import AppKit

@main
struct MacRemoteApp: App {
    @StateObject private var settings = SettingsStore()
    @StateObject private var ctrl: AppController

    init() {
        let s = SettingsStore()
        _settings = StateObject(wrappedValue: s)
        _ctrl = StateObject(wrappedValue: AppController(settings: s))
    }

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(ctrl)
                .onAppear {
                    if !ctrl.serverRunning {
                        ctrl.start()
                    }
                }
        } label: {
            // Status icon — filled when a client is connected, otherwise outlined.
            Image(systemName: ctrl.connectionCount > 0 ? "computermouse.fill" : "computermouse")
        }
        .menuBarExtraStyle(.window)
    }
}
