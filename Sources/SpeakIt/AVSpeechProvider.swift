import AVFoundation

final class AVSpeechProvider: NSObject, TTSProvider, AVSpeechSynthesizerDelegate {
    let id = "av-speech"
    let displayName = "Apple Speech"

    private let synth = AVSpeechSynthesizer()
    private var totalChars = 0
    private var charOffset = 0  // start offset in originalText when seeked
    private var originalText = ""
    private var lastVoice: AVSpeechSynthesisVoice?
    private var lastRate: Float = AVSpeechUtteranceDefaultSpeechRate
    private(set) var progress: Double = 0
    private(set) var highlightRange: NSRange? = nil

    var onStateChange: (() -> Void)?
    var onProgress: (() -> Void)?
    var onHighlight: (() -> Void)?

    override init() {
        super.init()
        synth.delegate = self
    }

    var availableVoices: [TTSVoice] {
        AVSpeechSynthesisVoice.speechVoices()
            .filter { $0.language.hasPrefix("en") }
            .sorted {
                if $0.quality.rawValue != $1.quality.rawValue {
                    return $0.quality.rawValue > $1.quality.rawValue
                }
                return $0.name < $1.name
            }
            .map {
                TTSVoice(
                    id: $0.identifier,
                    name: $0.name,
                    language: $0.language,
                    quality: qualityLabel($0.quality)
                )
            }
    }

    private func qualityLabel(_ q: AVSpeechSynthesisVoiceQuality) -> String {
        switch q {
        case .premium: return "Premium"
        case .enhanced: return "Enhanced"
        default: return "Default"
        }
    }

    func speak(_ text: String, voice: TTSVoice?, rate: Float) {
        stop()
        originalText = text
        totalChars = text.count
        charOffset = 0
        if let vid = voice?.id {
            lastVoice = AVSpeechSynthesisVoice(identifier: vid)
        } else {
            lastVoice = nil
        }
        lastRate = rate

        let utterance = AVSpeechUtterance(string: text)
        if let v = lastVoice { utterance.voice = v }
        utterance.rate = rate
        progress = 0
        onProgress?()
        synth.speak(utterance)
    }

    func pause() { synth.pauseSpeaking(at: .word) }
    func resume() { synth.continueSpeaking() }
    func stop() {
        synth.stopSpeaking(at: .immediate)
        progress = 0
        highlightRange = nil
        onProgress?()
        onHighlight?()
    }

    func seek(to fraction: Double) {
        guard totalChars > 0, !originalText.isEmpty else { return }
        let target = max(0, min(totalChars - 1, Int(fraction * Double(totalChars))))
        let startIdx = originalText.index(originalText.startIndex, offsetBy: target)
        let remainder = String(originalText[startIdx...])
        guard !remainder.isEmpty else {
            synth.stopSpeaking(at: .immediate)
            progress = 1
            onProgress?()
            return
        }
        synth.stopSpeaking(at: .immediate)
        charOffset = target

        let utterance = AVSpeechUtterance(string: remainder)
        if let v = lastVoice { utterance.voice = v }
        utterance.rate = lastRate
        progress = Double(target) / Double(totalChars)
        onProgress?()
        synth.speak(utterance)
    }

    var isSpeaking: Bool { synth.isSpeaking }
    var isPaused: Bool { synth.isPaused }

    func speechSynthesizer(_ s: AVSpeechSynthesizer, didStart _: AVSpeechUtterance) { onStateChange?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didFinish _: AVSpeechUtterance) {
        progress = 1
        onProgress?()
        onStateChange?()
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didPause _: AVSpeechUtterance) { onStateChange?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didContinue _: AVSpeechUtterance) { onStateChange?() }
    func speechSynthesizer(_ s: AVSpeechSynthesizer, didCancel _: AVSpeechUtterance) {
        onStateChange?()
    }
    func speechSynthesizer(_ s: AVSpeechSynthesizer,
                           willSpeakRangeOfSpeechString characterRange: NSRange,
                           utterance: AVSpeechUtterance) {
        guard totalChars > 0 else { return }
        let absoluteLoc = charOffset + characterRange.location
        let pos = min(totalChars, absoluteLoc + characterRange.length)
        progress = Double(pos) / Double(totalChars)
        onProgress?()

        highlightRange = NSRange(location: absoluteLoc, length: characterRange.length)
        onHighlight?()
    }
}
