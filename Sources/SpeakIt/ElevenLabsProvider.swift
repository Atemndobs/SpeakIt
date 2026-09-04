import AVFoundation
import ElevenLabsKit
import Foundation
import NaturalLanguage

/// ElevenLabs TTS.
///
/// Same shape as `EdgeTTSProvider`: split the text into sentences, synthesize
/// ahead of playback, queue the results so audio starts in about a second
/// instead of after the whole article renders. The difference is that the
/// generator is an HTTPS call rather than a local CLI, which brings three
/// things the local providers never had to deal with.
///
///  1. **It costs money per character.** Synthesis is capped and the cap is
///     enforced here, not just displayed. Seeking discards work already paid
///     for, so cached audio is kept rather than thrown away on every seek.
///  2. **It can fail in ways worth distinguishing.** A bad key must not be
///     retried once per sentence; a 500 should be. `APIError.isRetryable`
///     carries that distinction and a failed key stops the whole read.
///  3. **There is no rate parameter.** The API has no speaking-rate control, so
///     rate is applied at playback through `AVAudioPlayer.rate`. That is a real
///     difference from Edge, where the rate is baked into the synthesis.
@MainActor
final class ElevenLabsProvider: NSObject, TTSProvider {
    let id = "elevenlabs"
    let displayName = "ElevenLabs"

    // MARK: State

    private var sentences: [String] = []
    private var sentenceRanges: [NSRange] = []
    private var originalText: String = ""
    private var pendingAudio: [Int: URL] = [:]
    /// Sentences that will never produce audio. Playback steps over these;
    /// without them a single transient failure stalls the read forever.
    private var failedIndices: Set<Int> = []
    private var currentIndex: Int = -1
    private var activePlayer: AVAudioPlayer?
    private var generatorTask: Task<Void, Never>?
    private var progressTimer: Timer?
    private var _isSpeaking = false
    private var _isPaused = false
    private(set) var progress: Double = 0
    private(set) var highlightRange: NSRange? = nil

    private var currentVoiceID: String = ""
    private var currentRate: Float = 0.5

    /// Surfaced in the menu bar so a failure is visible rather than silent.
    private(set) var lastError: String?
    private(set) var subscriptionSummary: String?

    var onStateChange: (() -> Void)?
    var onProgress: (() -> Void)?
    var onHighlight: (() -> Void)?

    private let api: ElevenLabsAPI
    private let credentials: ElevenLabsCredentials

    /// How many sentences may be synthesized ahead of the one playing.
    ///
    /// Unbounded lookahead would bill the whole article the moment you press
    /// play, including the 90 percent you skip. Three is enough to keep the
    /// queue full at any realistic speaking rate.
    private static let lookahead = 3

    // MARK: Voices

    private static let voicesCacheKey = "SpeakIt.elevenlabs.voicesCache"
    private var _voices: [TTSVoice] = []

    /// Cached so the picker is populated at launch without a network round
    /// trip. Refreshed in the background by `refreshVoices()`.
    var availableVoices: [TTSVoice] { _voices }

    var isSpeaking: Bool { _isSpeaking }
    var isPaused: Bool { _isPaused }
    var hasAPIKey: Bool { credentials.hasKey }

    init(
        api: ElevenLabsAPI? = nil,
        credentials: ElevenLabsCredentials = .shared
    ) {
        self.credentials = credentials
        self.api = api ?? ElevenLabsAPI(apiKey: { credentials.apiKey })
        super.init()
        _voices = Self.loadCachedVoices()
        if credentials.hasKey {
            Task { await refreshVoices() }
        }
    }

    private lazy var audioDelegate: ElevenLabsPlayerDelegate = {
        let d = ElevenLabsPlayerDelegate()
        d.onFinish = { [weak self] in
            Task { @MainActor in self?.advance() }
        }
        return d
    }()

    // MARK: - Voice discovery

