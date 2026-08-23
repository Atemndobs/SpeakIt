import AppKit

/// Handles `speakit://` URLs from external callers (e.g. the Chrome extension).
///
/// Supported routes:
///   speakit://speak?text=<url-encoded-text>[&source=<url-encoded-path>][&title=<url-encoded-label>][&origin=claude-code|codex]
///   speakit://stop
///   speakit://next
///   speakit://prev
@MainActor
final class URLSchemeHandler {
    static let shared = URLSchemeHandler()

    func register() {
        NSAppleEventManager.shared().setEventHandler(
            self,
            andSelector: #selector(handleGetURL(event:replyEvent:)),
            forEventClass: AEEventClass(kInternetEventClass),
            andEventID: AEEventID(kAEGetURL)
        )
    }

    @objc private func handleGetURL(event: NSAppleEventDescriptor, replyEvent: NSAppleEventDescriptor) {
        guard let raw = event.paramDescriptor(forKeyword: keyDirectObject)?.stringValue,
              let url = URLComponents(string: raw) else { return }

        switch url.host?.lowercased() {
        case "speak":
            if let origin = url.queryItems?.first(where: { $0.name == "origin" })?.value,
               let source = AutoSpeechSettings.Origin(rawValue: origin),
               !AutoSpeechSettings.isEnabled(for: source) {
                return
            }

            let text = url.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            // Optional source path (a file or its project folder) lets the player
            // surface an "open in Finder" control. Callers: the Stop hook (cwd)
            // and `speakit-cli.sh file` (the file path).
            let source = url.queryItems?.first(where: { $0.name == "source" })?.value
            // Optional human-readable label (repo / page / file name). Lets the
            // player show what's talking so you can map it back to the right chat
            // or page. Falls back to the source basename or a text snippet.
            let title = url.queryItems?.first(where: { $0.name == "title" })?.value
            TTSEngine.shared.speak(trimmed, source: source, title: title)
        case "stop":
            TTSEngine.shared.stop()
        case "next":
            TTSEngine.shared.nextChunk()
        case "prev", "previous":
            TTSEngine.shared.previousChunk()
        default:
            break
        }
    }
}
