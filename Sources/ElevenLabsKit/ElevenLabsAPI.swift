import Foundation

/// Minimal ElevenLabs client: voice discovery, quota, and streaming synthesis.
///
/// Kept in its own library target rather than inside the app so it can be
/// tested. `SpeakIt` is an `@main` executable and executables are awkward to
/// import from a test target; the networking and parsing are the parts worth
/// testing anyway, and they have no AppKit dependency.
///
/// The `URLSession` is injected so tests can drive it through a stub protocol
/// without touching the network, and the one test that does hit the real API is
/// gated on a key being present.
public struct ElevenLabsAPI: Sendable {

    public static let defaultBaseURL = URL(string: "https://api.elevenlabs.io")!

    /// Turbo is the right default for a reader: this synthesizes sentence by
    /// sentence while the previous one is still playing, so time to first audio
    /// matters far more than the marginal quality of a slower model.
    public static let defaultModelID = "eleven_turbo_v2_5"

    private let baseURL: URL
    private let session: URLSession
    private let apiKeyProvider: @Sendable () -> String?

    public init(
        baseURL: URL = ElevenLabsAPI.defaultBaseURL,
        session: URLSession = .shared,
        apiKey: @escaping @Sendable () -> String?
    ) {
        self.baseURL = baseURL
        self.session = session
        self.apiKeyProvider = apiKey
    }

    /// Convenience for the app, which keeps the key in the Keychain.
    public init(baseURL: URL = ElevenLabsAPI.defaultBaseURL, session: URLSession = .shared) {
        self.init(baseURL: baseURL, session: session) { ElevenLabsCredentials.shared.apiKey }
    }

    // MARK: - Errors

    public enum APIError: LocalizedError, Equatable {
        case missingAPIKey
        case unauthorized
        /// The key is valid but was created without a required scope.
        /// Distinct from `unauthorized` on purpose: telling someone their key
        /// was rejected when it is actually fine sends them off to revoke and
        /// recreate a perfectly good credential.
        case missingPermission(scope: String)
        /// The plan does not allow this. Free accounts cannot use shared
        /// library voices through the API, which is the common case.
        case paidPlanRequired(String)
        case rateLimited(retryAfter: TimeInterval?)
        case quotaExceeded
        case http(status: Int, message: String)
        case emptyAudio
        /// A 2xx body that is not audio. Usually a JSON error served with a 200.
        case notAudio(String)
        case malformedResponse(String)

        public var errorDescription: String? {
            switch self {
            case .missingAPIKey:
                return "No ElevenLabs API key. Add one in SpeakIt settings."
            case .unauthorized:
                return "ElevenLabs rejected the API key."
            case .missingPermission(let scope):
                return "The API key is valid but lacks the '\(scope)' permission. "
                     + "Edit the key at elevenlabs.io/app/settings/api-keys and grant it."
            case .paidPlanRequired(let message):
                return "ElevenLabs plan limit: \(message)"
            case .rateLimited(let retryAfter):
                if let retryAfter {
                    return "ElevenLabs rate limit reached. Retry in \(Int(retryAfter))s."
                }
                return "ElevenLabs rate limit reached."
            case .quotaExceeded:
                return "ElevenLabs character quota exhausted for this billing period."
            case .http(let status, let message):
                return "ElevenLabs returned \(status): \(message)"
            case .emptyAudio:
                return "ElevenLabs returned no audio."
            case .notAudio(let hint):
                return "ElevenLabs returned something that is not audio: \(hint)"
            case .malformedResponse(let detail):
                return "Could not read the ElevenLabs response: \(detail)"
            }
        }

        /// Whether retrying the same request could plausibly succeed.
        /// A bad key or an exhausted quota will not fix itself on retry, and
        /// retrying them just burns time while the user waits for audio.
        public var isRetryable: Bool {
            switch self {
            case .missingPermission, .paidPlanRequired:
                // Retrying cannot grant a scope or upgrade a plan.
                return false
            case .rateLimited, .emptyAudio, .notAudio:
                // notAudio is usually a transient upstream hiccup rather than a
                // permanent contract change, so it is worth one more attempt.
                return true
            case .http(let status, _):
                return status >= 500
            default:
                return false
            }
        }
    }

    // MARK: - Voices

    public func listVoices() async throws -> [ElevenLabsVoice] {
        let data = try await get("/v1/voices")
        do {
            return try JSONDecoder().decode(VoicesResponse.self, from: data).voices
        } catch {
            throw APIError.malformedResponse("voices: \(error.localizedDescription)")
        }
    }

    /// Character quota for the current billing period.
    ///
    /// Worth surfacing in a reader. Unlike the offline Apple and Edge providers,
    /// this one has a meter running, and a user who cannot see it will discover
    /// the limit by having playback stop mid-article.
    public func subscription() async throws -> ElevenLabsSubscription {
        let data = try await get("/v1/user/subscription")
        do {
            return try JSONDecoder().decode(ElevenLabsSubscription.self, from: data)
        } catch {
            throw APIError.malformedResponse("subscription: \(error.localizedDescription)")
        }
    }

    /// Cheap credential check used by the settings UI.
    public func validateKey() async -> Result<ElevenLabsSubscription, APIError> {
        do {
            return .success(try await subscription())
        } catch let error as APIError {
            return .failure(error)
        } catch {
            return .failure(.malformedResponse(error.localizedDescription))
        }
    }

