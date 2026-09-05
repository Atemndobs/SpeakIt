import SwiftUI
import AVFoundation
import AppKit
import NaturalLanguage
import SpeechKit

@MainActor
final class TTSEngine: ObservableObject {
    static let shared = TTSEngine()

    @Published var providers: [TTSProvider] = []
    @Published var activeProviderId: String {
        didSet { UserDefaults.standard.set(activeProviderId, forKey: Keys.activeProviderId) }
    }
    @Published var selectedVoiceId: String? {
        didSet {
            // Only persist a voice the active provider actually offers.
            // `switchProvider` sets the provider before the voice, so there is
            // a window where this object holds a new provider and the previous
            // provider's voice; a write landing there used to file the wrong id
            // under the new provider's key. See VoiceSelection.canPersist.
            let available = activeProvider?.availableVoices.map(\.id) ?? []
            guard VoiceSelection.canPersist(selectedVoiceId, available: available) else { return }
            UserDefaults.standard.set(selectedVoiceId, forKey: voiceKey(for: activeProviderId))
        }
    }
    @Published var rate: Float {
        didSet { UserDefaults.standard.set(Double(rate), forKey: Keys.rate) }
    }
    @Published var isSpeaking: Bool = false
    @Published var isPaused: Bool = false
    @Published var progress: Double = 0
    @Published var currentText: String = ""
    @Published var highlightRange: NSRange?
    /// Filesystem path of what's being read (a file or its project folder), if a
    /// caller supplied one. Drives the bubble's "open in Finder" control. nil for
    /// ad-hoc reads (selection, clipboard) that have no source on disk.
    @Published var currentSource: String?
    /// Human-readable label for what's being read (project / plan / file name, or
    /// a snippet of the text when nothing better is known). Shown in the bubble so
    /// you can tell at a glance which chat, page, or file is talking.
    @Published var currentTitle: String = ""
    /// Reads waiting behind the current one. Published so the menu bar can show
    /// that an enqueued response is pending rather than lost.
    @Published private(set) var queueDepth: Int = 0

    // Natural-break navigation: text is read as one continuous utterance; skip
    // buttons jump to sentence or non-empty line starts.
    private var navigationOffsets: [Int] = []  // character offsets (UTF16) into currentText
    private var pendingRequests: [SpeakRequest] = []

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
        let eleven = ElevenLabsProvider()
        let kokoro = KokoroProvider()

        // --- Step 1: initialize ALL stored properties before referencing self ---
        let defaults = UserDefaults.standard
        let provider = defaults.string(forKey: Keys.activeProviderId) ?? Self.defaultProvider
        // NSNumber<->Float bridging can return nil unexpectedly; round-trip via Double.
        let hasStoredRate = defaults.object(forKey: Keys.rate) != nil
        let storedRate: Float? = hasStoredRate ? Float(defaults.double(forKey: Keys.rate)) : nil
        let active: TTSProvider = {
            switch provider {
            case edge.id: return edge
            case eleven.id: return eleven
            case kokoro.id: return kokoro
            default: return av
            }
        }()
        let storedVoice = defaults.string(forKey: Self.voiceKey(for: provider))

        let resolvedVoiceId = VoiceSelection.resolve(
            stored: storedVoice,
            available: active.availableVoices.map(\.id),
            preferred: provider == "edge-tts" ? Self.defaultEdgeVoice : nil,
            ranked: Self.voicesRankedByQuality(active)
        )

        self.providers = [av, edge, kokoro, eleven]
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
        eleven.onStateChange = stateHandler
        eleven.onProgress = progressHandler
        eleven.onHighlight = highlightHandler
        kokoro.onStateChange = stateHandler
        kokoro.onProgress = progressHandler
        kokoro.onHighlight = highlightHandler