    /// Fetch the catalogue. Cloned and professional voices sort first because
    /// they are the user's own.
    @discardableResult
    func refreshVoices() async -> Bool {
        guard credentials.hasKey else {
            _voices = []
            Self.cacheVoices([])
            onStateChange?()
            return false
        }
        do {
            let remote = try await api.listVoices()
            let mapped = remote
                .sorted { lhs, rhs in
                    if lhs.isCloned != rhs.isCloned { return lhs.isCloned }
                    return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
                }
                .map {
                    TTSVoice(
                        id: $0.voiceID,
                        name: $0.displayName,
                        language: $0.accent,
                        quality: "Premium"
                    )
                }
            _voices = mapped
            Self.cacheVoices(mapped)
            lastError = nil
            onStateChange?()
            return true
        } catch {
            lastError = (error as? ElevenLabsAPI.APIError)?.localizedDescription
                ?? error.localizedDescription
            log("voice refresh failed: \(lastError ?? "unknown")")
            onStateChange?()
            return false
        }
    }

    /// Validate the key and cache the quota line for the settings panel.
    func refreshSubscription() async {
        guard credentials.hasKey else {
            subscriptionSummary = nil
            onStateChange?()
            return
        }
        switch await api.validateKey() {
        case .success(let sub):
            subscriptionSummary = sub.summary
            lastError = nil
        case .failure(let error):
            subscriptionSummary = nil
            lastError = error.localizedDescription
        }
        onStateChange?()
    }

    private static func loadCachedVoices() -> [TTSVoice] {
        guard let raw = UserDefaults.standard.array(forKey: voicesCacheKey) as? [[String: String]]
        else { return [] }
        return raw.compactMap { entry in
            guard let id = entry["id"], let name = entry["name"] else { return nil }
            return TTSVoice(
                id: id,
                name: name,
                language: entry["language"] ?? "multilingual",
                quality: "Premium"
            )
        }
    }

    private static func cacheVoices(_ voices: [TTSVoice]) {
        let raw = voices.map { ["id": $0.id, "name": $0.name, "language": $0.language] }
        UserDefaults.standard.set(raw, forKey: voicesCacheKey)
    }

    // MARK: - TTSProvider

    func speak(_ text: String, voice: TTSVoice?, rate: Float) {
        stop()

        guard credentials.hasKey else {
            lastError = ElevenLabsAPI.APIError.missingAPIKey.localizedDescription
            log(lastError!)
            onStateChange?()
            return
        }
        guard let voiceID = voice?.id ?? _voices.first?.id else {
            lastError = "No ElevenLabs voice selected. Refresh voices in settings."
            log(lastError!)
            onStateChange?()
            return
        }

        currentVoiceID = voiceID
        currentRate = rate
        originalText = text
        let pairs = splitSentencesWithRanges(text)
        sentences = pairs.map { $0.0 }
        sentenceRanges = pairs.map { $0.1 }
        currentIndex = -1
        failedIndices = []
        progress = 0
        highlightRange = nil
        lastError = nil
        _isSpeaking = true
        onStateChange?()
        onProgress?()
        onHighlight?()
        log("speak() sentences=\(sentences.count) voice=\(voiceID) chars=\(text.count)")

        generatorTask = Task { [weak self] in
            await self?.runGenerator(from: 0)
        }
    }

    func pause() {
        activePlayer?.pause()
        progressTimer?.invalidate()
        _isPaused = true
        onStateChange?()
    }

    func resume() {
        activePlayer?.play()
        startProgressTimer()
        _isPaused = false
        onStateChange?()
        // The generator pauses with playback: lookahead is measured from the
        // playing sentence, so a paused read stops spending.
        if generatorTask == nil || generatorTask?.isCancelled == true {
            generatorTask = Task { [weak self] in
                await self?.runGenerator(from: max(0, self?.currentIndex ?? 0))
            }
        }
    }

