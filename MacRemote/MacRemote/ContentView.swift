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

            MediaPanel()
            SwipeableControls()
            BottomBar(keyboardActive: $keyboardActive)
                .padding(.bottom, 4)
        }
        .background(Color.black.ignoresSafeArea())
        .overlay(alignment: .topTrailing) {
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

// MARK: - Media panel

private struct MediaPanel: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 6) {
            // Track info
            if !state.nowPlaying.title.isEmpty {
                VStack(spacing: 2) {
                    Text(state.nowPlaying.title)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundColor(.white)
                        .lineLimit(1)
                    Text(state.nowPlaying.artist)
                        .font(.system(size: 11))
                        .foregroundColor(.gray)
                        .lineLimit(1)
                }
            }

            // Progress bar
            if state.nowPlaying.duration > 0 {
                VStack(spacing: 3) {
                    GeometryReader { geo in
                        ZStack(alignment: .leading) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color(white: 0.25))
                                .frame(height: 4)
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Color.white)
                                .frame(width: geo.size.width * CGFloat(state.nowPlaying.elapsed / state.nowPlaying.duration), height: 4)
                        }
                    }
                    .frame(height: 4)

                    HStack {
                        Text(formatTime(state.nowPlaying.elapsed))
                        Spacer()
                        Text(formatTime(state.nowPlaying.duration))
                    }
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundColor(.gray)
                }
            }

            // Controls
            HStack(spacing: 6) {
                mediaBtn("rewind10",    icon: "gobackward.10")
                mediaBtn("prev",        icon: "backward.end.fill")
                mediaBtn("play",        icon: "playpause.fill",   large: true)
                mediaBtn("next",        icon: "forward.end.fill")
                mediaBtn("forward15",   icon: "goforward.15")
                Spacer().frame(width: 4)
                mediaBtn("voldown",     icon: "speaker.minus.fill")
                mediaBtn("mute",        icon: "speaker.slash.fill")
                mediaBtn("volup",       icon: "speaker.plus.fill")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.07))
        .cornerRadius(10)
        .padding(.horizontal, 8)
    }

    private func mediaBtn(_ key: String, icon: String, large: Bool = false) -> some View {
        Button {
            state.media(key)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        } label: {
            Image(systemName: icon)
                .font(.system(size: large ? 18 : 14))
                .foregroundColor(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color(white: 0.13))
                .cornerRadius(8)
        }
    }

    private func formatTime(_ t: Double) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }
}

// MARK: - Swipeable mod + specials

private struct SwipeableControls: View {
    @State private var page = 0

    var body: some View {
        VStack(spacing: 4) {
            TabView(selection: $page) {
                ModRow().tag(0)
                SpecialsRow().tag(1)
            }
            .tabViewStyle(.page(indexDisplayMode: .never))
            .frame(height: 44)

            HStack(spacing: 6) {
                ForEach(0..<2) { i in
                    Circle()
                        .fill(page == i ? Color.white : Color(white: 0.35))
                        .frame(width: 5, height: 5)
                }
            }
        }
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
                        .foregroundColor(.white)
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
        HStack(spacing: 6) {
            ForEach(keys, id: \.0) { (key, label) in
                Button {
                    state.combo(key)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                } label: {
                    Text(label).font(.system(size: 13))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
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

// MARK: - Bottom bar

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
