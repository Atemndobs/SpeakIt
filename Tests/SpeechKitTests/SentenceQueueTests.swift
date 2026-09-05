import XCTest
@testable import SpeechKit

final class SentenceQueueTests: XCTestCase {

    func testPlaysTheNextReadySentence() {
        XCTAssertEqual(
            SentenceQueue.next(after: -1, ready: [0, 1], failed: [], total: 5),
            .play(0)
        )
        XCTAssertEqual(
            SentenceQueue.next(after: 0, ready: [0, 1], failed: [], total: 5),
            .play(1)
        )
    }

    func testWaitsWhenTheNextSentenceIsStillInFlight() {
        // Sentence 3 is ready but 1 is not. Playing 3 would reorder the
        // article, so the queue waits.
        XCTAssertEqual(
            SentenceQueue.next(after: 0, ready: [0, 3], failed: [], total: 5),
            .waiting
        )
    }

    /// The bug this type exists to prevent.
    ///
    /// One transient 500 on sentence 1 used to stall the read permanently:
    /// playback sat at sentence 0 forever while 2, 3 and 4 were synthesized and
    /// billed but never played.
    func testStepsOverAFailedSentenceInsteadOfStalling() {
        XCTAssertEqual(
            SentenceQueue.next(after: 0, ready: [0, 2], failed: [1], total: 5),
            .play(2)
        )
    }

    func testStepsOverSeveralConsecutiveFailures() {
        XCTAssertEqual(
            SentenceQueue.next(after: 0, ready: [4], failed: [1, 2, 3], total: 5),
            .play(4)
        )
    }

    func testWaitsWhenAFailureIsFollowedByAnInFlightSentence() {
        XCTAssertEqual(
            SentenceQueue.next(after: 0, ready: [], failed: [1], total: 5),
            .waiting
        )
    }

    func testFinishedAtTheEnd() {
        XCTAssertEqual(
            SentenceQueue.next(after: 4, ready: [], failed: [], total: 5),
            .finished
        )
    }

    func testFinishedWhenEveryRemainingSentenceFailed() {
        // Everything left is dead, so the player must report the read as over
        // rather than waiting for audio that will never arrive.
        XCTAssertEqual(
            SentenceQueue.next(after: 1, ready: [], failed: [2, 3, 4], total: 5),
            .finished
        )
        XCTAssertTrue(
            SentenceQueue.isExhausted(after: 1, ready: [], failed: [2, 3, 4], total: 5)
        )
    }

    func testNotExhaustedWhileSomethingIsStillComing() {
        XCTAssertFalse(
            SentenceQueue.isExhausted(after: 1, ready: [], failed: [2], total: 5)
        )
    }

    func testEmptyTextIsFinished() {
        XCTAssertEqual(
            SentenceQueue.next(after: -1, ready: [], failed: [], total: 0),
            .finished
        )
    }

    func testEveryFailureStillTerminates() {
        // A total network outage must end the read, not spin.
        let all = Set(0..<20)
        XCTAssertEqual(
            SentenceQueue.next(after: -1, ready: [], failed: all, total: 20),
            .finished
        )
    }

    func testWalkingAWholeArticleWithGapsTerminates() {
        // Property-ish check: whatever the mix of ready and failed, stepping
        // through with the queue must reach .finished and never revisit an
        // index.
        let total = 40
        let failed: Set<Int> = [3, 4, 11, 25, 39]
        let ready = Set(0..<total).subtracting(failed)

        var current = -1
        var played: [Int] = []
        while case .play(let idx) = SentenceQueue.next(
            after: current, ready: ready, failed: failed, total: total
        ) {
            XCTAssertGreaterThan(idx, current, "queue went backwards")
            played.append(idx)
            current = idx
            if played.count > total { XCTFail("did not terminate"); return }
        }
        XCTAssertEqual(played.count, total - failed.count)
        XCTAssertEqual(Set(played), ready)
    }
}
