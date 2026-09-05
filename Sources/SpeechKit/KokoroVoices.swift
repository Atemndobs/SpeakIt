import Foundation

/// The Kokoro-82M voice catalogue.
///
/// Voice ids encode their own metadata: `af_heart` is American English,
/// female, named Heart. Deriving the display name and language from the id
/// rather than hand-writing 54 rows means a voice pack update cannot leave the
/// table quietly disagreeing with the model about what a voice is.
public enum KokoroVoices {

    public struct Voice: Equatable, Hashable, Sendable {
        public let id: String
        public let name: String
        /// BCP-47 tag, for the app's voice list.
        public let language: String
        /// espeak-ng code, for the synthesis call.
        public let espeakLanguage: String

        public init(id: String, name: String, language: String, espeakLanguage: String) {
            self.id = id
            self.name = name
            self.language = language
            self.espeakLanguage = espeakLanguage
        }
    }

    /// First letter of a voice id maps to a language. Second letter is gender,
    /// which the app does not surface, so it is only used to skip past.
    private static let languages: [Character: (bcp47: String, espeak: String)] = [
        "a": ("en-US", "en-us"),
        "b": ("en-GB", "en-gb"),
        "e": ("es-ES", "es"),
        "f": ("fr-FR", "fr-fr"),
        "h": ("hi-IN", "hi"),
        "i": ("it-IT", "it"),
        "j": ("ja-JP", "ja"),
        "p": ("pt-BR", "pt-br"),
        "z": ("zh-CN", "cmn"),
    ]

    /// The 54 voices shipped in `voices-v1.0.bin`, in the order the app should
    /// show them: American English first, then British, then the rest
    /// alphabetically, because that matches who is actually reading English
    /// coding-agent output.
    public static let all: [String] = [
        "af_heart", "af_alloy", "af_aoede", "af_bella", "af_jessica", "af_kore",
        "af_nicole", "af_nova", "af_river", "af_sarah", "af_sky",
        "am_adam", "am_echo", "am_eric", "am_fenrir", "am_liam", "am_michael",
        "am_onyx", "am_puck", "am_santa",
        "bf_alice", "bf_emma", "bf_isabella", "bf_lily",
        "bm_daniel", "bm_fable", "bm_george", "bm_lewis",
        "ef_dora", "em_alex", "em_santa",
        "ff_siwis",
        "hf_alpha", "hf_beta", "hm_omega", "hm_psi",
        "if_sara", "im_nicola",
        "jf_alpha", "jf_gongitsune", "jf_nezumi", "jf_tebukuro", "jm_kumo",
        "pf_dora", "pm_alex", "pm_santa",
        "zf_xiaobei", "zf_xiaoni", "zf_xiaoxiao", "zf_xiaoyi",
        "zm_yunjian", "zm_yunxi", "zm_yunxia", "zm_yunyang",
    ]

    /// The default voice. `af_heart` is Kokoro's highest-rated voice in the
    /// model card's own grading, so it is what a first-time user hears.
    public static let defaultVoiceId = "af_heart"

    /// Build a voice from its id. Returns nil for an id that does not follow
    /// the `xy_name` shape, so an unknown entry is dropped rather than shown
    /// as a broken row.
    public static func voice(for id: String) -> Voice? {
        let parts = id.split(separator: "_", maxSplits: 1, omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, !parts[1].isEmpty else { return nil }
        guard let prefix = id.first, let lang = languages[prefix] else { return nil }

        let raw = String(parts[1])
        return Voice(
            id: id,
            name: raw.prefix(1).uppercased() + raw.dropFirst(),
            language: lang.bcp47,
            espeakLanguage: lang.espeak
        )
    }

    /// The catalogue, with unparseable ids dropped.
    public static func catalogue(_ ids: [String] = all) -> [Voice] {
        ids.compactMap(voice(for:))
    }

    /// espeak-ng language for a voice id, falling back to American English.
    /// The daemon derives this too; sending it explicitly keeps the two from
    /// disagreeing when only one side is updated.
    public static func espeakLanguage(for id: String) -> String {
        voice(for: id)?.espeakLanguage ?? "en-us"
    }
}
