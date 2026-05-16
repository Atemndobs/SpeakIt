import SwiftUI
import AppKit
import NaturalLanguage

/// Persistent floating player. Drag-to-move; last position is restored on launch.
/// Two visual states:
///   • minimized → circular badge with progress ring
///   • expanded  → controls + linear scrubber + drag grip
@MainActor
final class BubbleWindow: ObservableObject {
    static let shared = BubbleWindow()

    @Published private(set) var isVisible: Bool = false
    @Published var expanded: Bool = false
    @Published var showTranscript: Bool = false

    private var panel: NSPanel?
    private var dragStartOrigin: NSPoint?

    private let minSize = NSSize(width: 56, height: 56)
    private let barSize = NSSize(width: 360, height: 56)
    private let transcriptSize = NSSize(width: 420, height: 280)
    private let screenMargin: CGFloat = 20
    private static let positionKey = "SpeakIt.bubblePosition"

    func show() {
        if panel == nil { createPanel() }
        panel?.orderFrontRegardless()
        isVisible = true
    }

    func hide() {
        panel?.orderOut(nil)
        isVisible = false
    }

    func setExpanded(_ value: Bool) {
        guard expanded != value else { return }
        expanded = value
        if !value { showTranscript = false }
        applySize()
    }

    func toggleTranscript() {
        showTranscript.toggle()
        applySize()
    }

    private func applySize() {
        guard let panel else { return }
        var frame = panel.frame
        frame.size = currentSize()
        panel.setFrame(frame, display: true, animate: true)
        savePosition()
    }

    private func currentSize() -> NSSize {
        if !expanded { return minSize }
        return showTranscript ? transcriptSize : barSize
    }

    // MARK: Drag

    func beginDrag() {
        dragStartOrigin = panel?.frame.origin
    }

    func updateDrag(translation: CGSize) {
        guard let start = dragStartOrigin, let panel else { return }
        var frame = panel.frame
        // SwiftUI translation.y is positive going DOWN; NSWindow Y is positive going UP.
        frame.origin = NSPoint(
            x: start.x + translation.width,
            y: start.y - translation.height
        )
        panel.setFrame(frame, display: true)
    }

    func endDrag() {
        dragStartOrigin = nil
        savePosition()
    }

    // MARK: Internals

    private func createPanel() {
        let p = NSPanel(
            contentRect: NSRect(origin: .zero, size: minSize),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = false
        p.hidesOnDeactivate = false
        p.contentView = NSHostingView(rootView: PlayerView(window: self))

        let origin = restoredPosition() ?? defaultOrigin()
        p.setFrameOrigin(origin)

        panel = p
    }

    private func defaultOrigin() -> NSPoint {
        guard let screen = NSScreen.main ?? NSScreen.screens.first else { return .zero }
        let v = screen.visibleFrame
        return NSPoint(x: v.minX + screenMargin, y: v.minY + screenMargin)
    }

    private func restoredPosition() -> NSPoint? {
        guard let arr = UserDefaults.standard.array(forKey: Self.positionKey) as? [Double],
              arr.count == 2 else { return nil }
        let pt = NSPoint(x: arr[0], y: arr[1])
        // Accept only if some screen still contains the position
        let probe = NSRect(origin: pt, size: minSize)
        for screen in NSScreen.screens where screen.visibleFrame.intersects(probe) {
            return pt
        }
        return nil
    }

    private func savePosition() {
        guard let panel else { return }
        let o = panel.frame.origin
        UserDefaults.standard.set([Double(o.x), Double(o.y)], forKey: Self.positionKey)
    }
}

// MARK: - SwiftUI

private struct PlayerView: View {
    @ObservedObject var window: BubbleWindow
    @ObservedObject private var engine = TTSEngine.shared

