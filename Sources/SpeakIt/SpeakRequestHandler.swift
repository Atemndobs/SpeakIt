import Foundation

@MainActor
final class SpeakRequestHandler {
    static let shared = SpeakRequestHandler()

    func handle(_ request: SpeakRequest) {
        let normalized = ResponseTextAdapter.normalize(
            request.text,
            sanitizeMarkdown: request.sanitizeMarkdown
        )
        guard !normalized.isEmpty else {
            NSLog("[SpeakIt] speak request dropped source=%@ action=%@ reason=empty", request.source.rawValue, request.action.rawValue)
            return
        }

        NSLog("[SpeakIt] speak request source=%@ action=%@ chars=%ld", request.source.rawValue, request.action.rawValue, normalized.count)
        TTSEngine.shared.handleSpeakRequest(
            SpeakRequest(
                text: normalized,
                source: request.source,
                action: request.action,
                sanitizeMarkdown: false
            )
        )
    }
}
