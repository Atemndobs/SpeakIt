import XCTest
@testable import SpeechKit

final class VoiceSelectionTests: XCTestCase {

    private let kokoro = ["af_heart", "bm_george", "jf_alpha"]
    private let apple = ["com.apple.voice.premium.en-GB.Malcolm", "com.apple.voice.compact.en-US.Samantha"]

    // MARK: canPersist

    func testTheActualCorruptionIsRejected() {
        // The observed bug: an Apple voice id stored under the Kokoro key.
        // Kokoro ids look like af_heart, so this could never have come from
        // Kokoro, and it must not be writable against it.
        XCTAssertFalse(
            VoiceSelection.canPersist("com.apple.voice.premium.en-GB.Malcolm", available: kokoro)
        )
    }

    func testAVoiceTheProviderOffersIsPersisted() {
        XCTAssertTrue(VoiceSelection.canPersist("af_heart", available: kokoro))
    }

    func testClearingIsAlwaysAllowed() {
        // Deselecting is a legitimate state and must not be blocked.
        XCTAssertTrue(VoiceSelection.canPersist(nil, available: kokoro))
        XCTAssertTrue(VoiceSelection.canPersist("", available: kokoro))
    }

    func testAnUnloadedCatalogueDoesNotBlockPersistence() {
        // ElevenLabs fetches voices over the network. An empty list means "not
        // loaded yet", not "offers nothing". Refusing here would erase the
        // user's saved choice on every cold launch.
        XCTAssertTrue(VoiceSelection.canPersist("any-elevenlabs-id", available: []))
    }

    // MARK: resolve

    func testStoredChoiceWins() {
        XCTAssertEqual(
            VoiceSelection.resolve(stored: "bm_george", available: kokoro, ranked: kokoro),
            "bm_george"
        )
    }

    func testForeignStoredIdFallsBackRatherThanBeingHonoured() {
        // This is what made the bug invisible: a corrupted id is silently
        // replaced, so nothing ever looks wrong.
        XCTAssertEqual(
            VoiceSelection.resolve(
                stored: "com.apple.voice.premium.en-GB.Malcolm",
                available: kokoro,
                ranked: kokoro
            ),
            "af_heart"
        )
    }

    func testPreferredDefaultBeatsTheGenericRanking() {
        let edge = ["en-US-AvaNeural", "en-GB-SoniaNeural"]
        XCTAssertEqual(
            VoiceSelection.resolve(
                stored: nil,
                available: edge,
                preferred: "en-GB-SoniaNeural",
                ranked: edge
            ),
            "en-GB-SoniaNeural"
        )
    }

    func testPreferredIsIgnoredWhenTheProviderDoesNotOfferIt() {
        XCTAssertEqual(
            VoiceSelection.resolve(
                stored: nil,
                available: kokoro,
                preferred: "en-GB-SoniaNeural",
                ranked: kokoro
            ),
            "af_heart"
        )
    }

    func testRankingIsUsedWhenNothingElseApplies() {
        XCTAssertEqual(
            VoiceSelection.resolve(
                stored: nil,
                available: ["b", "a", "c"],
                ranked: ["c", "a"]
            ),
            "c"
        )
    }

    func testFallsBackToTheFirstVoiceWhenTheRankingMatchesNothing() {
        XCTAssertEqual(
            VoiceSelection.resolve(stored: nil, available: ["only"], ranked: ["absent"]),
            "only"
        )
    }

    func testUnloadedCatalogueKeepsTheStoredChoice() {
        // Must not reset the user's ElevenLabs voice to nil before the
        // catalogue arrives.
        XCTAssertEqual(
            VoiceSelection.resolve(stored: "saved-id", available: [], ranked: []),
            "saved-id"
        )
    }

    func testNoVoicesAtAllResolvesToNil() {
        XCTAssertNil(VoiceSelection.resolve(stored: nil, available: [], ranked: []))
    }

    // MARK: corruptedProviders

    func testCorruptedKeysAreIdentifiedForCleanup() {
        let found = VoiceSelection.corruptedProviders(
            stored: [
                "kokoro": "com.apple.voice.premium.en-GB.Malcolm",  // corrupted
                "apple": "com.apple.voice.premium.en-GB.Malcolm",   // legitimate
            ],
            catalogues: ["kokoro": kokoro, "apple": apple]
        )
        XCTAssertEqual(found, ["kokoro"])
    }

    func testUnloadedCatalogueIsSkippedNotWiped() {
        // An ElevenLabs key must survive a launch where the network was slow.
        // Treating "not loaded" as "invalid" would delete a good setting.
        XCTAssertEqual(
            VoiceSelection.corruptedProviders(
                stored: ["elevenlabs": "some-id"],
                catalogues: ["elevenlabs": []]
            ),
            []
        )
    }

    func testEmptyAndUnknownEntriesAreLeftAlone() {
        XCTAssertEqual(
            VoiceSelection.corruptedProviders(
                stored: ["kokoro": nil, "edge-tts": "", "ghost": "x"],
                catalogues: ["kokoro": kokoro, "edge-tts": ["a"]]
            ),
            []
        )
    }

    func testACleanInstallReportsNothingToHeal() {
        XCTAssertEqual(
            VoiceSelection.corruptedProviders(
                stored: ["kokoro": "af_heart", "apple": apple[0]],
                catalogues: ["kokoro": kokoro, "apple": apple]
            ),
            []
        )
    }

    // MARK: the switch that caused it

    func testSwitchingProvidersCannotLeakAVoiceAcrossKeys() {
        // Walks the sequence that produced the bug: Apple is active with an
        // Apple voice, the user switches to Kokoro, and during the switch the
        // engine briefly holds the new provider with the old voice.
        let carriedOver = apple[0]

        XCTAssertFalse(
            VoiceSelection.canPersist(carriedOver, available: kokoro),
            "the write in the switch window must be refused"
        )
        XCTAssertEqual(
            VoiceSelection.resolve(stored: nil, available: kokoro, ranked: kokoro),
            "af_heart",
            "and the switch should land on Kokoro's own default"
        )
    }
}
