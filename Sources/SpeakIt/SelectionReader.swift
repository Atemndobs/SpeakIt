import AppKit

@MainActor
final class SelectionReader {
    static let shared = SelectionReader()

    func captureAndSpeak() async {
        guard AccessibilityPermission.check(prompt: false) else {
            AccessibilityPermission.openSettings()
            return
        }

        let pasteboard = NSPasteboard.general
        let oldString = pasteboard.string(forType: .string)
        let oldChangeCount = pasteboard.changeCount

        sendCommandC()

        // Poll up to ~400ms for the clipboard to update
        var captured: String?
        for _ in 0..<40 {
            try? await Task.sleep(nanoseconds: 10_000_000)
            if pasteboard.changeCount != oldChangeCount {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        // Restore previous clipboard contents shortly after
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
            if pasteboard.changeCount != oldChangeCount {
                pasteboard.clearContents()
                if let old = oldString { pasteboard.setString(old, forType: .string) }
            }
        }

        guard let text = captured, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return
        }
        TTSEngine.shared.speak(text)
    }

    private func sendCommandC() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let kVK_ANSI_C: CGKeyCode = 0x08
        let down = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_C, keyDown: true)
        let up   = CGEvent(keyboardEventSource: src, virtualKey: kVK_ANSI_C, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }
}
