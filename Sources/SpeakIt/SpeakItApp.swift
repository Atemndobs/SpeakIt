import SwiftUI
import AppKit

@main
struct SpeakItApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra {
            MenuBarView()
                .environmentObject(TTSEngine.shared)
        } label: {
            MenuBarLabel()
        }
        .menuBarExtraStyle(.window)
    }
}

private struct MenuBarLabel: View {
    @ObservedObject private var engine = TTSEngine.shared

    var body: some View {
        Image(systemName: iconName)
            .symbolRenderingMode(.hierarchical)
            .foregroundStyle(iconColor)
    }

    private var iconName: String {
        if engine.isPaused { return "pause.circle.fill" }
        if engine.isSpeaking { return "waveform.circle.fill" }
        return "speaker.wave.2"
    }

    private var iconColor: Color {
        if engine.isSpeaking && !engine.isPaused { return .accentColor }
        return .primary
    }
}
