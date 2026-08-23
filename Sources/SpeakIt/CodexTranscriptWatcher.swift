import Foundation

/// Watches Codex rollout JSONL files and speaks completed assistant answers.
///
/// Codex records UI-visible messages under ~/.codex/sessions as rollout-*.jsonl.
/// We read only newly appended final-answer events, avoiding reasoning, folded
/// tool output, and interim commentary updates.
@MainActor
final class CodexTranscriptWatcher {
    static let shared = CodexTranscriptWatcher()

    enum Keys {
        static let enabled = "codexTranscriptWatcher.enabled"
    }

    private let sessionsRoot = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".codex/sessions", isDirectory: true)

    private var timer: Timer?
    private var offsets: [String: UInt64] = [:]
    private var pendingFragments: [String: String] = [:]
    private var recentlySpoken: Set<String> = []
    private var recentlySpokenOrder: [String] = []

    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Keys.enabled) }
        set {
            UserDefaults.standard.set(newValue, forKey: Keys.enabled)
            newValue ? start() : stop()
        }
    }

    func bootstrap() {
        if isEnabled { start() }
    }

    func start() {
        guard timer == nil else { return }
        primeOffsets()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        offsets.removeAll()
        pendingFragments.removeAll()
    }

    private func primeOffsets() {
        offsets.removeAll()
        pendingFragments.removeAll()
        for url in rolloutFiles() {
            offsets[url.path] = fileSize(url)
        }
    }

    private func tick() {
        guard isEnabled else {
            stop()
            return
        }

        for url in rolloutFiles() {
            readNewLines(from: url)
        }
    }

    private func rolloutFiles() -> [URL] {
        guard let enumerator = FileManager.default.enumerator(
            at: sessionsRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var files: [URL] = []
        for case let url as URL in enumerator {
            guard url.lastPathComponent.hasPrefix("rollout-"),
                  url.pathExtension == "jsonl",
                  (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true
            else {
                continue
            }
            files.append(url)
        }
        return files
    }

    private func fileSize(_ url: URL) -> UInt64 {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map(UInt64.init) ?? 0
    }

    private func readNewLines(from url: URL) {
        let path = url.path
        let size = fileSize(url)
        let previous = offsets[path] ?? size
        guard size > previous else {
            offsets[path] = size
            return
        }

        guard let handle = try? FileHandle(forReadingFrom: url) else {
            offsets[path] = size
            return
        }
        defer { try? handle.close() }

        do {
            try handle.seek(toOffset: previous)
            let data = try handle.readToEnd() ?? Data()
            offsets[path] = previous + UInt64(data.count)
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }

            let combined = (pendingFragments[path] ?? "") + chunk
            var parts = combined.components(separatedBy: "\n")
            if combined.hasSuffix("\n") {
                pendingFragments[path] = ""
            } else {
                pendingFragments[path] = parts.popLast() ?? ""
            }

            for line in parts where !line.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                handleRolloutLine(line, sourcePath: path)
            }
        } catch {
            offsets[path] = size
        }
    }

    private func handleRolloutLine(_ line: String, sourcePath: String) {
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              root["type"] as? String == "event_msg",
              let payload = root["payload"] as? [String: Any],
              payload["type"] as? String == "agent_message",
              payload["phase"] as? String == "final_answer",
              let message = payload["message"] as? String
        else {
            return
        }

        let cleaned = ClipboardWatcher.stripMarkdown(message)
        guard !cleaned.isEmpty else { return }
        let signature = String(cleaned.prefix(1_000))
        guard !recentlySpoken.contains(signature) else { return }
        remember(signature)

        TTSEngine.shared.speak(cleaned, source: sourcePath, title: "Codex")
    }

    private func remember(_ signature: String) {
        recentlySpoken.insert(signature)
        recentlySpokenOrder.append(signature)
        while recentlySpokenOrder.count > 25 {
            let old = recentlySpokenOrder.removeFirst()
            recentlySpoken.remove(old)
        }
    }
}
