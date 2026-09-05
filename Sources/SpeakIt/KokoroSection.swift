import AppKit
import SwiftUI
import SpeechKit

/// Install state for the local engine.
///
/// The other engines fail in ways the generic picker can express: Apple Speech
/// always works, Edge needs a CLI, ElevenLabs needs a key. This one needs a
/// 350 MB download, and selecting it before that has happened would otherwise
/// produce a voice list that looks complete and a play button that does
/// nothing.
struct KokoroSection: View {
    let provider: KokoroProvider

    /// Re-read on each menu open rather than observed. Setup runs in a
    /// terminal, outside the app entirely, so there is nothing to publish a
    /// change from; opening the menu is the natural moment to look again.
    @State private var status: KokoroInstall.Status = .ready

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch status {
            case .ready:
                Label("Running locally. No network, no API key.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case .notInstalled, .incomplete:
                if let explanation = status.explanation {
                    Label(explanation, systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Button("Copy setup command") {
                    let pasteboard = NSPasteboard.general
                    pasteboard.clearContents()
                    pasteboard.setString("./scripts/kokoro-setup.sh", forType: .string)
                }
                .controlSize(.small)
            }
        }
        .onAppear { status = provider.installStatus }
    }
}
