import Foundation

/// Choosing and persisting the voice for a provider.
///
/// The app remembers a voice per engine, under a key derived from whichever
/// engine is active when the write happens. That is the whole problem: during
/// a switch there is a moment when the new engine is already active and the
/// voice is still the old engine's, and a write landing in that window files,
/// say, an Apple voice id under the Kokoro key.
///
/// It self-heals, because a stored id the provider does not offer is rejected
/// on the next switch and replaced by a default. So nothing looks broken. The
/// only symptom is that "remember my voice per engine" quietly forgets, which
/// is the kind of bug that survives for months.
///
/// Pure and tested here rather than inline in the engine, because the rule is
/// an invariant worth stating once: a voice is only ever stored against a
/// provider that offers it.
public enum VoiceSelection {

    /// Whether `voiceId` may be persisted as the choice for a provider whose
    /// catalogue is `available`.
    ///
    /// An empty catalogue means "not loaded yet", not "offers nothing".
    /// ElevenLabs fetches its voices over the network, so on a cold launch its
    /// list is briefly empty; refusing to persist then would erase the user's
    /// saved choice every time they open the app before the request returns.
    public static func canPersist(_ voiceId: String?, available: [String]) -> Bool {
        guard let voiceId, !voiceId.isEmpty else { return true }  // clearing is legitimate
        if available.isEmpty { return true }
        return available.contains(voiceId)
    }

    /// Pick the voice to use for a provider.
    ///
    /// - Parameters:
    ///   - stored: what the user last chose for this provider, if anything.
    ///   - available: the provider's catalogue, empty when not yet loaded.
    ///   - preferred: a provider-specific default worth honouring over the
    ///     generic ranking (the app prefers one particular Edge voice).
    ///   - ranked: fallback ids in descending preference, typically ordered by
    ///     voice quality.
    ///
    /// Returns nil only when the provider genuinely offers nothing.
    public static func resolve(
        stored: String?,
        available: [String],
        preferred: String? = nil,
        ranked: [String] = []
    ) -> String? {
        // Nothing to validate against yet. Keep the stored choice rather than
        // resetting it to a default the user did not pick.
        if available.isEmpty { return stored }

        if let stored, available.contains(stored) { return stored }
        if let preferred, available.contains(preferred) { return preferred }
        if let best = ranked.first(where: available.contains) { return best }
        return available.first
    }

    /// Stored voice keys that no longer name a voice their provider offers.
    ///
    /// Existing installs already carry corrupted entries written before the
    /// guard existed, and those outlive the fix. Called once at launch to clear
    /// them, so the setting starts telling the truth.
    ///
    /// - Parameter catalogues: provider id to its available voice ids. A
    ///   provider whose catalogue has not loaded is skipped rather than wiped.
    public static func corruptedProviders(
        stored: [String: String?],
        catalogues: [String: [String]]
    ) -> [String] {
        stored.compactMap { providerId, voiceId in
            guard let voiceId, !voiceId.isEmpty else { return nil }
            guard let available = catalogues[providerId], !available.isEmpty else { return nil }
            return available.contains(voiceId) ? nil : providerId
        }
        .sorted()
    }
}
