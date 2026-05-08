import SwiftUI
import UIKit

/// A nearly-invisible UITextField that becomes first responder when toggled,
/// so the iOS software keyboard appears and we can capture keystrokes.
///
/// Approach:
/// - Plain typed characters → `text` message (handled by the server's
///   UnicodeString path, supports non-ASCII).
/// - Backspace → `combo: delete`.
/// - Hardware keyboards / external keyboard shortcuts: handled separately
///   via UIKeyCommand on the host view controller (SwiftUI's `.keyboardShortcut`
///   doesn't surface modifier-only or function keys reliably).
struct KeyboardCapture: UIViewRepresentable {
    @Binding var isActive: Bool
    var onText: (String) -> Void
    var onBackspace: () -> Void
    var onReturn: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onText: onText, onBackspace: onBackspace, onReturn: onReturn)
    }

    func makeUIView(context: Context) -> CaptureField {
        let f = CaptureField(frame: .zero)
        f.delegate = context.coordinator
        f.autocorrectionType = .no
        f.autocapitalizationType = .none
        f.spellCheckingType = .no
        f.smartDashesType = .no
        f.smartQuotesType = .no
        f.smartInsertDeleteType = .no
        f.keyboardType = .default
        f.inputAssistantItem.leadingBarButtonGroups = []
        f.inputAssistantItem.trailingBarButtonGroups = []
        f.tintColor = .clear
        f.textColor = .clear
        f.backgroundColor = .clear
        f.addTarget(context.coordinator, action: #selector(Coordinator.editingChanged(_:)), for: .editingChanged)
        f.backspaceCallback = context.coordinator.onBackspace
        return f
    }

    func updateUIView(_ uiView: CaptureField, context: Context) {
        if isActive {
            if !uiView.isFirstResponder { uiView.becomeFirstResponder() }
        } else {
            if uiView.isFirstResponder { uiView.resignFirstResponder() }
        }
    }

    final class Coordinator: NSObject, UITextFieldDelegate {
        let onText: (String) -> Void
        let onBackspace: () -> Void
        let onReturn: () -> Void
        init(onText: @escaping (String) -> Void, onBackspace: @escaping () -> Void, onReturn: @escaping () -> Void) {
            self.onText = onText
            self.onBackspace = onBackspace
            self.onReturn = onReturn
        }

        // Intercept text inserts before iOS commits them to the field.
        // Backspace is handled by CaptureField.deleteBackward() instead,
        // because shouldChangeCharactersIn is NOT called when the field is empty.
        func textField(_ textField: UITextField, shouldChangeCharactersIn range: NSRange, replacementString string: String) -> Bool {
            if !string.isEmpty {
                onText(string)
            }
            return false  // never actually mutate the invisible field
        }

        @objc func editingChanged(_ tf: UITextField) {
            // Defensive: clear any text that slipped through (e.g. from dictation)
            if tf.text?.isEmpty == false {
                if let t = tf.text { onText(t) }
                tf.text = ""
            }
        }

        func textFieldShouldReturn(_ textField: UITextField) -> Bool {
            onReturn()
            return false
        }
    }
}

/// UITextField subclass that overrides `keyCommands` to forward modifier
/// shortcuts from a connected hardware keyboard (e.g. iPad Magic Keyboard,
/// or a Bluetooth keyboard paired with the iPhone).
final class CaptureField: UITextField {
    var backspaceCallback: (() -> Void)?

    override var canBecomeFirstResponder: Bool { true }

    // Called for every backspace press, even when the field is empty.
    // shouldChangeCharactersIn is skipped by iOS when there's nothing to delete.
    override func deleteBackward() {
        backspaceCallback?()
    }

    // Static set of common shortcuts to forward. The server's `combo` handler
    // receives the (key, mods) pair and re-issues it on the Mac.
    override var keyCommands: [UIKeyCommand]? {
        // Forward Cmd+letter and arrows; extend as desired.
        var cmds: [UIKeyCommand] = []
        let letters = "abcdefghijklmnopqrstuvwxyz0123456789"
        for ch in letters {
            for mods in [UIKeyModifierFlags.command, [.command, .shift], [.command, .alternate], [.control], [.alternate]] {
                cmds.append(UIKeyCommand(input: String(ch), modifierFlags: mods, action: #selector(handleKey(_:))))
            }
        }
        for arrow in [UIKeyCommand.inputUpArrow, UIKeyCommand.inputDownArrow, UIKeyCommand.inputLeftArrow, UIKeyCommand.inputRightArrow] {
            cmds.append(UIKeyCommand(input: arrow, modifierFlags: [], action: #selector(handleKey(_:))))
            cmds.append(UIKeyCommand(input: arrow, modifierFlags: .command, action: #selector(handleKey(_:))))
            cmds.append(UIKeyCommand(input: arrow, modifierFlags: .alternate, action: #selector(handleKey(_:))))
            cmds.append(UIKeyCommand(input: arrow, modifierFlags: .shift, action: #selector(handleKey(_:))))
        }
        cmds.append(UIKeyCommand(input: UIKeyCommand.inputEscape, modifierFlags: [], action: #selector(handleKey(_:))))
        return cmds
    }

    @objc private func handleKey(_ cmd: UIKeyCommand) {
        guard let input = cmd.input else { return }
        let mapped: String
        switch input {
        case UIKeyCommand.inputUpArrow:    mapped = "up"
        case UIKeyCommand.inputDownArrow:  mapped = "down"
        case UIKeyCommand.inputLeftArrow:  mapped = "left"
        case UIKeyCommand.inputRightArrow: mapped = "right"
        case UIKeyCommand.inputEscape:     mapped = "escape"
        default: mapped = input.lowercased()
        }
        var mods: [String] = []
        if cmd.modifierFlags.contains(.command)   { mods.append("cmd") }
        if cmd.modifierFlags.contains(.shift)     { mods.append("shift") }
        if cmd.modifierFlags.contains(.alternate) { mods.append("opt") }
        if cmd.modifierFlags.contains(.control)   { mods.append("ctrl") }
        // Send via NotificationCenter so SwiftUI side can route it through AppState.
        NotificationCenter.default.post(name: .macRemoteHardwareKey, object: nil, userInfo: ["key": mapped, "mods": mods])
    }
}

extension Notification.Name {
    static let macRemoteHardwareKey = Notification.Name("MacRemoteHardwareKey")
}
