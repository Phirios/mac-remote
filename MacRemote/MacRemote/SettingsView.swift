import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var state: AppState
    @Environment(\.dismiss) private var dismiss
    var asSheet: Bool = false

    @State private var host: String = ""
    @State private var port: String = "8765"
    @State private var token: String = ""
    @State private var sensitivity: Double = 1.6
    @State private var scrollSensitivity: Double = 0.6
    @State private var smoothScroll: Bool = true
    @State private var threeFingerGestures: Bool = true

    var body: some View {
        NavigationStack {
            Form {
                Section("Mac connection") {
                    TextField("Host (e.g. 100.64.0.2)", text: $host)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                    TextField("Port", text: $port).keyboardType(.numberPad)
                    TextField("Token", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(size: 13, design: .monospaced))
                    Button("Paste URL from Mac") { pasteURL() }
                }

                Section("Sensitivity") {
                    VStack(alignment: .leading) {
                        Text("Cursor: \(String(format: "%.1f", sensitivity))×")
                        Slider(value: $sensitivity, in: 0.5...4.0, step: 0.1)
                    }
                    VStack(alignment: .leading) {
                        Text("Scroll: \(String(format: "%.2f", scrollSensitivity))×")
                        Slider(value: $scrollSensitivity, in: 0.1...2.0, step: 0.05)
                    }
                    Toggle("Smooth Scroll", isOn: $smoothScroll)
                    Toggle("3-Finger Gestures", isOn: $threeFingerGestures)
                }

                Section {
                    Button {
                        save()
                        dismiss()
                    } label: {
                        Text("Save & Connect").bold()
                    }
                    .disabled(host.trimmingCharacters(in: .whitespaces).isEmpty
                              || token.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Section("How to find these") {
                    Text("Open the Mac Remote menu bar app on your Mac. Click the icon → expand an address row → tap Copy URL, then use Paste URL from Mac here. Or click Copy Token in the footer and enter the host manually.")
                        .font(.footnote).foregroundColor(.gray)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if asSheet {
                    ToolbarItem(placement: .topBarLeading) {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .onAppear { loadFromState() }
        }
    }

    private func pasteURL() {
        guard let str = UIPasteboard.general.string,
              let url = URL(string: str),
              let h = url.host else { return }
        host = h
        if url.port != nil { port = String(url.port!) }
        let tok = url.pathComponents.first(where: { !$0.isEmpty && $0 != "/" }) ?? ""
        if !tok.isEmpty { token = tok }
    }

    private func loadFromState() {
        host = state.settings.host
        port = String(state.settings.port)
        token = state.settings.token
        sensitivity = state.settings.sensitivity
        scrollSensitivity = state.settings.scrollSensitivity
        smoothScroll = state.settings.smoothScroll
        threeFingerGestures = state.settings.threeFingerGestures
    }
    private func save() {
        var s = state.settings
        s.host = host.trimmingCharacters(in: .whitespaces)
        s.port = Int(port) ?? 8765
        s.token = token.trimmingCharacters(in: .whitespaces)
        s.sensitivity = sensitivity
        s.scrollSensitivity = scrollSensitivity
        s.smoothScroll = smoothScroll
        s.threeFingerGestures = threeFingerGestures
        state.settings = s
    }
}
