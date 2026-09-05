import XCTest
@testable import SpeechKit

final class SpeakQueueTests: XCTestCase {

    private func makeQueue() -> SpeakQueue<String> { SpeakQueue<String>() }

    // MARK: The bug this type exists for

    func testStoppingAbandonsTheQueue() {
        // Found by testing the branch: stop() left pendingRequests intact, so
        // the provider going idle immediately started the next queued read.
        // With three queued you had to press stop four times.
        var queue = makeQueue()
        _ = queue.submit("playing", replacesExisting: true, isBusy: false)
        _ = queue.submit("second", replacesExisting: false, isBusy: true)
        _ = queue.submit("third", replacesExisting: false, isBusy: true)
        XCTAssertEqual(queue.depth, 2)

        queue.cancelAll()

        XCTAssertEqual(queue.depth, 0)
        XCTAssertNil(queue.advance(), "nothing may start after a stop")
    }

    func testFinishingNaturallyStillHandsOver() {
        // The counterpart, and the reason cancelAll and advance are separate:
        // a read ending by itself must start the next one.
        var queue = makeQueue()
        _ = queue.submit("first", replacesExisting: true, isBusy: false)
        _ = queue.submit("second", replacesExisting: false, isBusy: true)

        XCTAssertEqual(queue.advance(), "second")
        XCTAssertNil(queue.advance())
    }

    // MARK: submit

    func testEnqueueAgainstAnIdleEngineStartsImmediately() {
        // Otherwise nothing would ever kick the queue into motion: every read
        // would wait for a read that is not happening.
        var queue = makeQueue()
        XCTAssertEqual(queue.submit("x", replacesExisting: false, isBusy: false), .start)
        XCTAssertEqual(queue.depth, 0)
    }

    func testEnqueueWhileBusyWaits() {
        var queue = makeQueue()
        XCTAssertEqual(queue.submit("x", replacesExisting: false, isBusy: true), .queued)
        XCTAssertEqual(queue.depth, 1)
    }

    func testReplaceDiscardsWhatWasWaiting() {
        var queue = makeQueue()
        _ = queue.submit("a", replacesExisting: false, isBusy: true)
        _ = queue.submit("b", replacesExisting: false, isBusy: true)
        XCTAssertEqual(queue.depth, 2)

        XCTAssertEqual(queue.submit("urgent", replacesExisting: true, isBusy: true), .start)
        XCTAssertEqual(queue.depth, 0, "a replace must not leave stale reads behind it")
        XCTAssertNil(queue.advance())
    }

    func testReplaceStartsEvenWhenIdle() {
        var queue = makeQueue()
        XCTAssertEqual(queue.submit("x", replacesExisting: true, isBusy: false), .start)
    }

    // MARK: ordering

    func testQueueIsFirstInFirstOut() {
        var queue = makeQueue()
        _ = queue.submit("playing", replacesExisting: true, isBusy: false)
        for item in ["one", "two", "three"] {
            _ = queue.submit(item, replacesExisting: false, isBusy: true)
        }
        XCTAssertEqual(queue.advance(), "one")
        XCTAssertEqual(queue.advance(), "two")
        XCTAssertEqual(queue.advance(), "three")
        XCTAssertNil(queue.advance())
    }

    func testDepthTracksWhatIsWaiting() {
        var queue = makeQueue()
        XCTAssertTrue(queue.isEmpty)
        _ = queue.submit("a", replacesExisting: false, isBusy: true)
        _ = queue.submit("b", replacesExisting: false, isBusy: true)
        XCTAssertEqual(queue.depth, 2)
        _ = queue.advance()
        XCTAssertEqual(queue.depth, 1)
        _ = queue.advance()
        XCTAssertTrue(queue.isEmpty)
    }

    // MARK: full sequences

    func testThreeEnqueuedReadsPlayInOrder() {
        // The behaviour the branch advertises, walked end to end.
        var queue = makeQueue()
        var played: [String] = []

        for item in ["first", "second", "third"] {
            let busy = !played.isEmpty
            if queue.submit(item, replacesExisting: false, isBusy: busy) == .start {
                played.append(item)
            }
        }
        while let next = queue.advance() { played.append(next) }

        XCTAssertEqual(played, ["first", "second", "third"])
    }

    func testStopMidQueueLeavesNothingBehind() {
        var queue = makeQueue()
        _ = queue.submit("playing", replacesExisting: true, isBusy: false)
        _ = queue.submit("waiting", replacesExisting: false, isBusy: true)

        queue.cancelAll()

        // A later read still works; stop clears, it does not disable.
        XCTAssertEqual(queue.submit("fresh", replacesExisting: false, isBusy: false), .start)
    }

    func testAdvanceOnAnEmptyQueueIsHarmless() {
        var queue = makeQueue()
        XCTAssertNil(queue.advance())
        XCTAssertNil(queue.advance())
    }
}
