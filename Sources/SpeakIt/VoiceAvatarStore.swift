import AppKit

/// Per-voice avatar images with a provider-logo fallback.
///
/// Images live in `~/Library/Application Support/SpeakIt/avatars/` so they can
/// be dropped in (or set from the menu) without rebuilding. Lookup order for a
/// given provider + voice:
///   1. `<providerId>__<voiceId>.<ext>`   (a specific voice's face)
///   2. `<voiceId>.<ext>`                 (shared across providers)
/// Filenames are sanitized: any character outside `[A-Za-z0-9._-]` becomes `_`.
/// When nothing matches, callers fall back to the provider logo.
@MainActor
final class VoiceAvatarStore: ObservableObject {
    static let shared = VoiceAvatarStore()

    /// Bumped whenever an avatar is added/replaced so views re-render.
    @Published private(set) var revision = 0

    private var cache: [String: NSImage] = [:]
    private var inFlight: Set<String> = []
    private var failedUntil: [String: Date] = [:]
    static let extensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]

    enum Keys {
        static let generate = "SpeakIt.generateAvatars"
        static let style = "SpeakIt.avatarStyle"
    }

    /// DiceBear styles offered in the menu (all render a per-seed face/character).
    static let styles = ["avataaars", "adventurer", "micah", "personas",
                         "notionists", "lorelei", "open-peeps", "thumbs",
                         "bottts", "fun-emoji"]
    static let defaultStyle = "avataaars"

    var generateEnabled: Bool { UserDefaults.standard.object(forKey: Keys.generate) as? Bool ?? true }
    var style: String { UserDefaults.standard.string(forKey: Keys.style) ?? Self.defaultStyle }

    let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SpeakIt/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// Cache for auto-generated (DiceBear) avatars, so they render offline once
    /// fetched. Separate from the user-set `directory`.
    lazy var generatedDirectory: URL = {
        let d = directory.deletingLastPathComponent()
            .appendingPathComponent("avatars-generated", isDirectory: true)
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d
    }()

    /// The avatar for a provider + voice: a user-set image if present, else an
    /// auto-generated DiceBear face (fetched + cached on first miss), else nil
    /// to fall back to the provider logo.
    func image(providerId: String, voiceId: String?) -> NSImage? {
        for key in candidateKeys(providerId: providerId, voiceId: voiceId) {
            if let cached = cache[key] { return cached }
            if let url = fileURL(for: key), let img = NSImage(contentsOf: url) {
                cache[key] = img
                return img
            }
        }

        guard generateEnabled, let v = voiceId, !v.isEmpty else { return nil }
        let name = "\(sanitize(style))__\(sanitize(v))"
        if let cached = cache[name] { return cached }
        let dest = generatedDirectory.appendingPathComponent("\(name).png")
        if FileManager.default.fileExists(atPath: dest.path), let img = NSImage(contentsOf: dest) {
            cache[name] = img
            return img
        }
        ensureGenerated(seed: v, name: name)
        return nil
    }

    /// Fetch a DiceBear avatar for a seed and cache it to disk, then bump the
    /// revision so the artwork re-renders and picks it up. De-duped + backed off.
    private func ensureGenerated(seed: String, name: String) {
        if inFlight.contains(name) { return }
        if let until = failedUntil[name], until > Date() { return }
        inFlight.insert(name)
        let s = seed.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? seed
        guard let url = URL(string: "https://api.dicebear.com/9.x/\(style)/png?seed=\(s)&size=128") else {
            inFlight.remove(name); return
        }
        URLSession.shared.dataTask(with: url) { [weak self] data, resp, _ in
            Task { @MainActor in
                guard let self else { return }
                self.inFlight.remove(name)
                guard let data, (resp as? HTTPURLResponse)?.statusCode == 200,
                      NSImage(data: data) != nil else {
                    self.failedUntil[name] = Date().addingTimeInterval(300)
                    return
                }
                try? data.write(to: self.generatedDirectory.appendingPathComponent("\(name).png"))
                self.cache.removeValue(forKey: name)
                self.revision += 1
            }
        }.resume()
    }

    /// Drop in-memory caches and re-render (used when the style/toggle changes).
    func refresh() {
        cache.removeAll()
        failedUntil.removeAll()
        revision += 1
    }

    /// Delete all generated avatars so they're re-fetched fresh.
    func regenerate() {
        try? FileManager.default.removeItem(at: generatedDirectory)
        try? FileManager.default.createDirectory(at: generatedDirectory, withIntermediateDirectories: true)
        refresh()
    }

    /// Copy a chosen image in as the avatar for a specific voice, replacing any
    /// existing one. Returns the destination URL.
    @discardableResult
    func install(from source: URL, providerId: String, voiceId: String) throws -> URL {
        let stem = sanitize("\(providerId)__\(voiceId)")
        for ext in Self.extensions {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent("\(stem).\(ext)"))
        }
        let ext = source.pathExtension.isEmpty ? "png" : source.pathExtension.lowercased()
        let dest = directory.appendingPathComponent("\(stem).\(ext)")
        try FileManager.default.copyItem(at: source, to: dest)
        cache.removeAll()
        revision += 1
        return dest
    }

    private func candidateKeys(providerId: String, voiceId: String?) -> [String] {
        guard let v = voiceId, !v.isEmpty else { return [] }
        return [sanitize("\(providerId)__\(v)"), sanitize(v)]
    }

    private func fileURL(for key: String) -> URL? {
        for ext in Self.extensions {
            let url = directory.appendingPathComponent("\(key).\(ext)")
            if FileManager.default.fileExists(atPath: url.path) { return url }
        }
        return nil
    }

    private func sanitize(_ s: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
        return String(s.map { allowed.contains($0) ? $0 : "_" })
    }
}

/// Loads static image assets bundled in the app (Contents/Resources), cached.
enum BundledImage {
    private static var cache: [String: NSImage] = [:]

    static func image(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let url = Bundle.main.url(forResource: name, withExtension: "png"),
              let img = NSImage(contentsOf: url) else { return nil }
        cache[name] = img
        return img
    }
}
