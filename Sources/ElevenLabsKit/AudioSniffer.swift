import Foundation

/// Checks that a 2xx body is actually audio before it is handed to a player.
///
/// A JSON error body can arrive with a 200, and an empty check only catches the
/// zero-length case. Without this, a malformed success turns into an
/// `AVAudioPlayer` init failure deep in the provider, which surfaces to the
/// listener as a silently skipped sentence rather than as an error anyone can
/// act on.
///
/// The live test asserted this and production did not, which is the wrong way
/// round.
public enum AudioSniffer {

    public enum Format: Equatable {
        case mp3
        case wav
        case ogg
        case flac
        /// The declared content type says audio but the bytes are unrecognised.
        /// Accepted, because the API may add a container this build predates.
        case unrecognisedButDeclaredAudio
    }

    /// - Parameters:
    ///   - data: the response body.
    ///   - contentType: the `Content-Type` header, if any.
    /// - Returns: the detected format, or nil when the body is not audio.
    public static func detect(_ data: Data, contentType: String? = nil) -> Format? {
        guard !data.isEmpty else { return nil }

        let head = [UInt8](data.prefix(12))

        // MP3: an ID3 tag, or a frame sync of 11 set bits.
        if head.count >= 3, head[0] == 0x49, head[1] == 0x44, head[2] == 0x33 { return .mp3 }
        if head.count >= 2, head[0] == 0xFF, (head[1] & 0xE0) == 0xE0 { return .mp3 }

        // WAV: "RIFF" .... "WAVE"
        if head.count >= 12,
           head[0] == 0x52, head[1] == 0x49, head[2] == 0x46, head[3] == 0x46,
           head[8] == 0x57, head[9] == 0x41, head[10] == 0x56, head[11] == 0x45 { return .wav }

        // OGG: "OggS"
        if head.count >= 4, head[0] == 0x4F, head[1] == 0x67, head[2] == 0x67, head[3] == 0x53 {
            return .ogg
        }

        // FLAC: "fLaC"
        if head.count >= 4, head[0] == 0x66, head[1] == 0x4C, head[2] == 0x61, head[3] == 0x43 {
            return .flac
        }

        // Nothing matched. Trust a declared audio content type rather than
        // rejecting a format this build has not heard of, but never trust a
        // declared JSON or text type.
        if let contentType = contentType?.lowercased(),
           contentType.hasPrefix("audio/") {
            return .unrecognisedButDeclaredAudio
        }

        return nil
    }

    /// True when the body is safe to hand to a player.
    public static func isAudio(_ data: Data, contentType: String? = nil) -> Bool {
        detect(data, contentType: contentType) != nil
    }
}
