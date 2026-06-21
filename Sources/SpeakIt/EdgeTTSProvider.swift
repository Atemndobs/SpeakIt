import AVFoundation
import Foundation
import NaturalLanguage

/// Edge Neural TTS via the `edge-tts` CLI. Streams by sentence: splits input,
/// generates each sentence in parallel-with-playback, and queues them so audio
/// starts in ~1s instead of waiting for the entire mp3 to render.
@MainActor
final class EdgeTTSProvider: NSObject, TTSProvider {
    let id = "edge-tts"
    let displayName = "Microsoft Edge (Neural)"

    // MARK: State
    private var sentences: [String] = []
    private var sentenceRanges: [NSRange] = []   // ranges within originalText
    private var originalText: String = ""
    private var pendingURLs: [Int: URL] = [:]  // generated mp3s waiting to play
    private var currentIndex: Int = -1
    private var activePlayer: AVAudioPlayer?
    private var generatorTask: Task<Void, Never>?
    private var activeProcesses: [Process] = []
    private var progressTimer: Timer?
    private var _isSpeaking = false
    private var _isPaused = false
    private(set) var progress: Double = 0
    private(set) var highlightRange: NSRange? = nil

    private var currentVoice: String = "en-US-AvaMultilingualNeural"
    private var currentRate: String = "+0%"

    var onStateChange: (() -> Void)?
    var onProgress: (() -> Void)?
    var onHighlight: (() -> Void)?

    private lazy var audioDelegate: PlayerDelegate = {
        let d = PlayerDelegate()
        d.onFinish = { [weak self] in
            Task { @MainActor in self?.advance() }
        }
        return d
    }()

