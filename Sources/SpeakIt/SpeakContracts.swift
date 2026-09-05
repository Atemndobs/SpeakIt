import Foundation

enum SpeakSource: String, Codable {
    case unknown
    case cli
    case plugin
    case extensionButton
    case contextMenu
    case selection
    case responseAction
    case localAPI
}

enum SpeakAction: String, Codable {
    case replace
    case enqueue
    case interrupt
}

struct SpeakRequest: Codable {
    var text: String
    /// Category of caller, for logging and for choosing defaults. Not a path:
    /// see `sourcePath`, which the URL scheme spells `source`.
    var source: SpeakSource
    var action: SpeakAction
    var sanitizeMarkdown: Bool
    /// Filesystem path of what is being read, a file or its project folder.
    /// Drives the player's "open in reader" control. nil for ad-hoc reads such
    /// as a selection or a clipboard copy, which have nothing on disk.
    var sourcePath: String?
    /// Human-readable label for the player, so you can tell which chat, page or
    /// file is talking without expanding it.
    var title: String?

    init(
        text: String,
        source: SpeakSource = .unknown,
        action: SpeakAction = .replace,
        sanitizeMarkdown: Bool = true,
        sourcePath: String? = nil,
        title: String? = nil
    ) {
        self.text = text
        self.source = source
        self.action = action
        self.sanitizeMarkdown = sanitizeMarkdown
        self.sourcePath = sourcePath
        self.title = title
    }
}
