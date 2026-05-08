import Foundation
import AppKit

private func mrLog(_ msg: String) {
    let line = "\(Date()) \(msg)\n"
    guard let data = line.data(using: .utf8) else { return }
    let url = URL(fileURLWithPath: "/tmp/mr_debug.log")
    if let h = try? FileHandle(forWritingTo: url) {
        h.seekToEndOfFile(); h.write(data); try? h.close()
    } else { try? data.write(to: url) }
}

/// Universal now-playing monitor.
/// Native apps: Music.app + Spotify via DistributedNotificationCenter.
/// Browsers: Chromium-family polled via AppleScript/JavaScript every 2s.
/// Seeking: AppleScript for native apps, JS injection for browsers.
final class NowPlayingMonitor {
    struct TrackInfo {
        var title: String
        var artist: String
        var duration: Double
        var elapsed: Double
        var playing: Bool
    }

    private var info = TrackInfo(title: "", artist: "", duration: 0, elapsed: 0, playing: false)
    private var positionBase: Double = 0
    private var positionDate = Date()
    private(set) var activePlayer: String?   // "Music" | "Spotify" | "Browser" | nil
    private var frontBrowserApp: NSRunningApplication?
    private var clearTask: DispatchWorkItem?
    private var observations: [NSObjectProtocol] = []
    private var browserPollTimer: Timer?
    private var browserPollInFlight = false

    // Chromium-based browsers (all support `execute ... javascript` AppleScript)
    static let chromiumBundles: [String: String] = [
        "com.google.Chrome":            "Google Chrome",
        "company.thebrowser.Browser":   "Arc",
        "com.brave.Browser":            "Brave Browser",
        "com.microsoft.edgemac":        "Microsoft Edge",
        "com.operasoftware.Opera":      "Opera",
    ]

