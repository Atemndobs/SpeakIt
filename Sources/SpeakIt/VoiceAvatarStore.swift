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
    static let extensions = ["png", "jpg", "jpeg", "heic", "webp", "gif", "tiff"]

    let directory: URL = {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("SpeakIt/avatars", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base
    }()

    /// The avatar for a provider + voice, or nil to fall back to the logo.
    func image(providerId: String, voiceId: String?) -> NSImage? {
        for key in candidateKeys(providerId: providerId, voiceId: voiceId) {
            if let cached = cache[key] { return cached }
            if let url = fileURL(for: key), let img = NSImage(contentsOf: url) {
                cache[key] = img
                return img
            }
        }
        return nil
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
