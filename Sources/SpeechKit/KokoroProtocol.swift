import Foundation

/// The JSON-lines protocol spoken with `scripts/kokoro_daemon.py`.
///
/// A local model is loaded once and kept resident, so unlike the Edge engine
/// there is no process per sentence. That means a long-lived pipe, and a pipe
/// needs a framing that survives partial reads: every message is one line of
/// JSON, and a reply always carries the id of the request it answers.
public enum KokoroProtocol {

    /// Ask for one sentence.
    public struct Request: Codable, Equatable, Sendable {
        public let id: Int
        public let text: String
        public let voice: String
        public let speed: Double
        public let lang: String
        public let out: String

        public init(id: Int, text: String, voice: String, speed: Double, lang: String, out: String) {
            self.id = id
            self.text = text
            self.voice = voice
            self.speed = speed
            self.lang = lang
            self.out = out
        }
    }

    /// Drop queued work below `cancelBefore`. Sent on seek, so a jump backwards
    /// does not wait through synthesis of sentences nobody will hear.
    public struct Cancel: Codable, Equatable, Sendable {
        public let cancelBefore: Int
        public init(cancelBefore: Int) { self.cancelBefore = cancelBefore }
        private enum CodingKeys: String, CodingKey { case cancelBefore = "cancel_before" }
    }

    /// Anything the daemon writes on stdout.
    public enum Message: Equatable, Sendable {
        /// Model resident, synthesis can begin.
        case ready(voices: [String])
        /// A sentence rendered to `path`, `seconds` long.
        case finished(id: Int, path: String, seconds: Double)
        /// A sentence will never arrive. `cancelled` separates "superseded by a
        /// seek", which is expected, from a real failure worth logging.
        case failed(id: Int, error: String?, cancelled: Bool)
        /// The daemon could not start at all.
        case fatal(String)
    }

    /// Parse one line of daemon output.
    ///
    /// Returns nil for anything unrecognised rather than throwing: onnxruntime
    /// and its dependencies are not perfectly disciplined about staying off
    /// stdout, and one stray line must not abort a read that is working.
    public static func parse(line: String) -> Message? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed.hasPrefix("{"), let data = trimmed.data(using: .utf8) else {
            return nil
        }
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }

        if let event = object["event"] as? String {
            switch event {
            case "ready":
                return .ready(voices: object["voices"] as? [String] ?? [])
            case "error":
                return .fatal(object["error"] as? String ?? "unknown error")
            default:
                return nil
            }
        }

        guard let id = object["id"] as? Int else { return nil }

        if object["ok"] as? Bool == true {
            guard let path = object["out"] as? String else { return nil }
            let seconds = (object["seconds"] as? NSNumber)?.doubleValue ?? 0
            return .finished(id: id, path: path, seconds: seconds)
        }

        return .failed(
            id: id,
            error: object["error"] as? String,
            cancelled: object["cancelled"] as? Bool ?? false
        )
    }

    /// Encode a request as the single line to write to the daemon's stdin.
    public static func line<T: Encodable>(_ value: T) -> String? {
        guard let data = try? JSONEncoder().encode(value),
              let json = String(data: data, encoding: .utf8) else { return nil }
        return json + "\n"
    }
}

/// Maps the app's 0...1 rate slider onto Kokoro's speed multiplier.
///
/// Split out and tested for the same reason `PlaybackRate` was in
/// `ElevenLabsKit`: the midpoint has to land on exactly 1.0, and that is the
/// value nearly everyone leaves alone, so an off-by-a-little here is a bug
/// almost no one would think to report.
public enum KokoroSpeed {
    public static let minimum = 0.5
    public static let maximum = 2.0

    /// `rate` is the AVSpeechUtterance-style slider value the app already
    /// stores, where 0.5 is the middle of its range.
    public static func multiplier(for rate: Float) -> Double {
        let normalized = Double(max(0, min(1, rate)))
        // Two straight segments meeting at 1.0 rather than one line across
        // [0.5, 2.0], so the midpoint is exactly normal speed.
        let value = normalized <= 0.5
            ? minimum + (1.0 - minimum) * (normalized / 0.5)
            : 1.0 + (maximum - 1.0) * ((normalized - 0.5) / 0.5)
        return (value * 100).rounded() / 100
    }
}