    // MARK: - Synthesis

    /// Synthesize one chunk of text and return the encoded audio.
    ///
    /// Uses the `/stream` endpoint with a low latency optimization because the
    /// caller plays sentence by sentence. The whole body is still collected
    /// before returning: `AVAudioPlayer` needs a complete file, and a sentence
    /// is short enough that collecting it costs little. Progressive playback of
    /// a partial mp3 would need `AVAudioEngine` and buffer scheduling, which is
    /// a real improvement and not one this change makes.
    public func synthesize(
        text: String,
        voiceID: String,
        modelID: String = ElevenLabsAPI.defaultModelID,
        settings: ElevenLabsVoiceSettings = .default,
        outputFormat: String = "mp3_44100_128",
        latencyOptimization: Int = 3
    ) async throws -> Data {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw APIError.emptyAudio }

        var components = URLComponents(
            url: baseURL.appendingPathComponent("/v1/text-to-speech/\(voiceID)/stream"),
            resolvingAgainstBaseURL: false
        )!
        components.queryItems = [
            URLQueryItem(name: "optimize_streaming_latency", value: String(latencyOptimization)),
            URLQueryItem(name: "output_format", value: outputFormat),
        ]

        var request = try makeRequest(url: components.url!)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("audio/mpeg", forHTTPHeaderField: "Accept")
        request.httpBody = try JSONEncoder().encode(
            SynthesisRequest(text: trimmed, modelID: modelID, voiceSettings: settings)
        )

        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, body: data)
        guard !data.isEmpty else { throw APIError.emptyAudio }

        // A 2xx is not a promise of audio. A JSON error body can arrive with a
        // 200, and handing that to AVAudioPlayer fails deep in the provider,
        // where it looks to the listener like a silently skipped sentence
        // rather than an error. Check the bytes here, where it can be reported.
        let contentType = (response as? HTTPURLResponse)?
            .value(forHTTPHeaderField: "Content-Type")
        guard AudioSniffer.isAudio(data, contentType: contentType) else {
            let hint = Self.errorMessage(from: data) ?? "response was not audio"
            throw APIError.notAudio(hint)
        }
        return data
    }

    // MARK: - Plumbing

    private func makeRequest(url: URL) throws -> URLRequest {
        guard let key = apiKeyProvider(), !key.isEmpty else { throw APIError.missingAPIKey }
        var request = URLRequest(url: url)
        request.setValue(key, forHTTPHeaderField: "xi-api-key")
        request.timeoutInterval = 30
        return request
    }

    private func get(_ path: String) async throws -> Data {
        let request = try makeRequest(url: baseURL.appendingPathComponent(path))
        let (data, response) = try await session.data(for: request)
        try Self.check(response: response, body: data)
        return data
    }

    static func check(response: URLResponse, body: Data) throws {
        guard let http = response as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200..<300:
            return
        case 401, 403:
            // A scoped key that is missing a permission also arrives as a 401,
            // but it means something completely different from a bad key.
            if let scope = Self.missingScope(from: body) {
                throw APIError.missingPermission(scope: scope)
            }
            throw APIError.unauthorized
        case 402:
            throw APIError.paidPlanRequired(Self.errorMessage(from: body) ?? "upgrade required")
        case 429:
            let retry = (http.value(forHTTPHeaderField: "Retry-After")).flatMap(TimeInterval.init)
            throw APIError.rateLimited(retryAfter: retry)
        default:
            let message = Self.errorMessage(from: body) ?? "unknown error"
            // 422 with a quota detail is the one people actually hit, and it
            // deserves its own message rather than a raw status code.
            if message.lowercased().contains("quota") {
                throw APIError.quotaExceeded
            }
            throw APIError.http(status: http.statusCode, message: message)
        }
    }

    /// ElevenLabs returns `{"detail": {"message": "...", "status": "..."}}` in
    /// some cases and `{"detail": "..."}` in others. Handle both rather than
    /// showing the user a raw JSON blob.
    /// Pull the scope name out of "missing the permission X to execute".
    ///
    /// The status field is the reliable signal; the scope name is parsed from
    /// the message purely so the error can name it, and a parse failure
    /// degrades to a generic scope rather than misreporting a bad key.
    static func missingScope(from data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let detail = object["detail"] as? [String: Any],
              (detail["status"] as? String) == "missing_permissions"
        else { return nil }

        let message = (detail["message"] as? String) ?? ""
        if let range = message.range(of: "missing the permission "),
           let end = message[range.upperBound...].firstIndex(of: " ") {
            return String(message[range.upperBound..<end])
        }
        return "required"
    }

    static func errorMessage(from data: Data) -> String? {
        guard !data.isEmpty,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }

        if let detail = object["detail"] as? String { return detail }
        if let detail = object["detail"] as? [String: Any] {
            if let message = detail["message"] as? String { return message }
            if let status = detail["status"] as? String { return status }
        }
        if let message = object["message"] as? String { return message }
        return nil
    }

    private struct VoicesResponse: Decodable {
        let voices: [ElevenLabsVoice]
    }

    private struct SynthesisRequest: Encodable {
        let text: String
        let modelID: String
        let voiceSettings: ElevenLabsVoiceSettings

        enum CodingKeys: String, CodingKey {
            case text
            case modelID = "model_id"
            case voiceSettings = "voice_settings"
        }
    }
}
