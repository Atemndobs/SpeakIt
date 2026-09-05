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

    /// Which half of the state this instance is responsible for.
    ///
    /// The two halves live in different places in the menu. A working engine
    /// is reassurance, and reassurance belongs in the folded Settings section
    /// where it is not costing a line every time the menu opens. A broken
    /// engine is a call to action, and hiding that behind a closed disclosure
    /// would leave the app apparently mute with no sign of why.
    enum Variant {
        /// Render only when something needs fixing. Nothing when healthy.
        case problemOnly
        /// Render only the healthy line. Nothing when broken, because
        /// `problemOnly` has already said so further up.
        case statusOnly
    }

    var variant: Variant = .problemOnly

    /// Re-read on each menu open rather than observed. Setup runs in a
    /// terminal, outside the app entirely, so there is nothing to publish a
    /// change from; opening the menu is the natural moment to look again.
    @State private var status: KokoroInstall.Status = .ready

    var body: some View {
        Group {
            switch (variant, status) {
            case (.statusOnly, .ready):
                Label("Running locally. No network, no API key.", systemImage: "checkmark.seal")
                    .font(.caption)
                    .foregroundStyle(.secondary)

            case (.problemOnly, .notInstalled), (.problemOnly, .incomplete):
                VStack(alignment: .leading, spacing: 6) {
                    if let explanation = status.explanation {
                        Label(explanation, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Button {
                        let pasteboard = NSPasteboard.general
                        pasteboard.clearContents()
                        pasteboard.setString("./scripts/kokoro-setup.sh", forType: .string)
                    } label: {
                        Label("Copy setup command", systemImage: "doc.on.doc")
                    }
                    .controlSize(.small)
                }

            default:
                EmptyView()
            }
        }
        .onAppear { status = provider.installStatus }
    }
}