    let availableVoices: [TTSVoice] = [
        TTSVoice(id: "en-US-AvaMultilingualNeural",    name: "Ava (Multilingual)",    language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-AndrewMultilingualNeural", name: "Andrew (Multilingual)", language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-EmmaMultilingualNeural",   name: "Emma (Multilingual)",   language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-BrianMultilingualNeural",  name: "Brian (Multilingual)",  language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-AriaNeural",               name: "Aria",                  language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-JennyNeural",              name: "Jenny",                 language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-GuyNeural",                name: "Guy",                   language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-US-DavisNeural",              name: "Davis",                 language: "en-US", quality: "Neural"),
        TTSVoice(id: "en-GB-SoniaNeural",              name: "Sonia (UK)",            language: "en-GB", quality: "Neural"),
        TTSVoice(id: "en-GB-RyanNeural",               name: "Ryan (UK)",             language: "en-GB", quality: "Neural"),
        TTSVoice(id: "de-DE-SeraphinaMultilingualNeural", name: "Seraphina (DE, Multilingual)", language: "de-DE", quality: "Neural"),
        TTSVoice(id: "de-DE-FlorianMultilingualNeural",   name: "Florian (DE, Multilingual)",   language: "de-DE", quality: "Neural"),
        TTSVoice(id: "de-DE-KatjaNeural",              name: "Katja (DE)",            language: "de-DE", quality: "Neural"),
        TTSVoice(id: "de-DE-ConradNeural",             name: "Conrad (DE)",           language: "de-DE", quality: "Neural"),
        TTSVoice(id: "de-DE-AmalaNeural",              name: "Amala (DE)",            language: "de-DE", quality: "Neural"),
        TTSVoice(id: "de-DE-KillianNeural",            name: "Killian (DE)",          language: "de-DE", quality: "Neural"),
    ]

    var isSpeaking: Bool { _isSpeaking }
    var isPaused: Bool { _isPaused }

    private static let candidatePaths = [
        "/opt/homebrew/bin/edge-tts",
        "/usr/local/bin/edge-tts",
        "\(NSHomeDirectory())/.local/bin/edge-tts",
    ]

    static var binaryPath: String? {
        for p in candidatePaths where FileManager.default.isExecutableFile(atPath: p) { return p }
        return nil
    }

    // MARK: API

    func speak(_ text: String, voice: TTSVoice?, rate: Float) {
        stop()
        guard Self.binaryPath != nil else {
            log("edge-tts not found. Install: brew install pipx && pipx install edge-tts")
            return
        }
        currentVoice = voice?.id ?? "en-US-AvaMultilingualNeural"
        currentRate = rateArg(rate)
        originalText = text
        let pairs = splitSentencesWithRanges(text)
        sentences = pairs.map { $0.0 }
        sentenceRanges = pairs.map { $0.1 }
        currentIndex = -1
        progress = 0
        highlightRange = nil
        _isSpeaking = true
        onStateChange?()
        onProgress?()
        onHighlight?()
        log("speak() sentences=\(sentences.count) voice=\(currentVoice) rate=\(currentRate)")

        generatorTask = Task { [weak self] in
            await self?.runGenerator(from: 0)
        }
    }

    func seek(to fraction: Double) {
        let n = sentences.count
        guard n > 0, (_isSpeaking || _isPaused) else { return }
        let target = max(0, min(n - 1, Int(floor(fraction * Double(n)))))
        let withinFraction = max(0, min(1, fraction * Double(n) - Double(target)))
        log("seek -> sentence \(target + 1)/\(n) within=\(String(format: "%.2f", withinFraction))")

        // Tear down current playback + generator
        activePlayer?.stop()
        activePlayer = nil
        progressTimer?.invalidate(); progressTimer = nil
        generatorTask?.cancel()
        generatorTask = nil
        for proc in activeProcesses where proc.isRunning { proc.terminate() }
        activeProcesses.removeAll()

        // Drop generated mp3s before the target (they're behind us now)
        let stale = pendingURLs.filter { $0.key < target }
        for (_, url) in stale { try? FileManager.default.removeItem(at: url) }
        pendingURLs = pendingURLs.filter { $0.key >= target }

        currentIndex = target - 1
        _isPaused = false
        _isSpeaking = true
        onStateChange?()

        // Start the target sentence immediately if it's already cached
        maybeStartPlayback()
        if let player = activePlayer, withinFraction > 0 {
            player.currentTime = withinFraction * player.duration
        }

        // Restart generator from target onward (skipping anything already cached)
        generatorTask = Task { [weak self] in
            await self?.runGenerator(from: target)
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
    }

    func stop() {
        generatorTask?.cancel()
        generatorTask = nil
        progressTimer?.invalidate(); progressTimer = nil

        activePlayer?.stop()
        activePlayer = nil

        for proc in activeProcesses where proc.isRunning { proc.terminate() }
        activeProcesses.removeAll()

        for (_, url) in pendingURLs { try? FileManager.default.removeItem(at: url) }
        pendingURLs.removeAll()

        sentences = []
        sentenceRanges = []
        originalText = ""
        currentIndex = -1
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

    // MARK: Generator pipeline

    private func runGenerator(from startIdx: Int) async {
        let voice = currentVoice
        let rate = currentRate
        let snapshot = sentences
        guard startIdx < snapshot.count else { return }
        for idx in startIdx..<snapshot.count {
            if Task.isCancelled { return }
            if pendingURLs[idx] != nil { continue }  // already cached from prior pass
            let url = await generateOne(sentence: snapshot[idx], voice: voice, rate: rate)
            if Task.isCancelled {
                if let url { try? FileManager.default.removeItem(at: url) }
                return
            }
            guard let url else { continue }
            pendingURLs[idx] = url
            maybeStartPlayback()
        }
    }

    private func generateOne(sentence: String, voice: String, rate: String) async -> URL? {
        guard let bin = Self.binaryPath else { return nil }
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakit-\(UUID().uuidString).mp3")

        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            let p = Process()
            p.executableURL = URL(fileURLWithPath: bin)
            p.arguments = [
                "-v", voice,
                "-t", sentence,
                "--rate=\(rate)",
                "--write-media", tmp.path,
            ]
            p.standardOutput = Pipe()
            p.standardError = Pipe()
            p.terminationHandler = { proc in
                Task { @MainActor in
                    self.activeProcesses.removeAll { $0 === proc }
                }
                cont.resume(returning: proc.terminationStatus == 0 ? tmp : nil)
            }
            do {
                try p.run()
                activeProcesses.append(p)
            } catch {
                cont.resume(returning: nil)
            }
        }
    }

    // MARK: Playback

    private func maybeStartPlayback() {
        guard activePlayer == nil, !_isPaused else { return }
        let nextIdx = currentIndex + 1
        guard let url = pendingURLs.removeValue(forKey: nextIdx) else { return }
        playIndex(nextIdx, url: url)
    }

    private func playIndex(_ idx: Int, url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = audioDelegate
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
        // Are we done with everything?
        if currentIndex + 1 >= sentences.count {
            // Generator may still be working; check if anything pending
            if pendingURLs.isEmpty && (generatorTask?.isCancelled ?? true || true) {
                // Generator either cancelled or sentences exhausted
                handleEnd()
                return
            }
        }
        maybeStartPlayback()
        // If nothing started, we're waiting for generator
        if activePlayer == nil && currentIndex + 1 >= sentences.count {
            handleEnd()
        }
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
        let n = sentences.count
        guard n > 0 else { return }
        var within: Double = 0
        if let p = activePlayer, p.duration > 0 {
            within = p.currentTime / p.duration
        }
        progress = min(1, (Double(max(currentIndex, 0)) + within) / Double(n))
        onProgress?()
    }

    // MARK: Helpers

    private func splitSentencesWithRanges(_ text: String) -> [(String, NSRange)] {
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [(String, NSRange)] = []
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let raw = String(text[range])
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return true }
            let ns = NSRange(range, in: text)
            out.append((trimmed, ns))
            return true
        }
        if out.isEmpty {
            return [(text, NSRange(location: 0, length: (text as NSString).length))]
        }
        return out
    }

    private func rateArg(_ rate: Float) -> String {
        let pct = max(-50, min(100, Int(((rate - 0.5) * 200).rounded())))
        return pct >= 0 ? "+\(pct)%" : "\(pct)%"
    }

    private func log(_ s: String) {
        print("[EdgeTTS] \(s)")
    }
}

private final class PlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish?() }
}
