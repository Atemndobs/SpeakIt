import Foundation
import Security

enum LLMProvider: String, CaseIterable, Identifiable {
    case ollama
    case openai

    var id: String { rawValue }
    var label: String {
        switch self {
        case .ollama: return "Ollama (local)"
        case .openai: return "OpenAI-compatible"
        }
    }
    var defaultBaseURL: String {
        switch self {
        case .ollama: return "http://localhost:11434/v1"
        case .openai: return "https://generativelanguage.googleapis.com/v1beta/openai"
        }
    }
    var defaultModel: String {
        switch self {
        case .ollama: return "llama3.2"
        case .openai: return "gemini-2.0-flash"
        }
    }
}

@MainActor
final class LLMSettings: ObservableObject {
    static let shared = LLMSettings()

    private static let providerKey = "SpeakIt.llm.provider"
    private static let baseURLKey  = "SpeakIt.llm.baseURL"
    private static let modelKey    = "SpeakIt.llm.model"
    private static let enabledKey  = "SpeakIt.llm.enabled"
    private static let kcService   = "com.atem.SpeakIt.llm"
    private static let kcAccount   = "apiKey"

    @Published var provider: LLMProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: Self.providerKey)
            restartServerIfNeeded()
        }
    }
    @Published var baseURL: String {
        didSet { UserDefaults.standard.set(baseURL, forKey: Self.baseURLKey); restartServerIfNeeded() }
    }
    @Published var model: String {
        didSet { UserDefaults.standard.set(model, forKey: Self.modelKey); restartServerIfNeeded() }
    }
    @Published var enabled: Bool {
        didSet { UserDefaults.standard.set(enabled, forKey: Self.enabledKey); restartServerIfNeeded() }
    }
    @Published var apiKey: String {
        didSet { Self.storeKey(apiKey); restartServerIfNeeded() }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.providerKey) ?? LLMProvider.ollama.rawValue
        let p = LLMProvider(rawValue: raw) ?? .ollama
        provider = p
        baseURL = UserDefaults.standard.string(forKey: Self.baseURLKey) ?? p.defaultBaseURL
        model = UserDefaults.standard.string(forKey: Self.modelKey) ?? p.defaultModel
        enabled = UserDefaults.standard.bool(forKey: Self.enabledKey)
        apiKey = Self.loadKey() ?? ""
    }

    func applyProviderDefaults() {
        baseURL = provider.defaultBaseURL
        model = provider.defaultModel
    }

    private func restartServerIfNeeded() {
        let s = LocalFileServer.shared
        if s.isRunning { s.restart() }
    }

    private static func loadKey() -> String? {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: AnyObject?
        guard SecItemCopyMatching(q as CFDictionary, &item) == errSecSuccess,
              let data = item as? Data,
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }

    private static func storeKey(_ value: String) {
        let q: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: kcService,
            kSecAttrAccount as String: kcAccount,
        ]
        SecItemDelete(q as CFDictionary)
        guard !value.isEmpty, let data = value.data(using: .utf8) else { return }
        var add = q
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }
}