    var body: some View {
        Group {
            if window.expanded {
                if window.showTranscript {
                    TranscriptPanel(
                        engine: engine,
                        window: window,
                        onCollapse: { window.setExpanded(false) },
                        onClose: closePlayer
                    )
                } else {
                    ExpandedBar(
                        engine: engine,
                        window: window,
                        onCollapse: { window.setExpanded(false) },
                        onClose: closePlayer
                    )
                }
            } else {
                CircleBadge(
                    engine: engine,
                    window: window,
                    onExpand: { window.setExpanded(true) },
                    onClose: closePlayer
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func closePlayer() {
        engine.stop()
        window.hide()
    }
}

private struct CircleBadge: View {
    @ObservedObject var engine: TTSEngine
    @ObservedObject var window: BubbleWindow
    let onExpand: () -> Void
    let onClose: () -> Void

    @State private var dragging = false

    var body: some View {
        ZStack {
            Circle()
                .fill(.regularMaterial)

            Circle()
                .stroke(.white.opacity(0.12), lineWidth: 3)
                .padding(4)

            Circle()
                .trim(from: 0, to: max(0, min(1, engine.progress)))
                .stroke(
                    Color.accentColor,
                    style: StrokeStyle(lineWidth: 3, lineCap: .round)
                )
                .rotationEffect(.degrees(-90))
                .padding(4)
                .animation(.linear(duration: 0.12), value: engine.progress)

            Image(systemName: stateIcon)
                .font(.system(size: 16, weight: .bold))
                .foregroundStyle(.primary)
        }
        .frame(width: 48, height: 48)
        .padding(4)
        .shadow(color: .black.opacity(0.25), radius: 4, y: 2)
        .contentShape(Circle())
        .onTapGesture { onExpand() }
        .simultaneousGesture(dragGesture)
        .contextMenu {
            Button("Expand") { onExpand() }
            Divider()
            Button("Close Player") { onClose() }
            Button("Quit SpeakIt") { NSApp.terminate(nil) }
        }
    }

    private var dragGesture: some Gesture {
        DragGesture(minimumDistance: 4, coordinateSpace: .global)
            .onChanged { value in
                if !dragging {
                    window.beginDrag()
                    dragging = true
                }
                window.updateDrag(translation: value.translation)
            }
            .onEnded { _ in
                dragging = false
                window.endDrag()
            }
    }

    private var stateIcon: String {
        if engine.isPaused { return "play.fill" }
        if engine.isSpeaking { return "waveform" }
        return "play.fill"
    }
}

private struct ExpandedBar: View {
    @ObservedObject var engine: TTSEngine
    @ObservedObject var window: BubbleWindow
    let onCollapse: () -> Void
    let onClose: () -> Void

    @State private var dragValue: Double = 0
    @State private var scrubbing = false

    var body: some View {
        HStack(spacing: 8) {
            DragGrip(window: window)

            prevChunkButton
            playPauseButton
            nextChunkButton
            stopButton

            Slider(
                value: Binding(
                    get: { scrubbing ? dragValue : engine.progress },
                    set: { dragValue = $0 }
                ),
                in: 0...1,
                onEditingChanged: { editing in
                    if editing {
                        scrubbing = true
                        dragValue = engine.progress
                    } else {
                        scrubbing = false
                        engine.seek(to: dragValue)
                    }
                }
            )
            .tint(.accentColor)
            .controlSize(.small)

            HoverChip(
                symbol: window.showTranscript ? "text.alignleft" : "text.alignleft",
                action: { window.toggleTranscript() }
            )
            HoverChip(symbol: "minus", action: onCollapse)
            HoverChip(symbol: "xmark", action: onClose)
        }
        .padding(.horizontal, 8)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .padding(2)
    }

    private var playPauseButton: some View {
        Button { engine.togglePause() } label: {
            Image(systemName: engine.isPaused || !engine.isSpeaking ? "play.fill" : "pause.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private var stopButton: some View {
        Button { engine.stop() } label: {
            Image(systemName: "stop.fill")
                .font(.system(size: 14, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
    }

    private var prevChunkButton: some View {
        Button { engine.previousChunk() } label: {
            Image(systemName: "backward.end.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!engine.isSpeaking && !engine.isPaused)
        .help("Previous sentence / paragraph")
    }

    private var nextChunkButton: some View {
        Button { engine.nextChunk() } label: {
            Image(systemName: "forward.end.fill")
                .font(.system(size: 13, weight: .semibold))
                .frame(width: 22, height: 22)
        }
        .buttonStyle(.plain)
        .disabled(!engine.isSpeaking && !engine.isPaused)
        .help("Skip to next sentence / paragraph")
    }
}

// MARK: Transcript

private struct TranscriptPanel: View {
    @ObservedObject var engine: TTSEngine
    @ObservedObject var window: BubbleWindow
    let onCollapse: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            TranscriptView(
                text: engine.currentText,
                highlight: engine.highlightRange,
                onTapSentence: { range in engine.seekToCharacter(range.location) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            Divider()
            ExpandedBar(
                engine: engine,
                window: window,
                onCollapse: onCollapse,
                onClose: onClose
            )
            .frame(height: 56)
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.25), radius: 6, y: 3)
        .padding(2)
    }
}

private struct TranscriptView: View {
    let text: String
    let highlight: NSRange?
    let onTapSentence: (NSRange) -> Void

    private var sentences: [(idx: Int, text: String, range: NSRange)] {
        guard !text.isEmpty else { return [] }
        let tokenizer = NLTokenizer(unit: .sentence)
        tokenizer.string = text
        var out: [(Int, String, NSRange)] = []
        var i = 0
        tokenizer.enumerateTokens(in: text.startIndex..<text.endIndex) { range, _ in
            let s = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty {
                let ns = NSRange(range, in: text)
                out.append((i, s, ns))
                i += 1
            }
            return true
        }
        if out.isEmpty {
            return [(0, text, NSRange(location: 0, length: (text as NSString).length))]
        }
        return out
    }

    private func isActive(_ range: NSRange) -> Bool {
        guard let h = highlight else { return false }
        return NSIntersectionRange(range, h).length > 0
    }

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 6) {
                    ForEach(sentences, id: \.idx) { s in
                        Text(s.text)
                            .font(.system(size: 13))
                            .foregroundStyle(isActive(s.range) ? Color.primary : Color.secondary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isActive(s.range) ? Color.accentColor.opacity(0.22) : .clear)
                            )
                            .contentShape(Rectangle())
                            .onTapGesture { onTapSentence(s.range) }
                            .help("Click to play from here")
                            .id(s.idx)
                    }
                }
                .padding(10)
            }
            .onChange(of: highlight) { _, _ in
                if let active = sentences.first(where: { isActive($0.range) }) {
                    withAnimation(.easeOut(duration: 0.25)) {
                        proxy.scrollTo(active.idx, anchor: .center)
                    }
                }
            }
        }
    }
}

private struct HoverChip: View {
    let symbol: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 12, weight: .bold))
                .foregroundStyle(hovering ? Color.primary : Color.secondary)
                .frame(width: 28, height: 28)
                .background(
                    Circle()
                        .fill(.white.opacity(hovering ? 0.12 : 0))
                )
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

private struct DragGrip: View {
    @ObservedObject var window: BubbleWindow
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 2) {
            Capsule().fill(.secondary.opacity(hovering ? 0.8 : 0.4)).frame(width: 2, height: 14)
            Capsule().fill(.secondary.opacity(hovering ? 0.8 : 0.4)).frame(width: 2, height: 14)
        }
        .frame(width: 16, height: 28)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging {
                        window.beginDrag()
                        dragging = true
                    }
                    window.updateDrag(translation: value.translation)
                }
                .onEnded { _ in
                    dragging = false
                    window.endDrag()
                }
        )
    }
}
