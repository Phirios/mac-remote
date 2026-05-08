import Foundation
import CoreGraphics
import ApplicationServices
import AppKit
import AudioToolbox

/// Posts CGEvents in response to messages from the iPhone client.
/// Mirrors the Python server's logic line-for-line.
@MainActor
final class EventInjector {
    private var heldButtons: Set<MRMessage.MouseButton> = []

    func handle(_ msg: MRMessage) {
        switch msg {
        case .move(let dx, let dy):
            moveRelative(dx: CGFloat(dx), dy: CGFloat(dy))
        case .mouseDown(let b, let n):
            buttonPress(b, down: true, count: n)
        case .mouseUp(let b, let n):
            buttonPress(b, down: false, count: n)
        case .click(let b, let n):
            buttonPress(b, down: true, count: n)
            buttonPress(b, down: false, count: n)
        case .scroll(let dx, let dy):
            scroll(dx: dx, dy: dy)
        case .key(let k, let mods, let down):
            postKey(k, mods: mods, down: down)
        case .combo(let k, let mods):
            postCombo(k, mods: mods)
        case .text(let s):
            type(s)
        case .media(let k):
            postMediaKey(k)
        case .nowPlaying:
            break
        case .selectSource:
            break
        case .availableSources:
            break
        }
    }

    // MARK: cursor

    private func cursorLocation() -> CGPoint {
        let e = CGEvent(source: nil)
        return e?.location ?? .zero
    }

    private func moveRelative(dx: CGFloat, dy: CGFloat) {
        let cur = cursorLocation()
        let p = CGPoint(x: cur.x + dx, y: cur.y + dy)
        let type: CGEventType
        let buttonForDrag: CGMouseButton
        if let held = heldButtons.first {
            switch held {
            case .left:   type = .leftMouseDragged;  buttonForDrag = .left
            case .right:  type = .rightMouseDragged; buttonForDrag = .right
            case .middle: type = .otherMouseDragged; buttonForDrag = .center
            }
        } else {
            type = .mouseMoved
            buttonForDrag = .left
        }
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: p, mouseButton: buttonForDrag) else { return }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: buttons

    private func buttonPress(_ b: MRMessage.MouseButton, down: Bool, count: Int) {
        let (downType, upType, btn): (CGEventType, CGEventType, CGMouseButton) = {
            switch b {
            case .left:   return (.leftMouseDown,  .leftMouseUp,  .left)
            case .right:  return (.rightMouseDown, .rightMouseUp, .right)
            case .middle: return (.otherMouseDown, .otherMouseUp, .center)
            }
        }()
        let type = down ? downType : upType
        guard let ev = CGEvent(mouseEventSource: nil, mouseType: type,
                               mouseCursorPosition: cursorLocation(), mouseButton: btn) else { return }
        if count > 1 {
            ev.setIntegerValueField(.mouseEventClickState, value: Int64(count))
        }
        ev.post(tap: .cghidEventTap)
        if down { heldButtons.insert(b) } else { heldButtons.remove(b) }
    }

    // MARK: scroll

    private func scroll(dx: Int, dy: Int) {
        guard let ev = CGEvent(scrollWheelEvent2Source: nil,
                               units: .pixel,
                               wheelCount: 2,
                               wheel1: Int32(dy), wheel2: Int32(dx), wheel3: 0) else { return }
        ev.post(tap: .cghidEventTap)
    }

    // MARK: keyboard

