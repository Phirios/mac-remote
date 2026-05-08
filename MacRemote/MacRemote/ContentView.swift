import SwiftUI
import UIKit

struct ContentView: View {
    @EnvironmentObject var state: AppState
    @State private var keyboardActive = false
    @State private var showSettings = false

    var body: some View {
        VStack(spacing: 8) {
            header
            TrackpadView()
                .padding(.horizontal, 8)

            MediaRow()
            ModRow()
            SpecialsRow()
            BottomBar(keyboardActive: $keyboardActive)
                .padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
            // Hidden keyboard capture lives in the overlay so it can become
            // first responder without disturbing the layout.
            KeyboardCapture(
                isActive: $keyboardActive,
                onText: { state.text($0) },
                onBackspace: { state.combo("delete", mods: []) },
                onReturn: { state.combo("return", mods: []) }
            )
            .frame(width: 1, height: 1)
            .opacity(0.01)
        }
        .onReceive(NotificationCenter.default.publisher(for: .macRemoteHardwareKey)) { note in
            guard let info = note.userInfo,
                  let key = info["key"] as? String,
                  let mods = info["mods"] as? [String] else { return }
            state.combo(key, mods: mods)
        }
        .sheet(isPresented: $showSettings) { SettingsView(asSheet: true) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(statusColor)
                .frame(width: 10, height: 10)
            Text("Mac Remote").font(.system(size: 14, weight: .semibold))
            Spacer()
            Text(state.settings.host).font(.system(size: 12)).foregroundColor(.gray)
            Button { showSettings = true } label: {
                Image(systemName: "gear").font(.system(size: 16))
            }
            .foregroundColor(.gray)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
    }

    private var statusColor: Color {
        switch state.status {
        case .connected:    return .green
        case .connecting:   return .yellow
        case .disconnected: return .red
        case .failed:       return .red
        }
    }
}

private struct MediaRow: View {
    @EnvironmentObject var state: AppState
    private let keys: [(String, String)] = [
        ("prev", "backward.end.fill"),
        ("play", "playpause.fill"),
        ("next", "forward.end.fill"),
        ("voldown", "speaker.minus.fill"),
        ("mute", "speaker.slash.fill"),
        ("volup", "speaker.plus.fill"),
    ]
    var body: some View {
        HStack(spacing: 6) {
            ForEach(keys, id: \.0) { (key, icon) in
                Button {
                    state.media(key)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Image(systemName: icon)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(Color(white: 0.1))
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.18), lineWidth: 1))
                        .foregroundColor(.white)
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct ModRow: View {
    @EnvironmentObject var state: AppState
    private let mods: [(String, String)] = [("cmd", "⌘"), ("shift", "⇧"), ("opt", "⌥"), ("ctrl", "⌃")]

    var body: some View {
        HStack(spacing: 6) {
            ForEach(mods, id: \.0) { (key, label) in
                Button {
                    state.toggleMod(key)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(label).font(.system(size: 13, weight: .medium))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(state.heldMods.contains(key) ? Color.accentColor : Color(white: 0.1))
                        .foregroundColor(state.heldMods.contains(key) ? .white : .white)
                        .cornerRadius(8)
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.18), lineWidth: 1))
                }
            }
        }
        .padding(.horizontal, 8)
    }
}

private struct SpecialsRow: View {
    @EnvironmentObject var state: AppState
    private let keys: [(String, String)] = [
        ("escape","esc"),("tab","⇥"),("return","↵"),("delete","⌫"),
        ("left","←"),("up","↑"),("down","↓"),("right","→"),
    ]
    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(keys, id: \.0) { (key, label) in
                    Button {
                        state.combo(key)
                        UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    } label: {
                        Text(label).font(.system(size: 13))
                            .padding(.vertical, 10).padding(.horizontal, 12)
                            .background(Color(white: 0.1))
                            .cornerRadius(8)
                            .overlay(RoundedRectangle(cornerRadius: 8).stroke(Color(white: 0.18), lineWidth: 1))
                            .foregroundColor(.white)
                    }
                }
            }
            .padding(.horizontal, 8)
        }
    }
}

private struct BottomBar: View {
    @EnvironmentObject var state: AppState
    @Binding var keyboardActive: Bool
    var body: some View {
        HStack(spacing: 6) {
            Button {
                state.click("left")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text("Left Click").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(white: 0.1)).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.18), lineWidth: 1))
                    .foregroundColor(.white)
            }
            Button {
                state.click("right")
                UIImpactFeedbackGenerator(style: .light).impactOccurred()
            } label: {
                Text("Right Click").frame(maxWidth: .infinity).padding(.vertical, 14)
                    .background(Color(white: 0.1)).cornerRadius(10)
                    .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(white: 0.18), lineWidth: 1))
                    .foregroundColor(.white)
            }
            Button { keyboardActive.toggle() } label: {
                Image(systemName: keyboardActive ? "keyboard.fill" : "keyboard")
                    .padding(.vertical, 14).padding(.horizontal, 16)
                    .background(keyboardActive ? Color.accentColor : Color(white: 0.1))
                    .cornerRadius(10)
                    .foregroundColor(.white)
            }
        }
        .padding(.horizontal, 8)
    }
}
