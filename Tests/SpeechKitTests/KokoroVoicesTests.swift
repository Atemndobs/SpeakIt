import XCTest
@testable import SpeechKit

final class KokoroVoicesTests: XCTestCase {

    func testCatalogueMatchesTheShippedVoicePack() {
        // 54 voices in voices-v1.0.bin. A mismatch means the table and the
        // model disagree, which shows up as a voice the picker offers and the
        // daemon rejects.
        XCTAssertEqual(KokoroVoices.all.count, 54)
        XCTAssertEqual(Set(KokoroVoices.all).count, 54, "duplicate voice id")
    }

    func testEveryShippedVoiceParses() {
        let parsed = KokoroVoices.catalogue()
        XCTAssertEqual(parsed.count, KokoroVoices.all.count,
                       "a voice id in the table does not parse and would be silently dropped")
    }

    func testDefaultVoiceIsInTheCatalogue() {
        XCTAssertTrue(KokoroVoices.all.contains(KokoroVoices.defaultVoiceId))
    }

    func testNameAndLanguageDerivedFromId() {
        let heart = KokoroVoices.voice(for: "af_heart")
        XCTAssertEqual(heart?.name, "Heart")
        XCTAssertEqual(heart?.language, "en-US")
        XCTAssertEqual(heart?.espeakLanguage, "en-us")

        let george = KokoroVoices.voice(for: "bm_george")
        XCTAssertEqual(george?.name, "George")
        XCTAssertEqual(george?.language, "en-GB")
        XCTAssertEqual(george?.espeakLanguage, "en-gb")
    }

    func testMultiWordNameKeepsItsUnderscores() {
        // jf_gongitsune splits on the first underscore only; a name containing
        // more must not be truncated.
        XCTAssertEqual(KokoroVoices.voice(for: "jf_gongitsune")?.name, "Gongitsune")
        XCTAssertEqual(KokoroVoices.voice(for: "af_the_thing")?.name, "The_thing")
    }

    func testMalformedIdsAreRejectedRatherThanShownBroken() {
        XCTAssertNil(KokoroVoices.voice(for: "af"))
        XCTAssertNil(KokoroVoices.voice(for: "af_"))
        XCTAssertNil(KokoroVoices.voice(for: "_heart"))
        XCTAssertNil(KokoroVoices.voice(for: "xf_unknown"), "unknown language prefix")
        XCTAssertNil(KokoroVoices.voice(for: "aff_heart"), "prefix must be two characters")
        XCTAssertNil(KokoroVoices.voice(for: ""))
    }

    func testEspeakLanguageFallsBackRatherThanFailing() {
        // A voice the table does not know must still synthesize in some
        // language: silence would be worse than the wrong accent.
        XCTAssertEqual(KokoroVoices.espeakLanguage(for: "xx_nobody"), "en-us")
    }

    func testEveryLanguagePrefixIsCovered() {
        let prefixes = Set(KokoroVoices.all.compactMap(\.first))
        for prefix in prefixes {
            let sample = KokoroVoices.all.first { $0.first == prefix }!
            XCTAssertNotNil(KokoroVoices.voice(for: sample),
                            "language prefix '\(prefix)' has no mapping")
        }
    }
}