    private func postKey(_ key: String, mods: [MRMessage.Modifier], down: Bool) {
        guard let kc = Self.keycodes[key.lowercased()] else {
            NSLog("[EventInjector] unknown key: \(key)"); return
        }
        var flags: CGEventFlags = []
        for m in mods {
            switch m {
            case .cmd:   flags.insert(.maskCommand)
            case .shift: flags.insert(.maskShift)
            case .opt:   flags.insert(.maskAlternate)
            case .ctrl:  flags.insert(.maskControl)
            }
        }
        guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: CGKeyCode(kc), keyDown: down) else { return }
        if !flags.isEmpty { ev.flags = flags }
        ev.post(tap: .cghidEventTap)
    }

    // For modifier combos (ctrl+arrow, cmd+letter, etc.) use osascript which goes through
    // the proper system event path and reliably triggers Mission Control and other OS shortcuts.
    // Plain keys (no mods) fall through to CGEvent directly.
    private func postCombo(_ key: String, mods: [MRMessage.Modifier]) {
        guard let kc = Self.keycodes[key.lowercased()] else {
            NSLog("[EventInjector] unknown key: \(key)"); return
        }
        guard !mods.isEmpty else {
            let src = CGEventSource(stateID: .privateState)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kc), keyDown: false)?.post(tap: .cghidEventTap)
            return
        }
        let modStr = mods.map { m -> String in
            switch m {
            case .cmd:   return "command down"
            case .shift: return "shift down"
            case .opt:   return "option down"
            case .ctrl:  return "control down"
            }
        }.joined(separator: ", ")
        let t = Process()
        t.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        t.arguments = ["-e", "tell application \"System Events\" to key code \(kc) using {\(modStr)}"]
        try? t.run()
    }

    private func postMediaKey(_ key: String) {
        switch key {
        case "volup":   adjustVolume(0.06)
        case "voldown": adjustVolume(-0.06)
        case "mute":    toggleMute()
        default:
            let keyCodes: [String: Int32] = ["play": 16, "next": 17, "prev": 18]
            guard let code = keyCodes[key] else { return }
            let flags = NSEvent.ModifierFlags(rawValue: 0xa00)
            for data1 in [(code << 16) | (0xa << 8), (code << 16) | (0xb << 8) | 1] {
                NSEvent.otherEvent(with: .systemDefined, location: .zero, modifierFlags: flags,
                                   timestamp: 0, windowNumber: 0, context: nil,
                                   subtype: 8, data1: Int(data1), data2: -1)?.cgEvent?.post(tap: .cghidEventTap)
            }
        }
    }

    private func defaultOutputDevice() -> AudioDeviceID? {
        var dev = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
                                             mScope: kAudioObjectPropertyScopeGlobal,
                                             mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                         &addr, 0, nil, &size, &dev) == noErr else { return nil }
        return dev
    }

    private func adjustVolume(_ delta: Float) {
        guard let dev = defaultOutputDevice() else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        var vol: Float32 = 0
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &vol) == noErr else { return }
        vol = max(0, min(1, vol + delta))
        AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &vol)
    }

    private func toggleMute() {
        guard let dev = defaultOutputDevice() else { return }
        var addr = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyMute,
                                             mScope: kAudioDevicePropertyScopeOutput,
                                             mElement: kAudioObjectPropertyElementMain)
        var muted: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &muted) == noErr else { return }
        muted = muted == 0 ? 1 : 0
        AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &muted)
    }

    private func type(_ s: String) {
        for ch in s {
            for down in [true, false] {
                guard let ev = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: down) else { continue }
                let utf16 = Array(String(ch).utf16)
                ev.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                ev.post(tap: .cghidEventTap)
            }
        }
    }

    // macOS virtual keycodes (subset). Extend as needed.
    static let keycodes: [String: Int] = [
        "a":0,"s":1,"d":2,"f":3,"h":4,"g":5,"z":6,"x":7,"c":8,"v":9,
        "b":11,"q":12,"w":13,"e":14,"r":15,"y":16,"t":17,
        "1":18,"2":19,"3":20,"4":21,"6":22,"5":23,"=":24,"9":25,"7":26,
        "-":27,"8":28,"0":29,"]":30,"o":31,"u":32,"[":33,"i":34,"p":35,
        "l":37,"j":38,"'":39,"k":40,";":41,"\\":42,",":43,"/":44,
        "n":45,"m":46,".":47,"`":50,
        "return":36,"enter":36,"tab":48,"space":49," ":49,
        "delete":51,"backspace":51,"escape":53,"esc":53,
        "command":55,"cmd":55,"shift":56,"capslock":57,
        "option":58,"opt":58,"alt":58,"control":59,"ctrl":59,
        "right":124,"left":123,"down":125,"up":126,
        "f1":122,"f2":120,"f3":99,"f4":118,"f5":96,"f6":97,
        "f7":98,"f8":100,"f9":101,"f10":109,"f11":103,"f12":111,
        "home":115,"end":119,"pageup":116,"pagedown":121,"fwd_delete":117,
    ]
}
