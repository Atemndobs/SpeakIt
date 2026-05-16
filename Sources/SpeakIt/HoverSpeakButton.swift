import SwiftUI
import AppKit

/// A floating play button that appears next to the selected text when the
/// cursor hovers over the selection. Click → speak. Disappears when the
/// cursor leaves both the selection and the button.
@MainActor
final class HoverSpeakButton {
    static let shared = HoverSpeakButton()

    static let autoShowKey = "SpeakIt.autoShowOnSelection"

    private var panel: NSPanel?
    private var globalMonitor: Any?
    private var localMonitor: Any?
    private var hideWorkItem: DispatchWorkItem?
    private var lastSelection: SelectionWatcher.Selection?

    private var autoShow: Bool {
        UserDefaults.standard.bool(forKey: Self.autoShowKey)
    }

    func start() {
        SelectionWatcher.shared.onChange = { [weak self] sel in
            self?.lastSelection = sel
            self?.evaluate()
        }
        SelectionWatcher.shared.start()

        globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved]) { [weak self] _ in
            Task { @MainActor in self?.evaluate() }
        }
        localMonitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved]) { [weak self] event in
            Task { @MainActor in self?.evaluate() }
            return event
        }
    }

    private func evaluate() {
        guard let sel = lastSelection, sel.bounds != .zero else {
            // No selection — hide immediately regardless of mode
            hideWorkItem?.cancel()
            hide()
            return
        }
        let nsBounds = axToNS(sel.bounds)

        if autoShow {
            // Stay pinned next to the selection until it changes or clears
            hideWorkItem?.cancel()
            show(near: nsBounds)
            return
        }

        let mouse = NSEvent.mouseLocation
        let inSelection = nsBounds.insetBy(dx: -6, dy: -6).contains(mouse)
        let inButton = (panel?.frame.insetBy(dx: -8, dy: -8).contains(mouse)) ?? false
        if inSelection || inButton {
            hideWorkItem?.cancel()
            show(near: nsBounds)
        } else {
            scheduleHide()
        }
    }

    private func scheduleHide() {
        hideWorkItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.hide() }
        hideWorkItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: item)
    }

    private func show(near rect: NSRect) {
        let size = NSSize(width: 32, height: 32)
        // Anchor to top-right corner of selection, slightly offset
        let frame = NSRect(
            x: rect.maxX + 4,
            y: rect.maxY - size.height,
            width: size.width,
            height: size.height
        )
        if let p = panel {
            if p.frame != frame { p.setFrame(frame, display: false) }
            return
        }
        let p = NSPanel(
            contentRect: frame,
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: PlayPill(onTap: { [weak self] in
            guard let text = self?.lastSelection?.text else { return }
            TTSEngine.shared.speak(text)
            self?.hide()
        }))
        p.orderFrontRegardless()
        panel = p
    }

    private func hide() {
        panel?.orderOut(nil)
        panel = nil
    }

    private func axToNS(_ rect: CGRect) -> NSRect {
        // AX uses top-left origin; NS uses bottom-left. Primary screen anchors both.
        let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
        return NSRect(
            x: rect.origin.x,
            y: primaryHeight - rect.origin.y - rect.height,
            width: rect.width,
            height: rect.height
        )
    }
}

private struct PlayPill: View {
    let onTap: () -> Void
    @State private var hovering = false
    var body: some View {
        Button(action: onTap) {
            Image(systemName: "play.fill")
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.white)
                .frame(width: 32, height: 32)
                .background(
                    Circle().fill(Color.accentColor)
                )
                .overlay(
                    Circle().stroke(.white.opacity(0.15), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
                .scaleEffect(hovering ? 1.08 : 1.0)
                .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}
