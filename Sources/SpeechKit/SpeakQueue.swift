import Foundation

/// Reads waiting behind the one currently playing.
///
/// Small enough to look obviously correct and it still had a bug: stopping did
/// not clear the queue, so pressing stop finished the current read and then
/// started the next queued one. With three queued you had to press stop four
/// times. Extracted here because AGENTS.md is right that every defect in this
/// project has been in state transitions rather than audio code, and a state
/// machine living in the `@main` target cannot be tested.
public struct SpeakQueue<Item> {

    public enum Decision: Equatable {
        /// Play this immediately.
        case start
        /// Something is already playing; this waits its turn.
        case queued
    }

    private var pending: [Item] = []

    public init() {}

    /// Reads waiting. Surfaced so the UI can show that an enqueued response is
    /// pending rather than lost.
    public var depth: Int { pending.count }

    public var isEmpty: Bool { pending.isEmpty }

    /// Offer a read.
    ///
    /// - Parameters:
    ///   - replacesExisting: true for actions that abandon whatever is queued
    ///     (replace, interrupt), false to append.
    ///   - isBusy: whether a read is currently playing or paused. Enqueueing
    ///     against an idle engine starts immediately, otherwise nothing would
    ///     ever kick the queue into motion.
    public mutating func submit(_ item: Item, replacesExisting: Bool, isBusy: Bool) -> Decision {
        if replacesExisting {
            pending.removeAll()
            return .start
        }
        guard isBusy else { return .start }
        pending.append(item)
        return .queued
    }

    /// The current read ended on its own. Returns what to play next.
    public mutating func advance() -> Item? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// The user stopped playback. Everything waiting is abandoned.
    ///
    /// Distinct from `advance`, and the distinction is the whole point: a read
    /// ending by itself should hand over to the next one, while a read ending
    /// because someone pressed stop should not.
    public mutating func cancelAll() {
        pending.removeAll()
    }
}
