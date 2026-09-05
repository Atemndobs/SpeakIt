import Foundation

/// Maps SpeakIt's speech-rate slider onto an `AVAudioPlayer` rate multiplier.
///
/// The ElevenLabs API has no speaking-rate parameter, unlike `edge-tts` where
/// the rate is baked into synthesis. So rate has to be applied at playback,
/// which makes this mapping the one piece of ElevenLabs rate handling that can
/// be wrong in a way the user hears.
///
/// The slider is centred on `AVSpeechUtteranceDefaultSpeechRate`, which is 0.5.
/// That midpoint MUST map to 1.0 or every read is pitched wrong at the default
/// setting, which is the setting almost everyone stays on.
///
/// Lives in the kit rather than the provider so it can be tested: the provider
/// is in the `@main` executable target.
public enum PlaybackRate {

    /// Rates outside this range produce audible artefacts through
    /// `AVAudioPlayer`'s time-pitch unit.
    public static let minimum: Float = 0.5
    public static let maximum: Float = 2.0

    /// - Parameter sliderValue: 0...1, centred on 0.5.
    /// - Returns: a playback multiplier in `minimum...maximum`, where 0.5 maps
    ///   to exactly 1.0.
    public static func multiplier(fromSlider sliderValue: Float) -> Float {
        let normalized = max(0, min(1, sliderValue))
        let rate = normalized <= 0.5
            ? 0.5 + normalized                   // 0.0 -> 0.5x, 0.5 -> 1.0x
            : 1.0 + (normalized - 0.5) * 2.0     // 0.5 -> 1.0x, 1.0 -> 2.0x
        return max(minimum, min(maximum, rate))
    }
}
