import AppKit

/// Handles `speakit://` URLs from external callers (e.g. the Chrome extension).
///
/// Supported routes:
///   speakit://speak?text=<url-encoded-text>
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
            let text = url.queryItems?.first(where: { $0.name == "text" })?.value ?? ""
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            TTSEngine.shared.speak(trimmed)
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