        healCorruptedVoiceKeys()
    }

    var activeProvider: TTSProvider? { providers.first { $0.id == activeProviderId } }

    /// Typed handle for the settings panel, which needs the key and quota
    /// affordances that only this provider has.
    var elevenLabs: ElevenLabsProvider? {
        providers.first { $0.id == "elevenlabs" } as? ElevenLabsProvider
    }

    /// Typed handle for the settings panel, which shows install state for the
    /// local engine because a missing 325 MB model is not something the generic
    /// voice picker can explain.
    var kokoro: KokoroProvider? {
        providers.first { $0.id == "kokoro" } as? KokoroProvider
    }

    /// Re-read the ElevenLabs catalogue and make sure a voice is selected.
    /// Called after the key changes, when the picker would otherwise stay empty
    /// until the next launch.
    func reloadElevenLabsVoices() async {
        guard let provider = elevenLabs else { return }
        await provider.refreshVoices()
        await provider.refreshSubscription()
        guard activeProviderId == provider.id else { return }
        let voices = provider.availableVoices
        if let current = selectedVoiceId, voices.contains(where: { $0.id == current }) { return }
        selectedVoiceId = voices.first?.id
        objectWillChange.send()
    }

    func switchProvider(to providerId: String) {
        activeProvider?.stop()
        activeProviderId = providerId
        guard let p = activeProvider else { return }
        selectedVoiceId = VoiceSelection.resolve(
            stored: UserDefaults.standard.string(forKey: voiceKey(for: providerId)),
            available: p.availableVoices.map(\.id),
            preferred: providerId == "edge-tts" ? Self.defaultEdgeVoice : nil,
            ranked: Self.voicesRankedByQuality(p)
        )
    }

    /// Voice ids in descending quality, the generic fallback order when a
    /// provider has no stored or preferred voice.
    private static func voicesRankedByQuality(_ provider: TTSProvider) -> [String] {
        let order = ["Premium", "Neural", "Enhanced"]
        return provider.availableVoices
            .sorted { a, b in
                (order.firstIndex(of: a.quality) ?? order.count)
                    < (order.firstIndex(of: b.quality) ?? order.count)
            }
            .map(\.id)
    }

    /// Clear voice keys naming a voice their provider does not offer.
    ///
    /// Installs that ran before the persistence guard carry corrupted entries,
    /// and those survive the fix. Wiping them once means the next switch picks
    /// a sensible default instead of silently discarding a stored id.
    private func healCorruptedVoiceKeys() {
        let defaults = UserDefaults.standard
        var stored: [String: String?] = [:]
        var catalogues: [String: [String]] = [:]
        for provider in providers {
            stored[provider.id] = defaults.string(forKey: Self.voiceKey(for: provider.id))
            catalogues[provider.id] = provider.availableVoices.map(\.id)
        }
        for providerId in VoiceSelection.corruptedProviders(stored: stored, catalogues: catalogues) {
            defaults.removeObject(forKey: Self.voiceKey(for: providerId))
        }
    }

    func speak(_ text: String, source: String? = nil, title: String? = nil) {
        handleSpeakRequest(
            SpeakRequest(
                text: text,
                source: .unknown,
                action: .replace,
                // Callers of this overload have already normalized, or are
                // passing text that should be spoken verbatim.
                sanitizeMarkdown: false,
                sourcePath: source,
                title: title
            )
        )
    }

    /// The single entry point for every caller: URL scheme, Services menu,
    /// clipboard watcher, selection hotkey and the local HTTP API.
    func handleSpeakRequest(_ request: SpeakRequest) {
        let trimmed = request.text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        var normalized = request
        normalized.text = trimmed

        switch request.action {
        case .replace, .interrupt:
            pendingRequests.removeAll()
            queueDepth = 0
            activeProvider?.stop()
            startSpeaking(normalized)
        case .enqueue:
            if isSpeaking || isPaused {
                // Queued entries play on their own when their turn comes, so
                // they are stored as .replace against an idle engine.
                normalized.action = .replace
                normalized.sanitizeMarkdown = false
                pendingRequests.append(normalized)
                queueDepth = pendingRequests.count
            } else {
                startSpeaking(normalized)
            }
        }
    }

    private func startSpeaking(_ request: SpeakRequest) {
        guard let provider = activeProvider else { return }
        let text = request.text
        let voice = provider.availableVoices.first { $0.id == selectedVoiceId }
        currentText = text
        let src = request.sourcePath.flatMap { $0.isEmpty ? nil : $0 }
        currentSource = src
        currentTitle = Self.resolveTitle(title: request.title, source: src, text: text)
        navigationOffsets = Self.findNavigationOffsets(in: text)
        highlightRange = nil
        provider.speak(text, voice: voice, rate: rate)
        BubbleWindow.shared.show()
    }

    /// Open `currentSource` in the SpeakIt web reader (browser) — a folder shows
    /// its listing, a file opens rendered. Shares it and starts the server if
    /// needed.
    func openSource() {
        guard let path = currentSource else { return }
        LocalFileServer.shared.openInReader(path: path)
    }

    /// Choose the player's display label. An explicit `title` (project / page name
    /// from the caller) wins; otherwise fall back to the source path's last
    /// component (file or folder name); otherwise a trimmed snippet of the spoken
    /// text so ad-hoc selections still show something recognizable.
    private static func resolveTitle(title: String?, source: String?, text: String) -> String {
        if let t = title?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty {
            return t
        }
        if let source, !source.isEmpty {
            let name = (source as NSString).lastPathComponent
            if !name.isEmpty { return name }
        }
        let firstLine = text.split(whereSeparator: \.isNewline).first.map(String.init) ?? text
        let snippet = firstLine.trimmingCharacters(in: .whitespaces)
        guard !snippet.isEmpty else { return "Speaking" }
        let limit = 48
        if snippet.count > limit {
            let cut = snippet.index(snippet.startIndex, offsetBy: limit)
            return String(snippet[..<cut]).trimmingCharacters(in: .whitespaces) + "…"
        }
        return snippet
    }

    /// Jump the cursor to the next natural break (sentence / paragraph).
    /// The current utterance is stopped and the remainder restarted from there.
    func nextChunk() {
        guard !currentText.isEmpty, !navigationOffsets.isEmpty else { return }
        let here = currentOffset()
        guard let target = navigationOffsets.first(where: { $0 > here + 1 }) else {
            stop(); return
        }
        seekToOffset(target)
    }

    func previousChunk() {
        guard !currentText.isEmpty, !navigationOffsets.isEmpty else { return }
        let here = currentOffset()
        let idx = currentNavigationIndex(for: here)
        let currentStart = navigationOffsets[idx]
        let target: Int
        if here - currentStart > 2 {
            target = currentStart
        } else {
            target = navigationOffsets[max(0, idx - 1)]
        }
        seekToOffset(target)
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
        activeProvider?.seek(toCharacterOffset: clamped)
    }

    private func currentNavigationIndex(for offset: Int) -> Int {
        var idx = 0
        for (i, candidate) in navigationOffsets.enumerated() {
            if candidate <= offset {
                idx = i
            } else {
                break
            }
        }
        return idx
    }

    /// Natural navigation offsets: sentence starts from NaturalLanguage plus
    /// non-empty line starts. Returns UTF16 character offsets into `text`.
    private static func findNavigationOffsets(in text: String) -> [Int] {
        guard !text.isEmpty else { return [] }
        var offsets: Set<Int> = [0]

        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            offsets.insert(NSRange(range, in: text).location)
            return true
        }

        let ns = text as NSString
        var lineStart = 0
        for i in 0..<ns.length {
            guard ns.character(at: i) == 0x0A else { continue }
            lineStart = i + 1
            while lineStart < ns.length {
                let c = ns.character(at: lineStart)
                if c == 0x20 || c == 0x09 { lineStart += 1 } else { break }
            }
            if lineStart < ns.length, ns.character(at: lineStart) != 0x0A {
                offsets.insert(lineStart)
            }
        }

        return offsets.sorted()
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
        if !speaking && !paused, !pendingRequests.isEmpty {
            let next = pendingRequests.removeFirst()
            queueDepth = pendingRequests.count
            startSpeaking(next)
        }
        // Bubble persists across playback boundaries — no auto-hide.
    }

    private func refreshProgress() {
        progress = activeProvider?.progress ?? 0
    }

    private func refreshHighlight() {
        highlightRange = activeProvider?.highlightRange
    }
}
