import AVFoundation
import AppKit
import Foundation
import NaturalLanguage
import SpeechKit

/// Kokoro-82M running locally, through a resident Python daemon.
///
/// Why this exists
/// ---------------
/// The two good-sounding engines both need the network: Edge Neural calls
/// Microsoft, ElevenLabs calls a metered API. The offline fallback is Apple's
/// `AVSpeechSynthesizer`, which sounds like 2011. Kokoro is 82M parameters,
/// runs on the CPU faster than realtime, and needs no network and no key.
///
/// Measured on an M3 Max, fp32 weights: RTF 0.155 in steady state, roughly
/// five times faster than playback, with a 0.6 s one-off model load. The
/// larger VoxCPM was measured at RTF 1.76 on comparable Apple silicon, which
/// is slower than realtime and therefore unusable for a reader that is
/// supposed to start talking the moment an agent stops.
///
/// Why a daemon rather than a process per sentence
/// ----------------------------------------------
/// `EdgeTTSProvider` spawns `edge-tts` once per sentence, which is cheap
/// because that process only makes an HTTP request. Here a process start means
/// importing onnxruntime and loading 325 MB of weights. Paying that per
/// sentence would put the first word further away than the network engine this
/// replaces, so one daemon is started on first use and kept alive.
@MainActor
final class KokoroProvider: NSObject, TTSProvider {
    let id = "kokoro"
    let displayName = "Kokoro (Local)"

    // MARK: Install

    private let install: KokoroInstall

    /// Prefer the daemon bundled in SpeakIt.app so an app update ships a new
    /// script without the user re-running setup. Falls back to the copy setup
    /// left in the home directory, which is what a `swift run` build sees.
    private static func resolveInstall() -> KokoroInstall {
        let base = KokoroInstall.standard()
        if let bundled = Bundle.main.url(forResource: "kokoro_daemon", withExtension: "py") {
            return base.withDaemon(bundled)
        }
        return base
    }

    var installStatus: KokoroInstall.Status { install.status() }
    var isInstalled: Bool { install.isReady() }

    // MARK: Sentence state

    private var sentences: [String] = []
    private var sentenceRanges: [NSRange] = []
    private var originalText: String = ""

    /// Rendered wav per sentence index, and the two sets that decide what plays
    /// next. `failed` is why a single bad sentence does not stall the read: see
    /// `SentenceQueue`, which is shared with the ElevenLabs provider precisely
    /// so this class cannot reinvent the stall.
    private var ready: [Int: URL] = [:]
    private var failedIndices: Set<Int> = []

    /// Derived rather than stored alongside `ready`. Two containers describing
    /// the same fact drift apart the first time one is updated on a path the
    /// other is not, and the symptom is a read that stops one sentence early.
    private var readyIndices: Set<Int> { Set(ready.keys) }

    private var currentIndex = -1
    private var activePlayer: AVAudioPlayer?
    private var progressTimer: Timer?
    private var _isSpeaking = false
    private var _isPaused = false
    private(set) var progress: Double = 0
    private(set) var highlightRange: NSRange?

    private var currentVoice = KokoroVoices.defaultVoiceId
    private var currentSpeed: Double = 1.0

    /// Ids are unique for the life of the daemon, never reset per read, so a
    /// reply that arrives after a stop can be told apart from one for the read
    /// that replaced it.
    private var nextRequestId = 0
    /// Request id -> sentence index, for the current read only.
    private var indexForRequest: [Int: Int] = [:]
    /// Replies below this id belong to an abandoned read and are discarded.
    private var acceptFromRequestId = 0

    /// How far ahead of playback synthesis is allowed to run.
    ///
    /// ElevenLabs caps this at three to bound spend. Nothing is billed here,
    /// but the cap is kept for a different reason: synthesis is real CPU on the
    /// user's machine, and rendering forty sentences of an article they will
    /// abandon after two heats the laptop for nothing. Larger than the paid
    /// cap because being wrong is cheaper.
    private let lookahead = 6

    var onStateChange: (() -> Void)?
    var onProgress: (() -> Void)?
    var onHighlight: (() -> Void)?

    let availableVoices: [TTSVoice]

    override init() {
        self.install = Self.resolveInstall()
        self.availableVoices = KokoroVoices.catalogue().map {
            TTSVoice(id: $0.id, name: $0.name, language: $0.language, quality: "Local")
        }
        super.init()
    }

