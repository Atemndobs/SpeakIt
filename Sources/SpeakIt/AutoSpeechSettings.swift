import Foundation

enum AutoSpeechSettings {
    enum Origin: String {
        case claudeCode = "claude-code"
        case codex = "codex"
    }

    enum Keys {
        /// Auto-speak Claude Code responses arriving via the `speakit://` Stop
        /// hook. Independent of clipboard/copy speaking (`ClipboardWatcher`).
        static let claudeCodeEnabled = "autoSpeech.claudeCode.enabled"
    }

    static func isEnabled(for origin: Origin) -> Bool {
        switch origin {
        case .claudeCode:
            return UserDefaults.standard.bool(forKey: Keys.claudeCodeEnabled)
        case .codex:
            return UserDefaults.standard.bool(forKey: CodexTranscriptWatcher.Keys.enabled)
        }
    }
}
