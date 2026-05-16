import AppKit
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    // fn-based shortcuts aren't supported by macOS global hotkey APIs.
    // ⌃⌘S is a good free combo; user can rebind from the menu bar UI.
    static let speakSelection = Self("speakSelection", default: .init(.s, modifiers: [.control, .command]))
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    private let serviceProvider = ServiceProvider()
    private let fnMonitor = FnKeyMonitor()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)

        KeyboardShortcuts.onKeyUp(for: .speakSelection) {
            Task { @MainActor in
                await SelectionReader.shared.captureAndSpeak()
            }
        }

        // Right-click → Services → "Speak with SpeakIt"
        NSApp.servicesProvider = serviceProvider
        NSUpdateDynamicServices()

        // speakit:// URL scheme (used by the browser extension)
        URLSchemeHandler.shared.register()

        _ = AccessibilityPermission.check(prompt: true)

        // Floating play button on hover-over-selection
        HoverSpeakButton.shared.start()

        // Speak-on-copy from watched apps (Claude desktop, etc.)
        ClipboardWatcher.shared.bootstrap()

        // Globe / fn single-tap → speak selection
        fnMonitor.onFnTap = {
            Task { @MainActor in
                await SelectionReader.shared.captureAndSpeak()
            }
        }
        fnMonitor.start()

        // Ensure the local-file server's python subprocess dies with us.
        // (Note: we don't touch isRunning state here — just terminate the
        //  process so it doesn't linger if it was running.)
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if LocalFileServer.shared.isRunning {
                    LocalFileServer.shared.stop()
                }
                // Belt-and-suspenders: drop any leftover tailscale serve config
                // even if the server wasn't "running" from our POV.
                TailscaleHelper.disableServeHTTPS()
            }
        }
    }
}