    var isSpeaking: Bool { _isSpeaking }
    var isPaused: Bool { _isPaused }

    private lazy var audioDelegate: KokoroPlayerDelegate = {
        let d = KokoroPlayerDelegate()
        d.onFinish = { [weak self] in Task { @MainActor in self?.advance() } }
        return d
    }()

    // MARK: Daemon

    private var daemon: Process?
    private var daemonInput: FileHandle?
    private var daemonReadyVoices: [String] = []

    /// Start the daemon if it is not already running. Returns false when the
    /// engine is not installed, so `speak` can bail with a useful log line
    /// rather than a silent no-op.
    @discardableResult
    private func ensureDaemon() -> Bool {
        if let daemon, daemon.isRunning { return true }
        self.daemon = nil
        self.daemonInput = nil

        guard install.isReady() else {
            log(install.status().explanation ?? "not installed")
            return false
        }

        let process = Process()
        process.executableURL = install.python
        process.arguments = [install.daemonScript.path]
        var env = ProcessInfo.processInfo.environment
        env["SPEAKIT_KOKORO_MODEL"] = install.model.path
        env["SPEAKIT_KOKORO_VOICES"] = install.voices.path
        // onnxruntime sizes its thread pool from the machine, which on a
        // performance-core Mac means saturating every core for a background
        // read. Leave headroom so the UI stays responsive.
        env["OMP_NUM_THREADS"] = String(max(2, min(4, ProcessInfo.processInfo.activeProcessorCount / 2)))
        process.environment = env

        let stdin = Pipe()
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardInput = stdin
        process.standardOutput = stdout
        process.standardError = stderr

        // Drain stderr. Without a reader the 64 KB pipe buffer fills and the
        // daemon blocks on its next warning, which looks exactly like a hang
        // partway through a long read.
        stderr.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            Task { @MainActor in self.log("daemon stderr: \(trimmed.prefix(400))") }
        }

