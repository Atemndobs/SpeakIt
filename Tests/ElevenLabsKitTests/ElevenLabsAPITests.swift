import XCTest
@testable import ElevenLabsKit

final class ElevenLabsAPITests: XCTestCase {

    private var api: ElevenLabsAPI!

    override func setUp() {
        super.setUp()
        StubURLProtocol.reset()
        api = ElevenLabsAPI(session: StubURLProtocol.session()) { "test-key" }
    }

    override func tearDown() {
        StubURLProtocol.reset()
        super.tearDown()
    }

    // MARK: - Auth

    func testRequestsCarryTheAPIKeyHeader() async throws {
        StubURLProtocol.handler = { _ in .json(#"{"voices":[]}"#) }
        _ = try await api.listVoices()
        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.value(forHTTPHeaderField: "xi-api-key"), "test-key")
    }

    func testMissingKeyFailsBeforeAnyNetworkCall() async {
        let keyless = ElevenLabsAPI(session: StubURLProtocol.session()) { nil }
        StubURLProtocol.handler = { _ in .json(#"{"voices":[]}"#) }
        do {
            _ = try await keyless.listVoices()
            XCTFail("expected missingAPIKey")
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // The point of failing early: nothing was sent.
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testEmptyKeyIsTreatedAsMissing() async {
        let keyless = ElevenLabsAPI(session: StubURLProtocol.session()) { "" }
        do {
            _ = try await keyless.listVoices()
            XCTFail("expected missingAPIKey")
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, .missingAPIKey)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Voices

    func testDecodesVoices() async throws {
        StubURLProtocol.handler = { _ in
            .json(#"""
            {"voices":[
              {"voice_id":"v1","name":"Rachel","category":"premade",
               "labels":{"accent":"american","description":"calm"}},
              {"voice_id":"v2","name":"Mine","category":"cloned","labels":{}}
            ]}
            """#)
        }
        let voices = try await api.listVoices()
        XCTAssertEqual(voices.count, 2)
        XCTAssertEqual(voices[0].voiceID, "v1")
        XCTAssertEqual(voices[0].displayName, "Rachel (american, calm)")
        XCTAssertEqual(voices[0].accent, "american")
        XCTAssertFalse(voices[0].isCloned)
        XCTAssertTrue(voices[1].isCloned)
        XCTAssertEqual(voices[1].displayName, "Mine")
    }

    func testUnknownFieldsDoNotBreakDecoding() async throws {
        // The catalogue gains fields regularly. A strict decoder would turn an
        // upstream addition into "no voices found" for the user.
        StubURLProtocol.handler = { _ in
            .json(#"""
            {"voices":[{"voice_id":"v1","name":"Rachel","brand_new_field":{"nested":true},
                        "sharing":null,"labels":{"accent":"british"}}]}
            """#)
        }
        let voices = try await api.listVoices()
        XCTAssertEqual(voices.first?.accent, "british")
    }

    func testNullLabelValuesAreDropped() async throws {
        StubURLProtocol.handler = { _ in
            .json(#"{"voices":[{"voice_id":"v1","name":"X","labels":{"accent":null,"age":"young"}}]}"#)
        }
        let voices = try await api.listVoices()
        let voice = try XCTUnwrap(voices.first)
        XCTAssertEqual(voice.labels["age"], "young")
        XCTAssertNil(voice.labels["accent"])
        XCTAssertEqual(voice.accent, "multilingual")
    }

    func testVoiceWithoutNameStillDecodes() async throws {
        StubURLProtocol.handler = { _ in .json(#"{"voices":[{"voice_id":"v1"}]}"#) }
        let voices = try await api.listVoices()
        let voice = try XCTUnwrap(voices.first)
        XCTAssertEqual(voice.name, "Unnamed")
    }

    // MARK: - Synthesis

    func testSynthesisPostsCorrectRequest() async throws {
        StubURLProtocol.handler = { _ in .audio(2048) }
        let data = try await api.synthesize(text: "Hello there.", voiceID: "v1")
        XCTAssertEqual(data.count, 2048)

        let request = try XCTUnwrap(StubURLProtocol.recorded.first)
        XCTAssertEqual(request.httpMethod, "POST")
        let url = try XCTUnwrap(request.url?.absoluteString)
        XCTAssertTrue(url.contains("/v1/text-to-speech/v1/stream"), url)
        XCTAssertTrue(url.contains("optimize_streaming_latency=3"), url)
        XCTAssertTrue(url.contains("output_format=mp3_44100_128"), url)

        let body = try XCTUnwrap(request.httpBody)
        let json = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: body) as? [String: Any]
        )
        XCTAssertEqual(json["text"] as? String, "Hello there.")
        XCTAssertEqual(json["model_id"] as? String, "eleven_turbo_v2_5")
        let settings = try XCTUnwrap(json["voice_settings"] as? [String: Any])
        XCTAssertEqual(settings["stability"] as? Double, 0.5)
        XCTAssertEqual(settings["similarity_boost"] as? Double, 0.75)
    }

    func testSynthesisTrimsWhitespace() async throws {
        StubURLProtocol.handler = { _ in .audio(16) }
        _ = try await api.synthesize(text: "  padded  ", voiceID: "v1")
        let body = try XCTUnwrap(StubURLProtocol.recorded.first?.httpBody)
        let json = try XCTUnwrap(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        XCTAssertEqual(json["text"] as? String, "padded")
    }

    func testBlankTextFailsWithoutCallingTheAPI() async {
        StubURLProtocol.handler = { _ in .audio(1024) }
        do {
            _ = try await api.synthesize(text: "   \n  ", voiceID: "v1")
            XCTFail("expected emptyAudio")
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, .emptyAudio)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
        // Whitespace must never be billed.
        XCTAssertTrue(StubURLProtocol.recorded.isEmpty)
    }

    func testEmptyBodyIsAnError() async {
        StubURLProtocol.handler = { _ in .audio(0) }
        do {
            _ = try await api.synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected emptyAudio")
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, .emptyAudio)
        } catch {
            XCTFail("unexpected error: \(error)")
        }
    }

    // MARK: - Error mapping

    func testUnauthorizedIsMapped() async {
        StubURLProtocol.handler = { _ in .json(#"{"detail":"invalid key"}"#, status: 401) }
        await assertError(.unauthorized)
    }

    func testForbiddenIsAlsoUnauthorized() async {
        StubURLProtocol.handler = { _ in .json(#"{"detail":"nope"}"#, status: 403) }
        await assertError(.unauthorized)
    }

    func testRateLimitCarriesRetryAfter() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Stub(status: 429, body: Data(), headers: ["Retry-After": "12"])
        }
        await assertError(.rateLimited(retryAfter: 12))
    }

    func testQuotaExceededIsItsOwnCase() async {
        // The failure people actually hit. It arrives as a 422 whose detail
        // mentions quota, and it deserves better than "422".
        StubURLProtocol.handler = { _ in
            .json(#"{"detail":{"status":"quota_exceeded","message":"character quota exceeded"}}"#,
                  status: 422)
        }
        await assertError(.quotaExceeded)
    }

    func testServerErrorKeepsStatusAndMessage() async {
        StubURLProtocol.handler = { _ in .json(#"{"detail":"boom"}"#, status: 503) }
        await assertError(.http(status: 503, message: "boom"))
    }

    func testNestedDetailObjectIsUnwrapped() async {
        StubURLProtocol.handler = { _ in
            .json(#"{"detail":{"message":"voice not found","status":"voice_not_found"}}"#, status: 404)
        }
        await assertError(.http(status: 404, message: "voice not found"))
    }

    func testUnparseableErrorBodyStillProducesAnError() async {
        StubURLProtocol.handler = { _ in
            StubURLProtocol.Stub(status: 500, body: Data("<html>oops</html>".utf8))
        }
        await assertError(.http(status: 500, message: "unknown error"))
    }

    // MARK: - Retry classification

    func testRetryClassification() {
        // A bad key will not fix itself. Retrying it once per sentence would
        // burn the user's time and produce silence with no explanation.
        XCTAssertFalse(ElevenLabsAPI.APIError.unauthorized.isRetryable)
        XCTAssertFalse(ElevenLabsAPI.APIError.quotaExceeded.isRetryable)
        XCTAssertFalse(ElevenLabsAPI.APIError.missingAPIKey.isRetryable)
        XCTAssertFalse(ElevenLabsAPI.APIError.http(status: 404, message: "").isRetryable)

        XCTAssertTrue(ElevenLabsAPI.APIError.rateLimited(retryAfter: nil).isRetryable)
        XCTAssertTrue(ElevenLabsAPI.APIError.emptyAudio.isRetryable)
        XCTAssertTrue(ElevenLabsAPI.APIError.http(status: 502, message: "").isRetryable)
    }

    // MARK: - Subscription

    func testSubscriptionSummary() async throws {
        StubURLProtocol.handler = { _ in
            .json(#"{"tier":"creator","character_count":21000,"character_limit":100000}"#)
        }
        let sub = try await api.subscription()
        XCTAssertEqual(sub.charactersRemaining, 79000)
        XCTAssertEqual(sub.fractionUsed, 0.21, accuracy: 0.001)
        XCTAssertTrue(sub.summary.contains("creator"))
        // Locale-agnostic on purpose. The summary is a UI string and uses the
        // user's regional format, so this machine renders 79000 as "79.000"
        // under German regional settings while CI in en_US renders "79,000".
        // Asserting on one of those spellings would make the suite pass or fail
        // depending on where it runs.
        let digits = sub.summary.filter(\.isNumber)
        XCTAssertTrue(digits.contains("79000"), sub.summary)
        XCTAssertTrue(digits.contains("100000"), sub.summary)
    }

    func testSubscriptionHandlesMissingFields() throws {
        let sub = try JSONDecoder().decode(
            ElevenLabsSubscription.self, from: Data(#"{}"#.utf8)
        )
        XCTAssertEqual(sub.characterCount, 0)
        XCTAssertEqual(sub.characterLimit, 0)
        XCTAssertEqual(sub.fractionUsed, 0)
    }

    func testValidateKeyReturnsFailureRatherThanThrowing() async {
        StubURLProtocol.handler = { _ in .json(#"{"detail":"bad"}"#, status: 401) }
        let result = await api.validateKey()
        switch result {
        case .success: XCTFail("expected failure")
        case .failure(let error): XCTAssertEqual(error, .unauthorized)
        }
    }

    // MARK: - Helper

    private func assertError(
        _ expected: ElevenLabsAPI.APIError,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        do {
            _ = try await api.synthesize(text: "Hello.", voiceID: "v1")
            XCTFail("expected \(expected)", file: file, line: line)
        } catch let error as ElevenLabsAPI.APIError {
            XCTAssertEqual(error, expected, file: file, line: line)
        } catch {
            XCTFail("unexpected error: \(error)", file: file, line: line)
        }
    }
}