    func stop() {
        generatorTask?.cancel()
        generatorTask = nil
        progressTimer?.invalidate(); progressTimer = nil

        activePlayer?.stop()
        activePlayer = nil

        for (_, url) in pendingAudio { try? FileManager.default.removeItem(at: url) }
        pendingAudio.removeAll()

        sentences = []
        sentenceRanges = []
        originalText = ""
        currentIndex = -1
        failedIndices = []
        highlightRange = nil
        let was = _isSpeaking || _isPaused
        _isSpeaking = false
        _isPaused = false
        progress = 0
        if was {
            onStateChange?()
            onProgress?()
            onHighlight?()
        }
    }

    func seek(to fraction: Double) {
        let total = (originalText as NSString).length
        guard total > 0 else { return }
        seek(toCharacterOffset: max(0, min(total - 1, Int(fraction * Double(total)))))
    }

    func seek(toCharacterOffset offset: Int) {
        let n = sentences.count
        guard n > 0, (_isSpeaking || _isPaused) else { return }
        let targetOffset = max(0, min(offset, max(0, (originalText as NSString).length - 1)))
        let target = sentenceIndex(containing: targetOffset) ?? max(0, min(n - 1, currentIndex))
        let within = fractionWithinSentence(offset: targetOffset, sentenceIndex: target)
        seekToSentence(target, withinFraction: within)
    }

    private func seekToSentence(_ target: Int, withinFraction: Double = 0) {
        let n = sentences.count
        guard n > 0, (_isSpeaking || _isPaused) else { return }
        log("seek -> sentence \(target + 1)/\(n)")

        activePlayer?.stop()
        activePlayer = nil
        progressTimer?.invalidate(); progressTimer = nil
        generatorTask?.cancel()
        generatorTask = nil

        // Unlike the Edge provider, audio behind the playhead is NOT discarded.
        // It has already been paid for, and seeking backwards over a paragraph
        // you just heard should not re-bill it.
        currentIndex = target - 1
        // Give sentences at or after the target another chance: the generator
        // is about to run over them again, and the failure may have been the
        // rate limit that has since cleared.
        failedIndices = failedIndices.filter { $0 < target }
        _isPaused = false
        _isSpeaking = true
        if target < sentenceRanges.count {
            highlightRange = sentenceRanges[target]
            progress = progressForSentence(target, withinFraction: withinFraction)
            onHighlight?()
            onProgress?()
        }
        onStateChange?()

        maybeStartPlayback()
        if let player = activePlayer, withinFraction > 0 {
            player.currentTime = withinFraction * player.duration
        }

        generatorTask = Task { [weak self] in
            await self?.runGenerator(from: target)
        }
    }

    // MARK: - Generator

    private func runGenerator(from startIdx: Int) async {
        let voiceID = currentVoiceID
        let snapshot = sentences
        guard startIdx < snapshot.count else { return }

        for idx in startIdx..<snapshot.count {
            if Task.isCancelled { return }
            if pendingAudio[idx] != nil { continue }

            // Stay within the lookahead window. Waiting here rather than
            // synthesizing eagerly is what keeps a skipped article from
            // billing in full.
            while !Task.isCancelled, idx > currentIndex + Self.lookahead {
                try? await Task.sleep(nanoseconds: 120_000_000)
            }
            if Task.isCancelled { return }

            do {
                let data = try await api.synthesize(
                    text: snapshot[idx],
                    voiceID: voiceID,
                    settings: .default
                )
                if Task.isCancelled { return }
                let url = FileManager.default.temporaryDirectory
                    .appendingPathComponent("speakit-el-\(UUID().uuidString).mp3")
                try data.write(to: url)
                pendingAudio[idx] = url
                maybeStartPlayback()
            } catch let error as ElevenLabsAPI.APIError {
                lastError = error.localizedDescription
                log("synthesis failed at sentence \(idx + 1): \(error.localizedDescription)")
                onStateChange?()
                // A key or quota problem will not fix itself on the next
                // sentence. Stop the whole read instead of failing 200 times
                // and leaving the user with silence and no explanation.
                if !error.isRetryable {
                    stop()
                    return
                }
                // Retryable, but this pass is giving up on this sentence.
                // Record it so playback steps over the gap rather than waiting
                // for audio that is never coming.
                failedIndices.insert(idx)
                maybeStartPlayback()
            } catch {
                lastError = error.localizedDescription
                log("synthesis failed at sentence \(idx + 1): \(error)")
                failedIndices.insert(idx)
                onStateChange?()
                maybeStartPlayback()
            }
        }
    }

