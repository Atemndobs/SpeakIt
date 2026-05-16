import AppKit

/// Receives macOS Services menu invocations. Wired up in AppDelegate via
/// `NSApp.servicesProvider`. The selector + `NSSendTypes` are declared in
/// `scripts/Info.plist` under `NSServices`.
final class ServiceProvider: NSObject {
    @objc func speakSelection(_ pasteboard: NSPasteboard,
                              userData: String,
                              error errorPointer: AutoreleasingUnsafeMutablePointer<NSString>) {
        guard let text = pasteboard.string(forType: .string),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            errorPointer.pointee = "No text was selected" as NSString
            return
        }
        Task { @MainActor in
            TTSEngine.shared.speak(text)
        }
    }
}
