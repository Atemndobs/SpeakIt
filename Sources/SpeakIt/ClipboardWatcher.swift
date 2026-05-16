import AppKit

/// Watches `NSPasteboard.general.changeCount` and speaks the new clipboard
/// contents whenever a copy happens while a watched app is frontmost.
///
/// Polling-based because AppKit doesn't expose a notification for pasteboard
/// changes. 10Hz is responsive without measurable CPU/battery impact.
@MainActor
final class ClipboardWatcher {
    static let shared = ClipboardWatcher()

    enum Keys {
        static let enabled = "clipboardWatcher.enabled"
        static let bundleIDs = "clipboardWatcher.bundleIDs"
    }

    static let defaultBundleIDs = ["com.anthropic.claudefordesktop"]

    private var timer: Timer?
    private var lastChangeCount: Int = NSPasteboard.general.changeCount

    private var watchedBundleIDs: Set<String> {
        let stored = UserDefaults.standard.stringArray(forKey: Keys.bundleIDs)
        return Set(stored ?? Self.defaultBundleIDs)
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            newValue ? start() : stop()
        }
    }

    func bootstrap() {
        if isEnabled { start() }
    }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    private func tick() {
        let pb = NSPasteboard.general
        let count = pb.changeCount
        guard count != lastChangeCount else { return }
        lastChangeCount = count

        guard let frontID = NSWorkspace.shared.frontmostApplication?.bundleIdentifier,
              watchedBundleIDs.contains(frontID) else { return }

        guard let raw = pb.string(forType: .string), !raw.isEmpty else { return }
        let cleaned = Self.stripMarkdown(raw)
        guard !cleaned.isEmpty else { return }
        TTSEngine.shared.speak(cleaned)
    }

    /// Strip common markdown syntax so TTS doesn't say "asterisk asterisk".
    /// Mirrors the Python stripper used by the Claude Code Stop hook.
    static func stripMarkdown(_ input: String) -> String {
        // Tables get a line-based pass first (regex with lambda replacement
        // isn't ergonomic in NSRegularExpression): drop alignment rows, flatten
        // body rows into comma-separated text so TTS reads them as prose.
        let separatorRow = try? NSRegularExpression(
            pattern: #"^[ \t]*\|?[ \t|:\-]*-{2,}[ \t|:\-]*\|?[ \t]*$"#
        )
        let bodyRow = try? NSRegularExpression(
            pattern: #"^[ \t]*\|(.+?)\|[ \t]*$"#
        )
        let preprocessed = input.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
            let s = String(line)
            let range = NSRange(s.startIndex..., in: s)
            if separatorRow?.firstMatch(in: s, range: range) != nil { return "" }
            if let m = bodyRow?.firstMatch(in: s, range: range), m.numberOfRanges > 1,
               let inner = Range(m.range(at: 1), in: s) {
                let cells = s[inner].split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
                return cells.filter { !$0.isEmpty }.joined(separator: ", ")
            }
            return s
        }.joined(separator: "\n")

        var t = preprocessed
        let passes: [(String, String, NSRegularExpression.Options)] = [
            (#"```[\s\S]*?```"#, "", []),                     // fenced code blocks
            (#"`([^`]*)`"#, "$1", []),                        // inline code
            (#"!\[[^\]]*\]\([^)]*\)"#, "", []),               // images
            (#"\[([^\]]+)\]\([^)]+\)"#, "$1", []),            // links → text
            (#"(?m)^\s{0,3}#{1,6}\s+"#, "", []),              // headers
            (#"(?m)^\s{0,3}>\s?"#, "", []),                   // blockquotes
            (#"(?m)^\s*[-*+]\s+"#, "", []),                   // bullets
            (#"(?m)^\s*\d+\.\s+"#, "", []),                   // numbered lists
            (#"\*\*([^*]+)\*\*"#, "$1", []),                  // bold
            (#"(?<!\*)\*([^*\n]+)\*(?!\*)"#, "$1", []),       // italic *
            (#"(?<!_)_([^_\n]+)_(?!_)"#, "$1", []),           // italic _
            (#"~~([^~]+)~~"#, "$1", []),                      // strikethrough
            (#"(?m)^\s*[-*_]{3,}\s*$"#, "", []),              // horizontal rule
            (#"<[^>]+>"#, "", []),                            // html tags
            (#"\n{3,}"#, "\n\n", []),
        ]
        for (pattern, replacement, opts) in passes {
            guard let re = try? NSRegularExpression(pattern: pattern, options: opts) else { continue }
            let range = NSRange(t.startIndex..., in: t)
            t = re.stringByReplacingMatches(in: t, options: [], range: range, withTemplate: replacement)
        }
        return t.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
