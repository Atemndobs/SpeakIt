import Foundation

/// A voice as ElevenLabs describes it.
///
/// Decoded loosely on purpose. The catalogue gains fields regularly and a
/// strict decoder would turn a harmless upstream addition into "no voices
/// found" for the user.
public struct ElevenLabsVoice: Decodable, Identifiable, Hashable, Sendable {
    public let voiceID: String
    public let name: String
    public let category: String?
    public let description: String?
    public let previewURL: String?
    public let labels: [String: String]

    public var id: String { voiceID }

    enum CodingKeys: String, CodingKey {
        case voiceID = "voice_id"
        case name
        case category
        case description
        case previewURL = "preview_url"
        case labels
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voiceID = try c.decode(String.self, forKey: .voiceID)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? "Unnamed"
        category = try c.decodeIfPresent(String.self, forKey: .category)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        previewURL = try c.decodeIfPresent(String.self, forKey: .previewURL)
        // Labels are documented as string:string but have shipped nulls before.
        labels = (try? c.decodeIfPresent([String: String?].self, forKey: .labels))?
            .map { $0.compactMapValues { $0 } } ?? [:]
    }

    public init(
        voiceID: String,
        name: String,
        category: String? = nil,
        description: String? = nil,
        previewURL: String? = nil,
        labels: [String: String] = [:]
    ) {
        self.voiceID = voiceID
        self.name = name
        self.category = category
        self.description = description
        self.previewURL = previewURL
        self.labels = labels
    }

    /// Best-effort locale for the picker.
    ///
    /// ElevenLabs voices are not locale-scoped the way Apple and Edge voices
    /// are: with a multilingual model one voice speaks many languages, so the
    /// accent label is the closest honest equivalent.
    public var accent: String {
        labels["accent"]
            ?? labels["language"]
            ?? "multilingual"
    }

    /// Label shown in the voice menu, e.g. "Rachel (american, calm)".
    public var displayName: String {
        let parts = [labels["accent"], labels["description"]].compactMap { $0 }
        guard !parts.isEmpty else { return name }
        return "\(name) (\(parts.joined(separator: ", ")))"
    }

    /// Cloned voices are the user's own and belong at the top of the list.
    public var isCloned: Bool {
        guard let category else { return false }
        return category == "cloned" || category == "professional" || category == "generated"
    }
}

/// Synthesis knobs. Defaults match the ElevenLabs recommended starting point.
public struct ElevenLabsVoiceSettings: Codable, Hashable, Sendable {
    public var stability: Double
    public var similarityBoost: Double
    public var style: Double?
    public var useSpeakerBoost: Bool?

    enum CodingKeys: String, CodingKey {
        case stability
        case similarityBoost = "similarity_boost"
        case style
        case useSpeakerBoost = "use_speaker_boost"
    }

    public init(
        stability: Double = 0.5,
        similarityBoost: Double = 0.75,
        style: Double? = nil,
        useSpeakerBoost: Bool? = nil
    ) {
        self.stability = stability
        self.similarityBoost = similarityBoost
        self.style = style
        self.useSpeakerBoost = useSpeakerBoost
    }

    public static let `default` = ElevenLabsVoiceSettings()
}

/// Character quota for the current billing period.
public struct ElevenLabsSubscription: Decodable, Sendable {
    public let tier: String?
    public let characterCount: Int
    public let characterLimit: Int
    public let nextResetUnix: Int?

    enum CodingKeys: String, CodingKey {
        case tier
        case characterCount = "character_count"
        case characterLimit = "character_limit"
        case nextResetUnix = "next_character_count_reset_unix"
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        tier = try c.decodeIfPresent(String.self, forKey: .tier)
        characterCount = try c.decodeIfPresent(Int.self, forKey: .characterCount) ?? 0
        characterLimit = try c.decodeIfPresent(Int.self, forKey: .characterLimit) ?? 0
        nextResetUnix = try c.decodeIfPresent(Int.self, forKey: .nextResetUnix)
    }

    public init(tier: String?, characterCount: Int, characterLimit: Int, nextResetUnix: Int? = nil) {
        self.tier = tier
        self.characterCount = characterCount
        self.characterLimit = characterLimit
        self.nextResetUnix = nextResetUnix
    }

    public var charactersRemaining: Int { max(0, characterLimit - characterCount) }

    public var fractionUsed: Double {
        guard characterLimit > 0 else { return 0 }
        return min(1, Double(characterCount) / Double(characterLimit))
    }

    /// One line for the settings panel.
    public var summary: String {
        guard characterLimit > 0 else { return tier ?? "connected" }
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        let remaining = formatter.string(from: NSNumber(value: charactersRemaining)) ?? "\(charactersRemaining)"
        let limit = formatter.string(from: NSNumber(value: characterLimit)) ?? "\(characterLimit)"
        let tierLabel = tier.map { "\($0): " } ?? ""
        return "\(tierLabel)\(remaining) of \(limit) characters left"
    }
}
