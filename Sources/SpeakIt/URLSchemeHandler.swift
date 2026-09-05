import AppKit

/// Handles `speakit://` URLs from external callers (e.g. the Chrome extension).
///
/// Supported routes:
///   speakit://speak?text=<url-encoded-text>[&source=<url-encoded-path>][&title=<url-encoded-label>][&origin=claude-code|codex][&action=replace|enqueue|interrupt][&requestSource=<name>][&sanitizeMarkdown=0|1]
///   speakit://speak-response?...   same parameters, defaults the request source to responseAction
///   speakit://speak-selection?...  same parameters, defaults the request source to selection
///   speakit://expand
///   speakit://collapse
///   speakit://stop
///   speakit://next
///   speakit://prev
///
/// Note on two things both once called "source". `source` is a filesystem path,
/// used by the player's "open in reader" control. The `SpeakRequest` field of
/// the same name is a category (selection, plugin, localAPI) used for logging
/// and defaults. They collided when these branches met; the query parameter for
/// the latter is `requestSource`, and renaming it here rather than the path was
/// deliberate, because `source=<path>` is already in the hooks, the Chrome
/// extension and the documented URL contract.
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
            speak(url.queryItems, defaultRequestSource: .unknown)
        case "speak-response":
            speak(url.queryItems, defaultRequestSource: .responseAction)
        case "speak-selection":
            speak(url.queryItems, defaultRequestSource: .selection)
        case "expand":
            BubbleWindow.shared.show()
            BubbleWindow.shared.setExpanded(true)
        case "collapse":
            BubbleWindow.shared.setExpanded(false)
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

    /// One path for all three speak routes; they differ only in what they
    /// assume when `requestSource` is absent.
    private func speak(_ items: [URLQueryItem]?, defaultRequestSource: SpeakSource) {
        // The auto-speech kill switch, checked before anything else. It gates
        // every speak route, not just `speak`, because the Stop hook now uses
        // `speak-response` and turning Claude Code speech off has to keep
        // working.
        if let origin = value(items, "origin"),
           let gate = AutoSpeechSettings.Origin(rawValue: origin),
           !AutoSpeechSettings.isEnabled(for: gate) {
            return
        }

        SpeakRequestHandler.shared.handle(
            SpeakRequest(
                text: value(items, "text") ?? "",
                source: SpeakSource(rawValue: value(items, "requestSource") ?? "") ?? defaultRequestSource,
                action: SpeakAction(rawValue: (value(items, "action") ?? "").lowercased()) ?? .replace,
                sanitizeMarkdown: parseSanitizeMarkdown(items, fallback: true),
                // Filesystem path of what is being read, so the player can offer
                // "open in reader". Set by the Stop hook (the plan folder) and
                // by `speakit-cli.sh file` (the file itself).
                sourcePath: value(items, "source"),
                // Human-readable label, so you can tell which chat or file is
                // talking without expanding the player.
                title: value(items, "title")
            )
        )
    }

    private func value(_ items: [URLQueryItem]?, _ name: String) -> String? {
        items?.first { $0.name == name }?.value
    }

    private func parseSanitizeMarkdown(_ items: [URLQueryItem]?, fallback: Bool) -> Bool {
        guard let raw = value(items, "sanitizeMarkdown")?.lowercased() else { return fallback }
        if ["0", "false", "no"].contains(raw) { return false }
        if ["1", "true", "yes"].contains(raw) { return true }
        return fallback
    }
}
