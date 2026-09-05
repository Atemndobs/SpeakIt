import XCTest
@testable import ElevenLabsKit

final class PlaybackRateTests: XCTestCase {

    /// The one that matters. AVSpeechUtteranceDefaultSpeechRate is 0.5, and
    /// almost everyone leaves the slider there. If this drifts, every default
    /// ElevenLabs read plays at the wrong speed.
    func testSliderMidpointIsExactlyNormalSpeed() {
        XCTAssertEqual(PlaybackRate.multiplier(fromSlider: 0.5), 1.0, accuracy: 0.0001)
    }

    func testEndsOfTheSlider() {
        XCTAssertEqual(PlaybackRate.multiplier(fromSlider: 0.0), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PlaybackRate.multiplier(fromSlider: 1.0), 2.0, accuracy: 0.0001)
    }

    func testOutOfRangeInputIsClamped() {
        XCTAssertEqual(PlaybackRate.multiplier(fromSlider: -5), 0.5, accuracy: 0.0001)
        XCTAssertEqual(PlaybackRate.multiplier(fromSlider: 99), 2.0, accuracy: 0.0001)
    }

    func testNeverLeavesTheSafeRange() {
        // Outside 0.5...2.0 AVAudioPlayer's time-pitch unit produces audible
        // artefacts, so no slider position may escape it.
        for i in 0...100 {
            let rate = PlaybackRate.multiplier(fromSlider: Float(i) / 100)
            XCTAssertGreaterThanOrEqual(rate, PlaybackRate.minimum)
            XCTAssertLessThanOrEqual(rate, PlaybackRate.maximum)
        }
    }

    func testIsMonotonic() {
        var previous = PlaybackRate.multiplier(fromSlider: 0)
        for i in 1...100 {
            let rate = PlaybackRate.multiplier(fromSlider: Float(i) / 100)
            XCTAssertGreaterThanOrEqual(rate, previous, "slider went backwards at \(i)")
            previous = rate
        }
    }
}