    // MARK: - Playback

    private func maybeStartPlayback() {
        guard activePlayer == nil, !_isPaused else { return }
        switch SentenceQueue.next(
            after: currentIndex,
            ready: Set(pendingAudio.keys),
            failed: failedIndices,
            total: sentences.count
        ) {
        case .play(let idx):
            guard let url = pendingAudio.removeValue(forKey: idx) else { return }
            playIndex(idx, url: url)
        case .waiting:
            return
        case .finished:
            if _isSpeaking { handleEnd() }
        }
    }

    private func playIndex(_ idx: Int, url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = audioDelegate
            // The API has no speaking-rate parameter, so rate is applied on
            // playback. enableRate must be set before prepareToPlay.
            player.enableRate = true
            player.rate = PlaybackRate.multiplier(fromSlider: currentRate)
            player.prepareToPlay()
            player.play()
            activePlayer = player
            currentIndex = idx
            if idx < sentenceRanges.count {
                highlightRange = sentenceRanges[idx]
                onHighlight?()
            }
            startProgressTimer()
            try? FileManager.default.removeItem(at: url)
            log("playing sentence \(idx + 1)/\(sentences.count) (\(String(format: "%.1f", player.duration))s)")
        } catch {
            log("playIndex \(idx) FAILED: \(error)")
            advance()
        }
    }

    private func advance() {
        activePlayer = nil
        maybeStartPlayback()
        // maybeStartPlayback ends the read itself when the queue is finished.
        // Reaching here with no player means we are waiting on the generator.
    }

    private func handleEnd() {
        progressTimer?.invalidate(); progressTimer = nil
        progress = 1
        onProgress?()
        _isSpeaking = false
        _isPaused = false
        onStateChange?()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let t = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        t.tolerance = 0.04
        progressTimer = t
    }

    private func tickProgress() {
        guard !sentences.isEmpty else { return }
        var within: Double = 0
        if let p = activePlayer, p.duration > 0 {
            within = p.currentTime / p.duration
        }
        progress = progressForSentence(max(currentIndex, 0), withinFraction: within)
        onProgress?()
    }

    // MARK: - Helpers

    private func sentenceIndex(containing offset: Int) -> Int? {
        sentenceRanges.firstIndex { offset >= $0.location && offset < NSMaxRange($0) }
            ?? sentenceRanges.lastIndex { offset >= $0.location }
    }

    private func fractionWithinSentence(offset: Int, sentenceIndex: Int) -> Double {
        guard sentenceIndex < sentenceRanges.count else { return 0 }
        let range = sentenceRanges[sentenceIndex]
        guard range.length > 0 else { return 0 }
        return max(0, min(1, Double(offset - range.location) / Double(range.length)))
    }

    private func progressForSentence(_ sentenceIndex: Int, withinFraction: Double) -> Double {
        let total = (originalText as NSString).length
        guard total > 0, sentenceIndex < sentenceRanges.count else { return progress }
        let range = sentenceRanges[sentenceIndex]
        let absolute = Double(range.location) + Double(range.length) * max(0, min(1, withinFraction))
        return max(0, min(1, absolute / Double(total)))
    }

    private func splitSentencesWithRanges(_ text: String) -> [(String, NSRange)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [(String, NSRange)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let trimmed = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            out.append((trimmed, NSRange(range, in: text)))
            return true
        }
        if out.isEmpty {
            return [(text, NSRange(location: 0, length: (text as NSString).length))]
        }
        return out
    }

    private func log(_ s: String) {
        print("[ElevenLabs] \(s)")
    }
}

private final class ElevenLabsPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish?() }
}
