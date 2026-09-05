import Foundation
import SpeechKit

/// Bookkeeping for one read: which sentences have audio, which have failed, and
/// where playback is.
///
/// Extracted from the provider because every bug found in review so far has
/// been in these transitions rather than in the audio code, and the provider
/// lives in the `@main` executable where it cannot be unit tested.
///
/// The provider holds the temp-file URLs; this holds the decisions. The two are
/// kept in step by routing every mutation through `cache` and `discard`.
public struct ReadState: Equatable {

    public let total: Int
    /// Last index that started playing. -1 before playback begins.
    public private(set) var currentIndex: Int
    /// Indices with audio available.
    public private(set) var ready: Set<Int>
    /// Indices that will never play: synthesis gave up, or the file was
    /// rejected by the player.
    public private(set) var failed: Set<Int>
    /// True once the read has run to its natural end.
    public private(set) var isComplete: Bool

    public init(total: Int) {
        self.total = max(0, total)
        self.currentIndex = -1
        self.ready = []
        self.failed = []
        self.isComplete = false
    }

    // MARK: - Transitions

    /// Audio arrived and is on disk.
    public mutating func cache(_ index: Int) {
        guard index >= 0, index < total else { return }
        // Arriving audio clears a previous failure: a retry that eventually
        // succeeded should play, not stay skipped.
        failed.remove(index)
        ready.insert(index)
    }

    /// Synthesis gave up on this sentence after its retries.
    public mutating func markSynthesisFailed(_ index: Int) {
        guard index >= 0, index < total else { return }
        ready.remove(index)
        failed.insert(index)
    }

    /// The player refused the cached file.
    ///
    /// This is the transition that was missing. Previously a rejected file was
    /// left in the cache and playback simply advanced, so the queue selected
    /// the same index again and the provider span. Dropping it from `ready` and
    /// recording the failure is what makes the loop impossible.
    public mutating func markPlaybackFailed(_ index: Int) {
        guard index >= 0, index < total else { return }
        ready.remove(index)
        failed.insert(index)
    }

    public mutating func beganPlaying(_ index: Int) {
        guard index >= 0, index < total else { return }
        currentIndex = index
    }

    /// Move the playhead for a seek. Failures at or after the target are
    /// cleared so the generator gets another go at them.
    public mutating func seek(to index: Int) {
        let target = max(0, min(index, max(0, total - 1)))
        currentIndex = target - 1
        failed = failed.filter { $0 < target }
        isComplete = false
    }

    /// The read reached its natural end. Cached audio is released.
    ///
    /// Deliberate: `seek` is refused once a read is no longer speaking, so
    /// holding temp files past completion buys nothing and leaves disk behind
    /// until the next `speak` or `stop`. Replaying a finished read starts a new
    /// one, which re-synthesizes, and that is the honest cost.
    public mutating func complete() {
        isComplete = true
        ready.removeAll()
    }

    // MARK: - Queries

    /// What to play next, stepping over failures.
    public func next() -> SentenceQueue.Next {
        SentenceQueue.next(after: currentIndex, ready: ready, failed: failed, total: total)
    }

    /// Whether this index still needs to be bought.
    ///
    /// False for anything cached, which is what stops a resume from
    /// re-synthesizing audio already paid for.
    public func needsSynthesis(_ index: Int) -> Bool {
        guard index >= 0, index < total else { return false }
        return !ready.contains(index) && !failed.contains(index)
    }

    /// Whether synthesis of this index may start yet, given the spend cap.
    public func isWithinLookahead(_ index: Int, lookahead: Int) -> Bool {
        index <= currentIndex + lookahead
    }
}
