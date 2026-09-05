import XCTest
@testable import SpeechKit

final class KokoroProtocolTests: XCTestCase {

    // MARK: Parsing

    func testReadyEvent() {
        let message = KokoroProtocol.parse(line: #"{"event":"ready","sample_rate":24000,"voices":["af_heart","bm_george"]}"#)
        XCTAssertEqual(message, .ready(voices: ["af_heart", "bm_george"]))
    }

    func testSuccessReply() {
        let message = KokoroProtocol.parse(line: #"{"id":7,"ok":true,"out":"/tmp/a.wav","seconds":2.31,"synth_ms":402}"#)
        XCTAssertEqual(message, .finished(id: 7, path: "/tmp/a.wav", seconds: 2.31))
    }

    func testFailureReplyCarriesTheError() {
        let message = KokoroProtocol.parse(line: #"{"id":3,"ok":false,"error":"bad voice"}"#)
        XCTAssertEqual(message, .failed(id: 3, error: "bad voice", cancelled: false))
    }

    func testCancellationIsDistinguishedFromFailure() {
        // A cancelled sentence is the expected result of a seek. Logging it as
        // a failure would fill the log with noise every time someone scrubs.
        let message = KokoroProtocol.parse(line: #"{"id":9,"ok":false,"cancelled":true}"#)
        XCTAssertEqual(message, .failed(id: 9, error: nil, cancelled: true))
    }

    func testFatalStartupError() {
        let message = KokoroProtocol.parse(line: #"{"event":"error","error":"import failed"}"#)
        XCTAssertEqual(message, .fatal("import failed"))
    }

    func testNoiseOnStdoutIsIgnoredNotFatal() {
        // onnxruntime and phonemizer are not disciplined about stdout. One
        // stray line must not abort a read that is otherwise working.
        XCTAssertNil(KokoroProtocol.parse(line: ""))
        XCTAssertNil(KokoroProtocol.parse(line: "   "))
        XCTAssertNil(KokoroProtocol.parse(line: "onnxruntime: using CoreML"))
        XCTAssertNil(KokoroProtocol.parse(line: "{not json"))
        XCTAssertNil(KokoroProtocol.parse(line: "[1,2,3]"))
        XCTAssertNil(KokoroProtocol.parse(line: #"{"event":"something-new"}"#))
    }

    func testRepliesWithoutAnIdAreIgnored() {
        // Without an id there is no sentence to attribute the result to.
        XCTAssertNil(KokoroProtocol.parse(line: #"{"ok":true,"out":"/tmp/a.wav"}"#))
    }

    func testSuccessWithoutAPathIsNotUsable() {
        XCTAssertNil(KokoroProtocol.parse(line: #"{"id":1,"ok":true}"#))
    }

    func testMissingDurationDoesNotDropTheAudio() {
        // The wav is on disk and playable; a missing duration is not a reason
        // to throw the sentence away.
        XCTAssertEqual(
            KokoroProtocol.parse(line: #"{"id":1,"ok":true,"out":"/tmp/a.wav"}"#),
            .finished(id: 1, path: "/tmp/a.wav", seconds: 0)
        )
    }

    func testWhitespaceAroundALineIsTolerated() {
        XCTAssertEqual(
            KokoroProtocol.parse(line: "  {\"id\":2,\"ok\":true,\"out\":\"/tmp/b.wav\",\"seconds\":1}\r\n"),
            .finished(id: 2, path: "/tmp/b.wav", seconds: 1)
        )
    }

    // MARK: Encoding

    func testRequestEncodesAsASingleNewlineTerminatedLine() throws {
        let request = KokoroProtocol.Request(
            id: 4, text: "Hello.", voice: "af_heart", speed: 1.0, lang: "en-us", out: "/tmp/x.wav"
        )
        let line = try XCTUnwrap(KokoroProtocol.line(request))

        XCTAssertTrue(line.hasSuffix("\n"))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1,
                       "an embedded newline would desynchronize the protocol")

        let decoded = try JSONDecoder().decode(
            KokoroProtocol.Request.self, from: Data(line.utf8)
        )
        XCTAssertEqual(decoded, request)
    }

    func testTextWithNewlinesStaysOnOneLine() throws {
        // Sentence splitting can hand over text containing a line break. JSON
        // escapes it; this guards against a hand-rolled encoder that would not.
        let request = KokoroProtocol.Request(
            id: 1, text: "One.\nTwo.", voice: "af_heart", speed: 1, lang: "en-us", out: "/tmp/x.wav"
        )
        let line = try XCTUnwrap(KokoroProtocol.line(request))
        XCTAssertEqual(line.filter { $0 == "\n" }.count, 1)
    }

    func testCancelUsesTheSnakeCaseKeyTheDaemonReads() throws {
        let line = try XCTUnwrap(KokoroProtocol.line(KokoroProtocol.Cancel(cancelBefore: 12)))
        XCTAssertTrue(line.contains("cancel_before"),
                      "the daemon looks for cancel_before; camelCase would be silently ignored")
    }

    // MARK: Speed

    func testSliderMidpointIsExactlyNormalSpeed() {
        // The value almost everyone leaves alone. Off by a little here is a
        // bug nobody would think to report.
        XCTAssertEqual(KokoroSpeed.multiplier(for: 0.5), 1.0)
    }

    func testSpeedSpansTheUsefulRange() {
        XCTAssertEqual(KokoroSpeed.multiplier(for: 0.0), KokoroSpeed.minimum)
        XCTAssertEqual(KokoroSpeed.multiplier(for: 1.0), KokoroSpeed.maximum)
    }

    func testSpeedIsMonotonic() {
        var previous = 0.0
        for step in 0...100 {
            let value = KokoroSpeed.multiplier(for: Float(step) / 100)
            XCTAssertGreaterThanOrEqual(value, previous)
            previous = value
        }
    }

    func testSpeedClampsOutOfRangeInput() {
        XCTAssertEqual(KokoroSpeed.multiplier(for: -3), KokoroSpeed.minimum)
        XCTAssertEqual(KokoroSpeed.multiplier(for: 99), KokoroSpeed.maximum)
    }
}
