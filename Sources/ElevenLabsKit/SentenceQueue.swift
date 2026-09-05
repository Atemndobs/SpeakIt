import Foundation

/// Decides what to play next when sentences are synthesized out of order and
/// some of them fail.
///
/// Extracted as a pure type because the alternative is a bug that is invisible
/// until it happens to a user mid-article. The queue is filled by a network
/// call per sentence, so at any moment an index is in one of three states:
/// ready, permanently failed, or still in flight. "Play the next one" is not
/// `currentIndex + 1`, and treating it that way means a single transient 500
/// stalls playback forever while the remaining sentences are still synthesized
/// and billed.
///
/// Living in the kit rather than the provider makes it testable: the provider
/// is in the `@main` executable target.
public enum SentenceQueue {

    public enum Next: Equatable {
        /// Play this index now.
        case play(Int)
        /// The next sentence has not arrived yet. Wait for the generator.
        case waiting
        /// Nothing playable remains.
        case finished
    }

    /// - Parameters:
    ///   - currentIndex: last index played, or -1 before playback starts.
    ///   - ready: indices with audio on disk.
    ///   - failed: indices that will never produce audio.
    ///   - total: number of sentences.
    ///
    /// Scans forward from `currentIndex`, stepping over failures. Stops at the
    /// first index that is neither ready nor failed, because playing past a
    /// sentence still in flight would reorder the article.
    public static func next(
        after currentIndex: Int,
        ready: Set<Int>,
        failed: Set<Int>,
        total: Int
    ) -> Next {
        guard total > 0 else { return .finished }
        var idx = currentIndex + 1
        while idx < total {
            if ready.contains(idx) { return .play(idx) }
            if failed.contains(idx) { idx += 1; continue }
            return .waiting
        }
        return .finished
    }

    /// Whether every remaining sentence has failed, so waiting is pointless.
    ///
    /// Distinct from `next` returning `.finished`: this answers "should the
    /// player report the read as over" when the generator has stopped
    /// producing, without depending on the generator's own state.
    public static func isExhausted(
        after currentIndex: Int,
        ready: Set<Int>,
        failed: Set<Int>,
        total: Int
    ) -> Bool {
        next(after: currentIndex, ready: ready, failed: failed, total: total) == .finished
    }
}
