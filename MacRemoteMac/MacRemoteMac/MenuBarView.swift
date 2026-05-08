import SwiftUI
import AppKit

struct MenuBarView: View {
    @EnvironmentObject var ctrl: AppController
    @State private var expandedAddress: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            statusBar
            Divider()

            if !ctrl.accessibilityTrusted {
                accessibilityWarning
                Divider()
            }

            if ctrl.addresses.isEmpty {
                Text("No usable network interfaces detected.")
                    .font(.callout).foregroundColor(.secondary)
                    .padding(12)
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(ctrl.addresses) { addr in
                        addressRow(addr)
                        Divider()
                    }
                }
            }

            footer
        }
        .frame(width: 340)
    }

    // MARK: status bar
    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(ctrl.serverRunning ? (ctrl.connectionCount > 0 ? .green : .yellow) : .red)
                .frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 1) {
                Text("Mac Remote").font(.system(size: 13, weight: .semibold))
                Text(statusText).font(.system(size: 11)).foregroundColor(.secondary)
            }
            Spacer()
            Text(":\(ctrl.settings.port)").font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
    }
    private var statusText: String {
        if !ctrl.serverRunning { return "stopped" }
        if ctrl.connectionCount == 0 { return "waiting for client" }
        return "\(ctrl.connectionCount) client\(ctrl.connectionCount == 1 ? "" : "s") connected"
    }

    // MARK: accessibility warning
    private var accessibilityWarning: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill").foregroundColor(.yellow)
                Text("Accessibility permission required").font(.system(size: 12, weight: .semibold))
            }
            Text("Without it, mouse and keyboard events will be silently dropped.")
                .font(.system(size: 11)).foregroundColor(.secondary)
            HStack {
                Button("Request") { AccessibilityHelper.promptForTrust() }
                Button("Open Settings") { AccessibilityHelper.openAccessibilitySettings() }
            }.font(.system(size: 11))
        }
        .padding(12)
        .background(Color.yellow.opacity(0.1))
    }

    // MARK: address row
    private func addressRow(_ addr: DetectedAddress) -> some View {
        let url = ctrl.clientURL(for: addr)
        let expanded = expandedAddress == addr.id
        return VStack(alignment: .leading, spacing: 6) {
            Button {
                expandedAddress = expanded ? nil : addr.id
            } label: {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(addr.label).font(.system(size: 12, weight: .medium))
                        Text(addr.address).font(.system(size: 11, design: .monospaced)).foregroundColor(.secondary)
                    }
                    Spacer()
                    Image(systemName: expanded ? "chevron.up" : "qrcode")
                        .foregroundColor(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if expanded {
                if let img = QRCode.image(for: url.absoluteString) {
                    Image(nsImage: img)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 200, height: 200)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.vertical, 4)
                }
                Text(url.absoluteString)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.secondary)
                    .lineLimit(2)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                HStack(spacing: 6) {
                    Button("Copy URL") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    Button("Open in browser") {
                        NSWorkspace.shared.open(url)
                    }
                }.font(.system(size: 11))
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 8)
    }

    // MARK: footer
    private var footer: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                Button {
                    ctrl.regenerateToken()
                } label: {
                    Label("Regenerate Token", systemImage: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Forces all connected clients to re-pair")

                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(ctrl.settings.token, forType: .string)
                } label: {
                    Label("Copy Token", systemImage: "doc.on.doc")
                        .font(.system(size: 11))
                }
                .buttonStyle(.plain)
                .help("Copy token to clipboard for iOS setup")

                Spacer()

                Button {
                    NSApp.terminate(nil)
                } label: {
                    Label("Quit", systemImage: "power").font(.system(size: 11))
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 12).padding(.vertical, 8)

            Divider()
            Toggle(isOn: Binding(get: { ctrl.settings.startAtLogin }, set: { ctrl.settings.startAtLogin = $0 })) {
                Text("Launch at Login").font(.system(size: 11))
            }
            .toggleStyle(.checkbox)
            .padding(.horizontal, 12).padding(.vertical, 8)
        }
    }
}
