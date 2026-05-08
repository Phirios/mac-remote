import Foundation
import ApplicationServices
import AppKit

/// Macs require Accessibility permission for synthetic input. Without it
/// `CGEvent.post` silently drops events. We check at startup and prompt
/// the user to grant it (then deep-link to System Settings).
enum AccessibilityHelper {
    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Triggers the system prompt; user must approve in System Settings →
    /// Privacy & Security → Accessibility, then quit and relaunch the app
    /// (macOS doesn't refresh the trust state for a running process).
    static func promptForTrust() {
        let opts = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opts)
    }

    /// Open the Accessibility pane directly so users don't hunt for it.
    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }
}
