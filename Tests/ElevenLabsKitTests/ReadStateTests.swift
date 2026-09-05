import XCTest
@testable import ElevenLabsKit

/// Regression tests for the transitions that review kept finding bugs in.
final class ReadStateTests: XCTestCase {

    // MARK: - Player rejects a cached file

    /// The loop. A file that `AVAudioPlayer` refuses used to stay in the cache,
    /// so the queue selected the same index on the next tick, forever.
    func testPlaybackFailureDoesNotSelectTheSameIndexAgain() {
        var state = ReadState(total: 4)
        state.cache(0); state.cache(1); state.cache(2); state.cache(3)

        XCTAssertEqual(state.next(), .play(0))
        state.beganPlaying(0)

        // Player refuses sentence 1.
        XCTAssertEqual(state.next(), .play(1))
        state.markPlaybackFailed(1)

        XCTAssertEqual(state.next(), .play(2), "must step past the rejected file")
        XCTAssertFalse(state.ready.contains(1))
        XCTAssertTrue(state.failed.contains(1))
    }

    func testRepeatedPlaybackFailuresStillTerminate() {
        var state = ReadState(total: 3)
        state.cache(0); state.cache(1); state.cache(2)
        var guardCount = 0
        while case .play(let idx) = state.next() {
            state.markPlaybackFailed(idx)
            guardCount += 1
            XCTAssertLessThan(guardCount, 10, "spun instead of terminating")
        }
        XCTAssertEqual(state.next(), .finished)
    }

    // MARK: - Resume must not re-buy

    func testCachedSentencesAreNotResynthesized() {
        var state = ReadState(total: 5)
        state.cache(0); state.cache(1); state.cache(2)
        XCTAssertFalse(state.needsSynthesis(0))
        XCTAssertFalse(state.needsSynthesis(2))
        XCTAssertTrue(state.needsSynthesis(3), "not yet bought")
    }

    func testFailedSentencesAreNotRetriedByTheGeneratorLoop() {
        // Retry happens inside one synthesis attempt. Once the state records a
        // failure, the generator pass must not buy it again on a later sweep.
        var state = ReadState(total: 3)
        state.markSynthesisFailed(1)
        XCTAssertFalse(state.needsSynthesis(1))
    }

    func testLateArrivingAudioClearsAnEarlierFailure() {
        // A retry that eventually succeeds must play, not stay skipped.
        var state = ReadState(total: 3)
        state.cache(0)
        state.beganPlaying(0)
        state.markSynthesisFailed(1)
        XCTAssertEqual(state.next(), .waiting, "index 2 is still in flight")

        state.cache(1)

        XCTAssertTrue(state.ready.contains(1))
        XCTAssertFalse(state.failed.contains(1))
        XCTAssertEqual(state.next(), .play(1))
    }

    // MARK: - Spend cap

    func testLookaheadCapsHowFarAheadSynthesisRuns() {
        var state = ReadState(total: 100)
        state.beganPlaying(10)
        XCTAssertTrue(state.isWithinLookahead(13, lookahead: 3))
        XCTAssertFalse(state.isWithinLookahead(14, lookahead: 3),
                       "spending past the cap is what bills a skipped article in full")
    }

    func testLookaheadBeforePlaybackStartsAllowsThePrefix() {
        let state = ReadState(total: 100)   // currentIndex == -1
        XCTAssertTrue(state.isWithinLookahead(0, lookahead: 3))
        XCTAssertTrue(state.isWithinLookahead(2, lookahead: 3))
        XCTAssertFalse(state.isWithinLookahead(3, lookahead: 3))
    }

    // MARK: - Seeking

    func testBackwardSeekKeepsAudioAlreadyPaidFor() {
        var state = ReadState(total: 6)
        for i in 0..<5 { state.cache(i) }
        state.beganPlaying(4)

        state.seek(to: 1)

        XCTAssertTrue(state.ready.contains(1), "seeking back must not discard bought audio")
        XCTAssertTrue(state.ready.contains(2))
        XCTAssertEqual(state.next(), .play(1))
        XCTAssertFalse(state.needsSynthesis(1), "must not re-buy on a backward seek")
    }

    func testSeekClearsFailuresAtOrAfterTheTargetOnly() {
        var state = ReadState(total: 6)
        state.markSynthesisFailed(0)
        state.markSynthesisFailed(4)
        state.beganPlaying(5)

        state.seek(to: 3)

        XCTAssertTrue(state.failed.contains(0), "failures behind the target stay")
        XCTAssertFalse(state.failed.contains(4), "failures ahead get another chance")
        XCTAssertTrue(state.needsSynthesis(4))
    }

    func testSeekClampsToBounds() {
        var state = ReadState(total: 3)
        state.seek(to: 99)
        XCTAssertEqual(state.currentIndex, 1)
        state.seek(to: -5)
        XCTAssertEqual(state.currentIndex, -1)
    }

    // MARK: - Completion

    func testCompletionReleasesTheCache() {
        var state = ReadState(total: 3)
        state.cache(0); state.cache(1); state.cache(2)
        state.beganPlaying(2)

        state.complete()

        XCTAssertTrue(state.isComplete)
        XCTAssertTrue(state.ready.isEmpty, "temp files must not survive the read")
        XCTAssertEqual(state.next(), .finished)
    }

    func testSeekingAfterCompletionReopensTheRead() {
        // Documents the chosen behaviour: a finished read holds nothing, so
        // replaying it starts over and re-synthesizes. That is the honest cost
        // of releasing the cache at the end.
        var state = ReadState(total: 3)
        state.cache(0); state.cache(1); state.cache(2)
        state.complete()

        state.seek(to: 0)

        XCTAssertFalse(state.isComplete)
        XCTAssertTrue(state.needsSynthesis(0), "cache was released, so this is bought again")
    }

    // MARK: - Bounds

    func testOutOfRangeIndicesAreIgnored() {
        var state = ReadState(total: 2)
        state.cache(-1); state.cache(5)
        state.markSynthesisFailed(9)
        XCTAssertTrue(state.ready.isEmpty)
        XCTAssertTrue(state.failed.isEmpty)
    }

    func testEmptyReadIsImmediatelyFinished() {
        XCTAssertEqual(ReadState(total: 0).next(), .finished)
    }
}
