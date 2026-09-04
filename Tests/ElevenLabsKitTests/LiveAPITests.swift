import XCTest
@testable import ElevenLabsKit

/// The one test that talks to the real ElevenLabs API.
///
/// Skipped unless `ELEVENLABS_API_KEY` is set, so the suite stays green on a
/// machine without a key and in CI. Everything else in this target runs against
/// a stubbed `URLSession`; this exists because a mocked client only proves the
/// code matches my belief about the API, not that the belief is right.
///
///     ELEVENLABS_API_KEY=xi-... swift test --filter LiveAPITests
///
/// Synthesis costs characters, so the test speaks one short sentence.
final class LiveAPITests: XCTestCase {

    private var api: ElevenLabsAPI!

    override func setUpWithError() throws {
        try XCTSkipIf(
            (ProcessInfo.processInfo.environment["ELEVENLABS_API_KEY"] ?? "").isEmpty,
            "Set ELEVENLABS_API_KEY to run the live API tests"
        )
        api = ElevenLabsAPI()
    }

    func testLiveKeyIsValidAndQuotaIsReadable() async throws {
        let subscription = try await api.subscription()
        XCTAssertGreaterThan(subscription.characterLimit, 0)
        print("[live] \(subscription.summary)")
    }

    func testLiveVoiceCatalogueDecodes() async throws {
        let voices = try await api.listVoices()
        XCTAssertFalse(voices.isEmpty, "expected at least one voice on the account")
        for voice in voices {
            XCTAssertFalse(voice.voiceID.isEmpty)
            XCTAssertFalse(voice.name.isEmpty)
        }
        print("[live] \(voices.count) voices, first: \(voices[0].displayName)")
    }

    /// The real proof: one sentence in, playable audio out.
    func testLiveSynthesisReturnsPlayableMP3() async throws {
        let voices = try await api.listVoices()
        let voice = try XCTUnwrap(voices.first)

        let started = Date()
        let audio = try await api.synthesize(
            text: "SpeakIt now reads with ElevenLabs.",
            voiceID: voice.voiceID
        )
        let elapsed = Date().timeIntervalSince(started)

        XCTAssertGreaterThan(audio.count, 1_000, "suspiciously small audio payload")

        // Verify it is actually an MP3 rather than a JSON error body that
        // happened to arrive with a 200. Frame sync is 0xFF 0xEx, and files
        // often open with an ID3 tag.
        let head = [UInt8](audio.prefix(3))
        let isID3 = head.count >= 3 && head[0] == 0x49 && head[1] == 0x44 && head[2] == 0x33
        let isFrameSync = head.count >= 2 && head[0] == 0xFF && (head[1] & 0xE0) == 0xE0
        XCTAssertTrue(isID3 || isFrameSync, "not an MP3: first bytes \(head)")

        print("[live] \(audio.count) bytes in \(String(format: "%.2f", elapsed))s using \(voice.displayName)")

        // Keep the artifact so the audio can actually be listened to. A test
        // that asserts bytes exist but never plays them is not proof of much.
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("speakit-live-test.mp3")
        try audio.write(to: out)
        print("[live] wrote \(out.path)")
    }

    func testLiveBadKeyIsRejectedCleanly() async {
        // Confirms the 401 mapping against the real service rather than a stub.
        let bad = ElevenLabsAPI { "xi-definitely-not-a-real-key" }
        let result = await bad.validateKey()
        switch result {
        case .success:
            XCTFail("a bogus key should not validate")
        case .failure(let error):
            XCTAssertEqual(error, .unauthorized, "got \(error) instead")
        }
    }
}