        // Reassembly state lives in a locked reference type rather than a
        // captured `var`: the handler runs off the main actor, and a captured
        // local would be shared mutable state across invocations.
        let buffer = LineBuffer()
        stdout.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            guard !chunk.isEmpty else { return }
            // Replies are newline framed and a read can split mid-line, so
            // only complete lines are consumed and the remainder is kept.
            for line in buffer.append(chunk) {
                guard let message = KokoroProtocol.parse(line: line) else { continue }
                Task { @MainActor in self.handle(message) }
            }
        }

        process.terminationHandler = { _ in
            Task { @MainActor in
                self.log("daemon exited")
                self.daemon = nil
                self.daemonInput = nil
            }
        }

        do {
            try process.run()
        } catch {
            log("failed to start daemon: \(error)")
            return false
        }

        daemon = process
        daemonInput = stdin.fileHandleForWriting
        log("daemon started (pid \(process.processIdentifier))")
        return true
    }

    private func send<T: Encodable>(_ value: T) {
        guard let input = daemonInput, let line = KokoroProtocol.line(value) else { return }
        // A daemon that died between the liveness check and this write turns a
        // broken pipe into SIGPIPE, which would take the app down with it.
        do {
            try input.write(contentsOf: Data(line.utf8))
        } catch {
            log("write failed, daemon gone: \(error)")
            daemon = nil
            daemonInput = nil
        }
    }

    private func handle(_ message: KokoroProtocol.Message) {
        switch message {
        case .ready(let voices):
            daemonReadyVoices = voices
            log("daemon ready, \(voices.count) voices")

        case .fatal(let error):
            log("daemon fatal: \(error)")
            daemon = nil
            daemonInput = nil
            failRemaining()

        case .finished(let requestId, let path, let seconds):
            guard requestId >= acceptFromRequestId,
                  let index = indexForRequest.removeValue(forKey: requestId) else {
                // Belongs to an abandoned read. Clean up so stale wavs do not
                // accumulate in the temporary directory.
                try? FileManager.default.removeItem(atPath: path)
                return
            }
            _ = seconds
            ready[index] = URL(fileURLWithPath: path)
            maybeStartPlayback()
            pump()

        case .failed(let requestId, let error, let cancelled):
            guard requestId >= acceptFromRequestId,
                  let index = indexForRequest.removeValue(forKey: requestId) else { return }
            if !cancelled {
                log("sentence \(index + 1) failed: \(error ?? "unknown")")
            }
            // Marked failed either way: a cancelled request will not be
            // answered again, so leaving it pending would stall the queue.
            failedIndices.insert(index)
            maybeStartPlayback()
            pump()
            checkForEnd()
        }
    }

    // MARK: TTSProvider

    func speak(_ text: String, voice: TTSVoice?, rate: Float) {
        stop()
        guard ensureDaemon() else { return }

        currentVoice = voice?.id ?? KokoroVoices.defaultVoiceId
        currentSpeed = KokoroSpeed.multiplier(for: rate)
        originalText = text

        let pairs = splitSentencesWithRanges(text)
        sentences = pairs.map(\.0)
        sentenceRanges = pairs.map(\.1)
        currentIndex = -1
        progress = 0
        highlightRange = nil
        _isSpeaking = true

        onStateChange?()
        onProgress?()
        onHighlight?()
        log("speak() sentences=\(sentences.count) voice=\(currentVoice) speed=\(currentSpeed)")
        pump()
    }

    /// Queue synthesis up to `lookahead` sentences past what is playing.
    ///
    /// Called after every completion and every seek rather than run as a loop,
    /// so the window slides forward with playback instead of being decided once
    /// at the start.
    private func pump() {
        guard _isSpeaking, !sentences.isEmpty else { return }
        let horizon = min(sentences.count, currentIndex + 1 + lookahead)
        var index = max(0, currentIndex + 1)
        while index < horizon {
            defer { index += 1 }
            guard ready[index] == nil,
                  !failedIndices.contains(index),
                  !indexForRequest.values.contains(index) else { continue }

            let requestId = nextRequestId
            nextRequestId += 1
            indexForRequest[requestId] = index

            let out = FileManager.default.temporaryDirectory
                .appendingPathComponent("speakit-kokoro-\(UUID().uuidString).wav")
            send(KokoroProtocol.Request(
                id: requestId,
                text: sentences[index],
                voice: currentVoice,
                speed: currentSpeed,
                lang: KokoroVoices.espeakLanguage(for: currentVoice),
                out: out.path
            ))
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
        pump()
    }

    func stop() {
        progressTimer?.invalidate()
        progressTimer = nil
        activePlayer?.stop()
        activePlayer = nil

        // Abandon every reply still owed to us, and tell the daemon to drop
        // what it has not started. The daemon is left running: it holds the
        // loaded model, which is the whole point of it being a daemon.
        acceptFromRequestId = nextRequestId
        indexForRequest.removeAll()
        if daemon?.isRunning == true {
            send(KokoroProtocol.Cancel(cancelBefore: nextRequestId))
        }

        for (_, url) in ready { try? FileManager.default.removeItem(at: url) }
        ready.removeAll()
        failedIndices.removeAll()

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

    func seek(to fraction: Double) {
        let total = (originalText as NSString).length
        guard total > 0 else { return }
        seek(toCharacterOffset: max(0, min(total - 1, Int(fraction * Double(total)))))
    }

    func seek(toCharacterOffset offset: Int) {
        guard !sentences.isEmpty, _isSpeaking || _isPaused else { return }
        let clamped = max(0, min(offset, max(0, (originalText as NSString).length - 1)))
        let target = sentenceIndex(containing: clamped) ?? max(0, min(sentences.count - 1, currentIndex))
        let within = fractionWithinSentence(offset: clamped, sentenceIndex: target)

        activePlayer?.stop()
        activePlayer = nil
        progressTimer?.invalidate()
        progressTimer = nil

        // Drop rendered audio behind the target. Unlike the paid provider
        // there is no reason to keep it: re-rendering costs CPU we already
        // have, and holding wavs for a whole article wastes disk.
        for (index, url) in ready where index < target {
            try? FileManager.default.removeItem(at: url)
            ready.removeValue(forKey: index)
        }
        failedIndices = failedIndices.filter { $0 >= target }

        // Abandon in-flight requests for sentences we have jumped past.
        for (requestId, index) in indexForRequest where index < target {
            indexForRequest.removeValue(forKey: requestId)
        }
        // Everything still wanted has a request id at or above this floor,
        // because abandoned ids were just removed from the map. An empty map
        // means nothing is wanted, so cancel the whole queue.
        let floor = indexForRequest.keys.min() ?? nextRequestId
        send(KokoroProtocol.Cancel(cancelBefore: floor))

        currentIndex = target - 1
        _isPaused = false
        _isSpeaking = true
        if target < sentenceRanges.count {
            highlightRange = sentenceRanges[target]
            progress = progressForSentence(target, withinFraction: within)
            onHighlight?()
            onProgress?()
        }
        onStateChange?()

        maybeStartPlayback()
        if let player = activePlayer, within > 0 {
            player.currentTime = within * player.duration
        }
        pump()
    }

    // MARK: Playback

    private func maybeStartPlayback() {
        guard activePlayer == nil, !_isPaused, _isSpeaking else { return }
        switch SentenceQueue.next(
            after: currentIndex,
            ready: readyIndices,
            failed: failedIndices,
            total: sentences.count
        ) {
        case .play(let index):
            guard let url = ready.removeValue(forKey: index) else { return }
            play(index: index, url: url)
        case .waiting:
            return
        case .finished:
            handleEnd()
        }
    }

    private func play(index: Int, url: URL) {
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = audioDelegate
            player.prepareToPlay()
            player.play()
            activePlayer = player
            currentIndex = index
            if index < sentenceRanges.count {
                highlightRange = sentenceRanges[index]
                onHighlight?()
            }
            startProgressTimer()
            try? FileManager.default.removeItem(at: url)
        } catch {
            // A file the player rejects must be marked failed, not merely
            // skipped: leaving it unresolved lets the queue return to it and
            // loop. Same defect the paid provider hit with `markPlaybackFailed`.
            log("playback rejected sentence \(index + 1): \(error)")
            try? FileManager.default.removeItem(at: url)
            failedIndices.insert(index)
            currentIndex = index
            advance()
        }
    }

    private func advance() {
        activePlayer = nil
        maybeStartPlayback()
        if activePlayer == nil { checkForEnd() }
        pump()
    }

    private func checkForEnd() {
        guard _isSpeaking, activePlayer == nil, !_isPaused else { return }
        // Only finish when nothing is outstanding. A pending request means
        // audio is still coming, and ending here would truncate the read.
        guard indexForRequest.isEmpty else { return }
        if SentenceQueue.isExhausted(
            after: currentIndex,
            ready: readyIndices,
            failed: failedIndices,
            total: sentences.count
        ) {
            handleEnd()
        }
    }

    /// The daemon died mid-read. Nothing further will arrive, so unblock the
    /// queue instead of leaving the player waiting forever.
    private func failRemaining() {
        for (_, index) in indexForRequest { failedIndices.insert(index) }
        indexForRequest.removeAll()
        maybeStartPlayback()
        checkForEnd()
    }

    private func handleEnd() {
        progressTimer?.invalidate()
        progressTimer = nil
        guard _isSpeaking || _isPaused else { return }
        progress = 1
        onProgress?()
        _isSpeaking = false
        _isPaused = false
        onStateChange?()
    }

    private func startProgressTimer() {
        progressTimer?.invalidate()
        let timer = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tickProgress() }
        }
        timer.tolerance = 0.04
        progressTimer = timer
    }

    private func tickProgress() {
        guard !sentences.isEmpty else { return }
        var within: Double = 0
        if let player = activePlayer, player.duration > 0 {
            within = player.currentTime / player.duration
        }
        progress = progressForSentence(max(currentIndex, 0), withinFraction: within)
        onProgress?()
    }

    // MARK: Text helpers

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

    private func progressForSentence(_ index: Int, withinFraction: Double) -> Double {
        let total = (originalText as NSString).length
        guard total > 0, index < sentenceRanges.count else { return progress }
        let range = sentenceRanges[index]
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

    private func log(_ message: String) {
        print("[Kokoro] \(message)")
    }
}

/// Reassembles newline-delimited output from a pipe.
///
/// A single read can return half a line, two lines, or a line split through a
/// multi-byte character, so the leftover has to survive between callbacks.
private final class LineBuffer: @unchecked Sendable {
    private var data = Data()
    private let lock = NSLock()

    /// Append a chunk and return whatever complete lines that produced.
    func append(_ chunk: Data) -> [String] {
        lock.lock()
        defer { lock.unlock() }
        data.append(chunk)

        var lines: [String] = []
        while let newline = data.firstIndex(of: 0x0A) {
            let lineData = data[data.startIndex..<newline]
            data.removeSubrange(data.startIndex...newline)
            if let line = String(data: lineData, encoding: .utf8) {
                lines.append(line)
            }
        }
        return lines
    }
}

private final class KokoroPlayerDelegate: NSObject, AVAudioPlayerDelegate {
    var onFinish: (() -> Void)?
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { onFinish?() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { onFinish?() }
}
