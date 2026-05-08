import SwiftUI

@main
struct MacRemoteApp: App {
    @StateObject private var state = AppState()

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .persistentSystemOverlays(.hidden)
        }
    }
}

struct RootView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        if state.settings.host.isEmpty || state.settings.token.isEmpty {
            SettingsView()
        } else {
            ContentView()
        }
    }
}
