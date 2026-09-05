import Foundation

/// How many times to retry a failed synthesis, and how long to wait.
///
/// The previous version classified errors as retryable and then did not retry
/// them. It recorded the sentence as failed and moved on, so a single rate
/// limit cost the listener a sentence in the middle of an article. The
/// classification was doing half a job.
///
/// Bounded on purpose. This runs inside a live read, so the listener is waiting
/// through every delay, and an unbounded backoff is indistinguishable from a
/// hang.
public struct RetryPolicy: Sendable {

    /// Attempts in total, including the first. 3 means one try and two retries.
    public let maxAttempts: Int
    /// Base for exponential backoff on transient failures.
    public let baseDelay: TimeInterval
    /// Never wait longer than this, even if the server asks for more. A caller
    /// is on the line; a 60 second `Retry-After` is worse than a lost sentence.
    public let maxDelay: TimeInterval

    public init(maxAttempts: Int = 3, baseDelay: TimeInterval = 0.4, maxDelay: TimeInterval = 4.0) {
        self.maxAttempts = maxAttempts
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
    }

    public static let `default` = RetryPolicy()

    /// - Parameters:
    ///   - error: what went wrong.
    ///   - attempt: 1-based number of the attempt that just failed.
    /// - Returns: seconds to wait before the next attempt, or nil to give up.
    public func delay(after error: ElevenLabsAPI.APIError, attempt: Int) -> TimeInterval? {
        guard error.isRetryable else { return nil }
        guard attempt < maxAttempts else { return nil }

        // Honour Retry-After when the server sends one, clamped so the listener
        // is never left in silence for longer than maxDelay.
        if case .rateLimited(let retryAfter) = error, let retryAfter, retryAfter > 0 {
            return min(retryAfter, maxDelay)
        }

        // Otherwise exponential: 0.4, 0.8, 1.6 ...
        let exponential = baseDelay * pow(2, Double(attempt - 1))
        return min(exponential, maxDelay)
    }

    /// Convenience for the call site.
    public func shouldRetry(_ error: ElevenLabsAPI.APIError, attempt: Int) -> Bool {
        delay(after: error, attempt: attempt) != nil
    }
}
