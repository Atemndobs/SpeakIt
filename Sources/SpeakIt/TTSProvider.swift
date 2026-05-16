import Foundation

struct TTSVoice: Identifiable, Hashable {
    let id: String
    let name: String
    let language: String
    let quality: String  // "Default" | "Enhanced" | "Premium"
}

protocol TTSProvider: AnyObject {
    var id: String { get }
    var displayName: String { get }
    var availableVoices: [TTSVoice] { get }
    var isSpeaking: Bool { get }
    var isPaused: Bool { get }
    var progress: Double { get }                   // 0.0–1.0
    var highlightRange: NSRange? { get }           // current spoken range in the original text
    var onStateChange: (() -> Void)? { get set }
    var onProgress: (() -> Void)? { get set }
    var onHighlight: (() -> Void)? { get set }

    func speak(_ text: String, voice: TTSVoice?, rate: Float)
    func pause()
    func resume()
    func stop()
    func seek(to fraction: Double)  // 0...1
}

extension TTSProvider {
    func seek(to fraction: Double) {}  // default no-op
}
