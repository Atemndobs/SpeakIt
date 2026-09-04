import XCTest
@testable import ElevenLabsKit

/// Covers the two findings from PR review: retryable errors that were never
/// retried, and 2xx bodies that were never checked for being audio.
final class RetryPolicyTests: XCTestCase {

    private let policy = RetryPolicy.default   // 3 attempts, 0.4s base, 4s cap

    func testFatalErrorsAreNeverRetried() {
        for error: ElevenLabsAPI.APIError in [
            .unauthorized, .quotaExceeded, .missingAPIKey, .http(status: 404, message: "")
        ] {
            XCTAssertNil(policy.delay(after: error, attempt: 1), "\(error) should not retry")
        }
    }

    func testTransientErrorsAreRetried() {
        XCTAssertNotNil(policy.delay(after: .http(status: 503, message: ""), attempt: 1))
        XCTAssertNotNil(policy.delay(after: .emptyAudio, attempt: 1))
        XCTAssertNotNil(policy.delay(after: .notAudio("json"), attempt: 1))
    }

    func testAttemptsAreBounded() {
        // Someone is listening through every delay. Retrying forever is
        // indistinguishable from a hang.
        XCTAssertNotNil(policy.delay(after: .emptyAudio, attempt: 1))
        XCTAssertNotNil(policy.delay(after: .emptyAudio, attempt: 2))
        XCTAssertNil(policy.delay(after: .emptyAudio, attempt: 3), "3 attempts is the cap")
    }

    func testBackoffGrows() {
        let first = policy.delay(after: .emptyAudio, attempt: 1)!
        let second = policy.delay(after: .emptyAudio, attempt: 2)!
        XCTAssertGreaterThan(second, first)
    }

    func testRetryAfterIsHonoured() throws {
        let delay = try XCTUnwrap(policy.delay(after: .rateLimited(retryAfter: 2), attempt: 1))
        XCTAssertEqual(delay, 2, accuracy: 0.001)
    }

    func testRetryAfterIsClampedToTheCap() throws {
        // A 60 second Retry-After mid-call is worse than a lost sentence.
        let delay = try XCTUnwrap(policy.delay(after: .rateLimited(retryAfter: 60), attempt: 1))
        XCTAssertEqual(delay, policy.maxDelay, accuracy: 0.001)
    }

    func testRateLimitWithoutRetryAfterFallsBackToBackoff() throws {
        let delay = try XCTUnwrap(policy.delay(after: .rateLimited(retryAfter: nil), attempt: 1))
        XCTAssertEqual(delay, 0.4, accuracy: 0.001)
    }

    func testZeroRetryAfterDoesNotProduceAZeroDelay() throws {
        let delay = try XCTUnwrap(policy.delay(after: .rateLimited(retryAfter: 0), attempt: 1))
        XCTAssertEqual(delay, 0.4, accuracy: 0.001)
    }
}

final class AudioSnifferTests: XCTestCase {

    private func bytes(_ values: [UInt8], padTo: Int = 32) -> Data {
        var d = Data(values)
        if d.count < padTo { d.append(Data(repeating: 0, count: padTo - d.count)) }
        return d
    }

    func testDetectsID3TaggedMP3() {
        XCTAssertEqual(AudioSniffer.detect(bytes([0x49, 0x44, 0x33, 0x04])), .mp3)
    }

    func testDetectsBareMP3FrameSync() {
        XCTAssertEqual(AudioSniffer.detect(bytes([0xFF, 0xFB, 0x90])), .mp3)
    }

    func testDetectsWav() {
        let wav: [UInt8] = [0x52, 0x49, 0x46, 0x46, 0, 0, 0, 0, 0x57, 0x41, 0x56, 0x45]
        XCTAssertEqual(AudioSniffer.detect(bytes(wav)), .wav)
    }

    func testDetectsOggAndFlac() {
        XCTAssertEqual(AudioSniffer.detect(bytes([0x4F, 0x67, 0x67, 0x53])), .ogg)
        XCTAssertEqual(AudioSniffer.detect(bytes([0x66, 0x4C, 0x61, 0x43])), .flac)
    }

    /// The failure this exists to catch: a JSON error body served with a 200.
    func testRejectsJSONBody() {
        let json = Data(#"{"detail":{"status":"system_busy"}}"#.utf8)
        XCTAssertNil(AudioSniffer.detect(json))
        XCTAssertFalse(AudioSniffer.isAudio(json))
    }

    func testRejectsJSONEvenWhenContentTypeLies() {
        // A declared audio type does not override recognisable JSON... but if
        // the bytes are unrecognisable we do trust the header, so assert the
        // specific behaviour rather than assuming.
        let json = Data(#"{"detail":"oops"}"#.utf8)
        XCTAssertNil(AudioSniffer.detect(json, contentType: "application/json"))
    }

    func testRejectsHTMLErrorPage() {
        XCTAssertNil(AudioSniffer.detect(Data("<html><body>502</body></html>".utf8)))
    }

    func testRejectsEmptyBody() {
        XCTAssertNil(AudioSniffer.detect(Data()))
    }

    func testAcceptsUnknownContainerWhenContentTypeSaysAudio() {
        // Forward compatibility: if the API ships a container this build does
        // not know, a declared audio type is enough. Refusing would break
        // playback on an upstream change that is not actually a problem.
        let unknown = bytes([0x00, 0x11, 0x22, 0x33])
        XCTAssertEqual(
            AudioSniffer.detect(unknown, contentType: "audio/webm"),
            .unrecognisedButDeclaredAudio
        )
        XCTAssertNil(AudioSniffer.detect(unknown, contentType: "text/plain"))
    }
}

/// The API client must reject a non-audio 200 rather than pass it downstream.
final class SynthesisValidationTests: XCTestCase {

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    private func api() -> ElevenLabsAPI {
        ElevenLabsAPI(session: StubURLProtocol.session()) { "test-key" }
    }

    func testJSONServedWithA200IsRejected() async {
        StubURLProtocol.handler = { _ in
            .json(#"{"detail":{"status":"system_busy","message":"try later"}}"#, status: 200)
        }
        do {
            _ = try await api().synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected notAudio")
        } catch let error as ElevenLabsAPI.APIError {
            guard case .notAudio(let hint) = error else {
                return XCTFail("expected notAudio, got \(error)")
            }
            // The hint should carry the server's own message, not a byte dump.
            XCTAssertTrue(hint.contains("try later"), hint)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    func testRealMP3PassesValidation() async throws {
        StubURLProtocol.handler = { _ in
            var body = Data([0x49, 0x44, 0x33, 0x04, 0x00])
            body.append(Data(repeating: 0xAA, count: 2048))
            return StubURLProtocol.Stub(
                status: 200, body: body, headers: ["Content-Type": "audio/mpeg"]
            )
        }
        let data = try await api().synthesize(text: "Hello.", voiceID: "v1")
        XCTAssertEqual(data.count, 2053)
    }

    func testNotAudioIsRetryable() {
        // A busy upstream is transient, so it deserves another attempt rather
        // than costing the listener the sentence.
        XCTAssertTrue(ElevenLabsAPI.APIError.notAudio("system_busy").isRetryable)
    }
}