    init() {
        setupNotifications()
        browserPollTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            self?.pollBrowser()
        }
        mrLog("[NowPlaying] init")
    }

    deinit {
        observations.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        browserPollTimer?.invalidate()
    }

    // MARK: - Native app notifications

    private func setupNotifications() {
        let nc = DistributedNotificationCenter.default()
        observations.append(nc.addObserver(
            forName: NSNotification.Name("com.apple.Music.playerInfo"),
            object: nil, queue: .main) { [weak self] n in self?.handleMusic(n) })
        observations.append(nc.addObserver(
            forName: NSNotification.Name("com.spotify.client.PlaybackStateChanged"),
            object: nil, queue: .main) { [weak self] n in self?.handleSpotify(n) })
    }

    private func handleMusic(_ n: Notification) {
        guard let u = n.userInfo else { return }
        let state    = u["Player State"] as? String ?? ""
        let playing  = state == "Playing"
        let title    = u["Name"]   as? String ?? ""
        let artist   = u["Artist"] as? String ?? ""
        let totalMs  = u["Total Time"]      as? Double ?? 0
        let position = u["Player Position"] as? Double ?? 0
        let duration = totalMs > 0 ? totalMs / 1000.0 : 0
        mrLog("[NowPlaying] Music.app \(state) — \"\(title)\"")
        apply(TrackInfo(title: title, artist: artist, duration: duration,
                        elapsed: position, playing: playing),
              player: "Music", position: position)
    }

    private func handleSpotify(_ n: Notification) {
        guard let u = n.userInfo else { return }
        let playerState = u["Player State"] as? String
        let playing  = playerState == "Playing" || (playerState == nil && (u["Playing"] as? Bool ?? false))
        let title    = u["Name"]   as? String ?? info.title
        let artist   = u["Artist"] as? String ?? info.artist
        let durMs    = u["Duration"]         as? Double ?? 0
        let position = u["Playback Position"] as? Double ?? positionBase
        let duration = durMs > 0 ? durMs / 1000.0 : info.duration
        mrLog("[NowPlaying] Spotify playing=\(playing) — \"\(title)\"")
        apply(TrackInfo(title: title, artist: artist, duration: duration,
                        elapsed: position, playing: playing),
              player: "Spotify", position: position)
    }

    private func apply(_ newInfo: TrackInfo, player: String, position: Double) {
        clearTask?.cancel()
        info = newInfo
        positionBase = position
        positionDate = Date()
        activePlayer = player
        if !newInfo.playing {
            // Release control after 5 s of pause so browser can take over
            let task = DispatchWorkItem { [weak self] in
                guard let self, self.activePlayer == player, !self.info.playing else { return }
                self.info = TrackInfo(title: "", artist: "", duration: 0, elapsed: 0, playing: false)
                self.activePlayer = nil
            }
            clearTask = task
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: task)
        }
    }

    // MARK: - Browser polling

    private func pollBrowser() {
        guard !browserPollInFlight else { return }
        guard activePlayer == nil || activePlayer == "Browser" else { return }
        guard let frontApp = NSWorkspace.shared.frontmostApplication,
              let appName = Self.chromiumBundles[frontApp.bundleIdentifier ?? ""] else { return }

        // JS: return 'none' if no ready video, else 'playing|time|duration|title'
        // Uses only single quotes inside so it is safe inside an AppleScript double-quoted string.
        let js = "(function(){var v=document.querySelector('video');if(!v||v.readyState<2)return 'none';var t=document.title.replace(/[|]/g,'').substring(0,80);return(v.paused?'0':'1')+'|'+v.currentTime.toFixed(2)+'|'+v.duration.toFixed(2)+'|'+t})()"
        let script = "tell application \"\(appName)\" to execute front window's active tab javascript \"\(js)\""

        browserPollInFlight = true
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", script]
        let pipe = Pipe()
        t.standardOutput = pipe
        t.terminationHandler = { [weak self] _ in
            guard let self else { return }
            let raw = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self.browserPollInFlight = false
                guard raw != "none", !raw.isEmpty else { return }
                let parts = raw.components(separatedBy: "|")
                guard parts.count >= 3 else { return }
                let playing  = parts[0] == "1"
                let position = Double(parts[1]) ?? 0
                let duration = Double(parts[2]) ?? 0
                let title    = parts.count > 3 ? parts[3...].joined(separator: "|") : ""
                guard duration > 0 else { return }
                self.info = TrackInfo(title: title, artist: "", duration: duration,
                                      elapsed: position, playing: playing)
                self.positionBase = position
                self.positionDate = Date()
                self.activePlayer = "Browser"
                self.frontBrowserApp = frontApp
            }
        }
        try? t.run()
    }

    // MARK: - Public API

    private func liveElapsed() -> Double {
        guard info.playing else { return positionBase }
        return min(info.duration, positionBase + Date().timeIntervalSince(positionDate))
    }

    func getInfo(completion: @escaping (TrackInfo?) -> Void) {
        guard !info.title.isEmpty else { completion(nil); return }
        var result = info
        result.elapsed = liveElapsed()
        completion(result)
    }

    func togglePlayPause() {
        switch activePlayer {
        case "Music":
            runScript("tell application \"Music\" to playpause")
        case "Spotify":
            runScript("tell application \"Spotify\" to playpause")
        case "Browser":
            let app = frontBrowserApp ?? NSWorkspace.shared.frontmostApplication
            if let app, let appName = Self.chromiumBundles[app.bundleIdentifier ?? ""] {
                let js = "var v=document.querySelector('video');if(v){if(v.paused)v.play();else v.pause();}"
                let script = "tell application \"\(appName)\" to execute front window's active tab javascript \"\(js)\""
                runScript(script)
                return
            }
            fallthrough
        default:
            // Stremio / unknown: send space key to frontmost app
            let src = CGEventSource(stateID: .privateState)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 49, keyDown: false)?.post(tap: .cghidEventTap)
        }
    }

    func seekByOffset(_ offset: Double) {
        let elapsed = liveElapsed()
        switch activePlayer {
        case "Music":
            let p = max(0, min(info.duration, elapsed + offset))
            mrLog("[NowPlaying] Music seek → \(p)")
            runScript("tell application \"Music\" to set player position to \(p)")

        case "Spotify":
            let p = max(0, min(info.duration, elapsed + offset))
            mrLog("[NowPlaying] Spotify seek → \(p)")
            runScript("tell application \"Spotify\" to set player position to \(p)")

        default:
            // Chromium browsers: JS injection
            let app = frontBrowserApp ?? NSWorkspace.shared.frontmostApplication
            if let app, let appName = Self.chromiumBundles[app.bundleIdentifier ?? ""] {
                let js = "var v=document.querySelector('video');if(v)v.currentTime+=(\(offset));"
                let script = "tell application \"\(appName)\" to execute front window's active tab javascript \"\(js)\""
                mrLog("[NowPlaying] Browser seek \(appName) by \(offset)")
                runScript(script)
            } else {
                // Stremio/Electron or unknown: arrow key injection
                let kc: CGKeyCode = offset < 0 ? 123 : 124
                let src = CGEventSource(stateID: .privateState)
                mrLog("[NowPlaying] Arrow key seek kc=\(kc) for offset \(offset)")
                CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: true)?.post(tap: .cghidEventTap)
                CGEvent(keyboardEventSource: src, virtualKey: kc, keyDown: false)?.post(tap: .cghidEventTap)
            }
        }
    }

    private func runScript(_ script: String) {
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", script]
        let errPipe = Pipe()
        t.standardError = errPipe
        t.terminationHandler = { _ in
            let d = errPipe.fileHandleForReading.readDataToEndOfFile()
            if !d.isEmpty { mrLog("[NowPlaying] script error: \(String(data: d, encoding: .utf8) ?? "")") }
        }
        try? t.run()
    }
}
