import SwiftUI
import AVFoundation

@MainActor
final class TTSEngine: ObservableObject {
    static let shared = TTSEngine()

    @Published var providers: [TTSProvider] = []
    @Published var activeProviderId: String {
        didSet { UserDefaults.standard.set(activeProviderId, forKey: Keys.activeProviderId) }
    }
    @Published var selectedVoiceId: String? {
        didSet { UserDefaults.standard.set(selectedVoiceId, forKey: voiceKey(for: activeProviderId)) }
    }
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(Double(rate), forKey: Keys.rate) }
    }
    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var progress: Double = 0
    @Published var currentText: String = ""
    @Published var highlightRange: NSRange?

    // Natural-break navigation: text is read as one continuous utterance; skip
    // buttons jump the cursor to the next/previous sentence-or-paragraph break.
    private var breakpoints: [Int] = []  // character offsets (UTF16) into currentText

    private enum Keys {
        static let activeProviderId = "SpeakIt.activeProviderId"
        static let rate = "SpeakIt.rate"
    }
    private static func voiceKey(for providerId: String) -> String { "SpeakIt.voice.\(providerId)" }
    private func voiceKey(for providerId: String) -> String { Self.voiceKey(for: providerId) }

    private static let defaultProvider = "edge-tts"
    private static let defaultEdgeVoice = "en-GB-SoniaNeural"

    private init() {
        let av = AVSpeechProvider()
        let edge = EdgeTTSProvider()

        // --- Step 1: initialize ALL stored properties before referencing self ---
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: Keys.activeProviderId) ?? Self.defaultProvider
        // NSNumber<->Float bridging can return nil unexpectedly; round-trip via Double.
        let hasStoredRate = defaults.object(forKey: Keys.rate) != nil
        let storedRate: Float? = hasStoredRate ? Float(defaults.double(forKey: Keys.rate)) : nil
        let active: TTSProvider = (provider == edge.id) ? edge : av
        let storedVoice = defaults.string(forKey: Self.voiceKey(for: provider))

        let resolvedVoiceId: String? = {
            if let storedVoice, active.availableVoices.contains(where: { $0.id == storedVoice }) {
                return storedVoice
            }
            if provider == "edge-tts",
               edge.availableVoices.contains(where: { $0.id == Self.defaultEdgeVoice }) {
                return Self.defaultEdgeVoice
            }
            return Self.bestDefaultVoiceId(for: active)
        }()

        self.providers = [av, edge]
        self.activeProviderId = provider
        self.rate = storedRate ?? AVSpeechUtteranceDefaultSpeechRate
        self.selectedVoiceId = resolvedVoiceId

        // --- Step 2: now self is fully initialized; safe to capture in closures ---
        let stateHandler: () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshState() }
        }
        let progressHandler: () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshProgress() }
        }
        let highlightHandler: () -> Void = { [weak self] in
            Task { @MainActor in self?.refreshHighlight() }
        }
        av.onStateChange = stateHandler
        av.onProgress = progressHandler
        av.onHighlight = highlightHandler
        edge.onStateChange = stateHandler
        edge.onProgress = progressHandler
        edge.onHighlight = highlightHandler
    }

    var activeProvider: TTSProvider? { providers.first { $0.id == activeProviderId } }

    func switchProvider(to providerId: String) {
        activeProvider?.stop()
        activeProviderId = providerId
        guard let p = activeProvider else { return }
        // Prefer the voice the user last picked for this provider; else best default
        let stored = UserDefaults.standard.string(forKey: voiceKey(for: providerId))
        if let stored, p.availableVoices.contains(where: { $0.id == stored }) {
            selectedVoiceId = stored
        } else if providerId == "edge-tts",
                  p.availableVoices.contains(where: { $0.id == Self.defaultEdgeVoice }) {
            selectedVoiceId = Self.defaultEdgeVoice
        } else {
            selectedVoiceId = bestDefaultVoiceId(for: p)
        }
    }

    private func bestDefaultVoiceId(for provider: TTSProvider) -> String? {
        Self.bestDefaultVoiceId(for: provider)
    }

    private static func bestDefaultVoiceId(for provider: TTSProvider) -> String? {
        let voices = provider.availableVoices
        return voices.first(where: { $0.quality == "Premium" })?.id
            ?? voices.first(where: { $0.quality == "Neural" })?.id
            ?? voices.first(where: { $0.quality == "Enhanced" })?.id
            ?? voices.first?.id
    }

    func speak(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let provider = activeProvider else { return }
        let voice = provider.availableVoices.first { $0.id == selectedVoiceId }
        currentText = trimmed
        breakpoints = Self.findBreakpoints(in: trimmed)
        highlightRange = nil
        provider.speak(trimmed, voice: voice, rate: rate)
        BubbleWindow.shared.show()
    }

    /// Jump the cursor to the next natural break (sentence / paragraph).
    /// The current utterance is stopped and the remainder restarted from there.
    func nextChunk() {
        guard !currentText.isEmpty, !breakpoints.isEmpty else { return }
        let here = currentOffset()
        guard let target = breakpoints.first(where: { $0 > here }) else {
            stop(); return
        }
        seekToOffset(target)
    }

    func previousChunk() {
        guard !currentText.isEmpty, !breakpoints.isEmpty else { return }
        let here = currentOffset()
        // Step back to the breakpoint *before* the current one, so repeated
        // presses move backwards instead of bouncing on the nearest boundary.
        let priors = breakpoints.filter { $0 < here - 2 }
        seekToOffset(priors.last ?? 0)
    }

    private func currentOffset() -> Int {
        highlightRange?.location ?? 0
    }

    /// Jump playback to a character offset (UTF16) in `currentText`.
    func seekToCharacter(_ offset: Int) { seekToOffset(offset) }

    private func seekToOffset(_ offset: Int) {
        let total = (currentText as NSString).length
        guard total > 0 else { return }
        let clamped = max(0, min(offset, total - 1))
        activeProvider?.seek(to: Double(clamped) / Double(total))
    }

    /// Natural break offsets: end of each sentence (after `.!?`) and paragraph
    /// boundaries (newlines). Returns UTF16 character offsets into `text`.
    private static func findBreakpoints(in text: String) -> [Int] {
        let ns = text as NSString
        var out: [Int] = []
        var i = 0
        let len = ns.length
        while i < len {
            let scalar = ns.character(at: i)
            // ASCII . ! ? \n
            if scalar == 0x2E || scalar == 0x21 || scalar == 0x3F || scalar == 0x0A {
                // Skip any trailing whitespace so the cursor lands at the next
                // sentence's first letter.
                var j = i + 1
                while j < len {
                    let c = ns.character(at: j)
                    if c == 0x20 || c == 0x0A || c == 0x09 { j += 1 } else { break }
                }
                if j < len, out.last != j { out.append(j) }
                i = j
            } else {
                i += 1
            }
        }
        return out
    }

    func togglePause() {
        guard let p = activeProvider else { return }
        if p.isPaused { p.resume() } else if p.isSpeaking { p.pause() }
        refreshState()
    }

    func stop() {
        activeProvider?.stop()
        refreshState()
        // Player stays visible — user dismisses via menu-bar Quit.
    }

    func seek(to fraction: Double) {
        activeProvider?.seek(to: fraction)
    }

    private func refreshState() {
        let speaking = activeProvider?.isSpeaking ?? false
        let paused = activeProvider?.isPaused ?? false
        isSpeaking = speaking
        isPaused = paused
        // Bubble persists across playback boundaries — no auto-hide.
    }

    private func refreshProgress() {
        progress = activeProvider?.progress ?? 0
    }

    private func refreshHighlight() {
        highlightRange = activeProvider?.highlightRange
    }
}
