import Foundation
import Security

/// The ElevenLabs API key, stored in the macOS Keychain.
///
/// Deliberately not `UserDefaults`. Every other setting in SpeakIt is a
/// preference; this one is a bearer credential that bills money to the user's
/// account. `UserDefaults` writes a plist in `~/Library/Preferences` that is
/// world-readable to anything running as the user, ends up in backups, and is
/// trivially recoverable. The Keychain is the right store and the cost is about
/// forty lines.
///
/// The item is `kSecAttrAccessibleWhenUnlocked`, so it is unreadable while the
/// Mac is locked and never syncs to iCloud.
///
/// Note: `LLMSettings` already stores the Reader AI key in the Keychain under a
/// different service. This is deliberately not shared with it yet. That helper
/// deletes and re-adds on every write, sets no accessibility attribute and
/// ignores its `OSStatus`, and it lives inside the `@main` executable where it
/// cannot be tested. Folding both onto this implementation is a worthwhile
/// follow-up, but it would change behaviour for an unrelated feature and does
/// not belong in the same change as adding a provider.
public final class ElevenLabsCredentials: @unchecked Sendable {

    public static let shared = ElevenLabsCredentials()

    private let service: String
    private let account: String
    private let lock = NSLock()
    private var cached: String??

    public init(
        service: String = "com.atemkeng.speakit.elevenlabs",
        account: String = "api-key"
    ) {
        self.service = service
        self.account = account
    }

    // MARK: - Read

    /// The stored key, or nil. Cached after the first read because the provider
    /// asks for it on every synthesis call and a Keychain hit per sentence is
    /// needless.
    public var apiKey: String? {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let value = readFromKeychain()
        cached = .some(value)
        return value
    }

    /// Where the key currently in use came from.
    ///
    /// Exists because a stale `ELEVENLABS_API_KEY` in a shell silently
    /// overrides a correct key in the Keychain, and the resulting "rejected"
    /// message gives no hint that this is what happened. Naming the source
    /// turns a confusing failure into an obvious one.
    public enum Source: String {
        case environment = "the ELEVENLABS_API_KEY environment variable"
        case keychain = "the Keychain"
        case none = "nowhere"

        public var overridesKeychain: Bool { self == .environment }
    }

    public var source: Source {
        if let fromEnv = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
           !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return .environment
        }
        return hasKey ? .keychain : .none
    }

    public var hasKey: Bool {
        guard let key = apiKey else { return false }
        return !key.isEmpty
    }

    /// Last four characters, for showing "sk-...a1b2" in settings without
    /// putting the key back on screen.
    public var maskedKey: String? {
        guard let key = apiKey, key.count >= 4 else { return nil }
        return "\u{2022}\u{2022}\u{2022}\u{2022}" + key.suffix(4)
    }

    // MARK: - Write

    @discardableResult
    public func store(_ key: String) -> Bool {
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return delete() }

        lock.lock()
        defer { lock.unlock() }

        guard let data = trimmed.data(using: .utf8) else { return false }

        // Update in place if the item exists, otherwise add. SecItemAdd on an
        // existing item returns errSecDuplicateItem rather than overwriting.
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let updateStatus = SecItemUpdate(
            query as CFDictionary,
            [kSecValueData as String: data] as CFDictionary
        )

        let status: OSStatus
        if updateStatus == errSecItemNotFound {
            var add = query
            add[kSecValueData as String] = data
            add[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            add[kSecAttrSynchronizable as String] = false
            add[kSecAttrLabel as String] = "SpeakIt: ElevenLabs API key"
            status = SecItemAdd(add as CFDictionary, nil)
        } else {
            status = updateStatus
        }

        guard status == errSecSuccess else {
            cached = nil
            return false
        }
        cached = .some(trimmed)
        return true
    }

    @discardableResult
    public func delete() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        cached = .some(nil)
        return status == errSecSuccess || status == errSecItemNotFound
    }

    /// Drop the in-memory copy. Used by tests and after an external change.
    public func invalidateCache() {
        lock.lock()
        cached = nil
        lock.unlock()
    }

    // MARK: - Keychain

    private func readFromKeychain() -> String? {
        // An environment variable wins, so CI and the live integration test can
        // run without touching the developer's Keychain.
        if let fromEnv = ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"],
           !fromEnv.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return fromEnv.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let string = String(data: data, encoding: .utf8)
        else { return nil }
        return string.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
