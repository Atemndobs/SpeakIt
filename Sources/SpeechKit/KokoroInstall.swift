import Foundation

/// Where the local Kokoro engine lives on disk, and whether it is usable.
///
/// Kept as a pure value type so the "is it installed, and if not what is
/// missing" question can be tested without a filesystem full of 325 MB models.
/// `EdgeTTSProvider` answers the same question with a bare
/// `isExecutableFile` check and can only say yes or no; here a partial install
/// (venv present, weights half-downloaded) needs to name what is absent,
/// because the fix differs.
public struct KokoroInstall: Equatable, Sendable {

    public enum Status: Equatable, Sendable {
        case ready
        /// Setup was never run.
        case notInstalled
        /// Setup ran but left something behind. Carries what is missing.
        case incomplete(missing: [String])
    }

    public let root: URL
    public let python: URL
    public let daemon: URL
    public let model: URL
    public let voices: URL

    /// Default layout, matching `scripts/kokoro-setup.sh`.
    public init(root: URL) {
        self.root = root
        self.python = root.appendingPathComponent("venv/bin/python")
        self.daemon = root.appendingPathComponent("kokoro_daemon.py")
        self.model = root.appendingPathComponent("kokoro.onnx")
        self.voices = root.appendingPathComponent("voices.bin")
    }

    public static func standard(home: URL = URL(fileURLWithPath: NSHomeDirectory())) -> KokoroInstall {
        KokoroInstall(root: home.appendingPathComponent(".speakit/kokoro"))
    }

    /// Override the bundled daemon script. `build-app.sh` puts a copy inside
    /// SpeakIt.app so an app update ships a new daemon without the user
    /// re-running setup; the weights and virtualenv stay in the home directory
    /// because they are large and version-independent.
    public func withDaemon(_ url: URL) -> KokoroInstall {
        var copy = self
        copy.daemonOverride = url
        return copy
    }

    private var daemonOverride: URL?

    public var daemonScript: URL { daemonOverride ?? daemon }

    /// Classify the install. `exists` is injected so this is testable.
    public func status(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Status {
        let checks: [(String, URL)] = [
            ("Python environment", python),
            ("synthesis daemon", daemonScript),
            ("model weights", model),
            ("voice pack", voices),
        ]
        let missing = checks.filter { !exists($0.1) }.map(\.0)

        if missing.count == checks.count { return .notInstalled }
        if missing.isEmpty { return .ready }
        return .incomplete(missing: missing)
    }

    public func isReady(exists: (URL) -> Bool = { FileManager.default.fileExists(atPath: $0.path) }) -> Bool {
        status(exists: exists) == .ready
    }
}

extension KokoroInstall.Status {
    /// A sentence for the menu bar. Written to say what to do next, because
    /// "not installed" on its own sends people to the issue tracker.
    public var explanation: String? {
        switch self {
        case .ready:
            return nil
        case .notInstalled:
            return "Not installed. Run scripts/kokoro-setup.sh to download the model (about 350 MB)."
        case .incomplete(let missing):
            let list = ListFormatter.localizedString(byJoining: missing)
            return "Install incomplete, missing \(list). Re-run scripts/kokoro-setup.sh."
        }
    }
}
