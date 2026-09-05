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
    /// User-draggable width of the expanded mini-player. Drives which controls
    /// stay visible (see ExpandedBar.mode). Persisted across launches.
    @Published var barWidth: CGFloat = UserDefaults.standard.object(forKey: BubbleWindow.widthKey) as? Double ?? 384
    /// User-draggable height of the expanded mini-player (corner resize).
    @Published var barHeight: CGFloat = UserDefaults.standard.object(forKey: BubbleWindow.heightKey) as? Double ?? 72

    private var panel: NSPanel?
    private var dragStartOrigin: NSPoint?
    private var resizeStartFrame: NSRect?

    private let minSize = NSSize(width: 56, height: 56)
    let minBarWidth: CGFloat = 148
    let maxBarWidth: CGFloat = 480
    let minBarHeight: CGFloat = 46
    let maxBarHeight: CGFloat = 108
    private let transcriptSize = NSSize(width: 420, height: 320)
    private let screenMargin: CGFloat = 20
    private static let positionKey = "SpeakIt.bubblePosition"
    private static let widthKey = "SpeakIt.barWidth"
    private static let heightKey = "SpeakIt.barHeight"

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

    private func applySize(animated: Bool = true) {
        guard let panel else { return }
        var frame = panel.frame
        frame.size = currentSize()
        panel.setFrame(frame, display: true, animate: animated)
        savePosition()
    }

    private func currentSize() -> NSSize {
        if !expanded { return minSize }
        if showTranscript { return transcriptSize }
        return NSSize(width: barWidth, height: barHeight)
    }

    // MARK: Resize (expanded mini-player, corner drag → width + height)

    func beginResize() { resizeStartFrame = panel?.frame }

    /// Corner drag. `dw`/`dh` are SwiftUI translation (dh positive = downward).
    /// The top-left corner stays put: width grows to the right, height grows
    /// downward (so the panel's visual top edge doesn't jump).
    func updateResize(dw: CGFloat, dh: CGFloat) {
        guard let panel, let start = resizeStartFrame else { return }
        let w = min(maxBarWidth, max(minBarWidth, start.width + dw))
        let h = min(maxBarHeight, max(minBarHeight, start.height + dh))
        var f = start
        f.size = NSSize(width: w, height: h)
        f.origin.y = start.origin.y + (start.height - h)
        panel.setFrame(f, display: true)
        barWidth = w
        barHeight = h
    }

    func endResize() {
        resizeStartFrame = nil
        UserDefaults.standard.set(Double(barWidth), forKey: Self.widthKey)
        UserDefaults.standard.set(Double(barHeight), forKey: Self.heightKey)
        savePosition()
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
        .help(engine.currentTitle.isEmpty ? "SpeakIt" : "Reading: \(engine.currentTitle)")
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

/// Spotify-mini-player-style transport card, resizable by dragging the right
/// edge. As it narrows it sheds controls gracefully:
///   full     [•• drag] [logo] now-reading / source   [‹] (▶) [›]  + bottom seek
///   compact           [logo] now-reading / source        (▶) [›]  + bottom seek
///   mini              [logo] (now-reading)              (◍▶) [›]   progress = ring
/// A red close dot sits in the top-left; transcript / minimize live on the
/// right-click menu. The album art is the active voice provider's logo.
private struct ExpandedBar: View {
    @ObservedObject var engine: TTSEngine
    @ObservedObject var window: BubbleWindow
    let onCollapse: () -> Void
    let onClose: () -> Void

    /// When embedded at the foot of the transcript panel, drop the rounded
    /// clip + shadow so it doesn't draw a card-inside-a-card, and stay full.
    var embedded: Bool = false

    @State private var dragging = false

    private enum Mode { case full, compact, mini }
    private var mode: Mode {
        if embedded { return .full }
        let w = window.barWidth
        if w < 210 { return .mini }
        if w < 300 { return .compact }
        return .full
    }

    private var enabled: Bool { engine.isSpeaking || engine.isPaused }
    private var showGrip: Bool { mode == .full }
    private var showPrev: Bool { mode == .full }
    private var showBottomSeek: Bool { mode != .mini }
    private var ringProgress: Bool { mode == .mini }
    private var showMeta: Bool { mode != .mini || window.barWidth >= 176 }
    private var showNext: Bool { mode != .mini || window.barWidth >= 176 }

    var body: some View {
        ZStack(alignment: .bottomLeading) {
            content
            if showBottomSeek {
                SeekBar(engine: engine)
                    .padding(.horizontal, embedded ? 0 : 2)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(cardBackground)
        .clipShape(RoundedRectangle(cornerRadius: embedded ? 0 : 15, style: .continuous))
        .overlay(alignment: .topLeading) {
            if !embedded { WindowControls(onClose: onClose, onMinimize: onCollapse) }
        }
        .overlay(alignment: .bottomTrailing) { if !embedded { ResizeHandle(window: window) } }
        .overlay {
            if !embedded {
                RoundedRectangle(cornerRadius: 15, style: .continuous)
                    .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
            }
        }
        .shadow(color: embedded ? .clear : .black.opacity(0.35), radius: 10, y: 4)
        .padding(embedded ? 0 : 2)
        .contextMenu {
            Button(window.showTranscript ? "Hide Transcript" : "Show Transcript") { window.toggleTranscript() }
            Button("Minimize") { onCollapse() }
            Divider()
            Button("Close Player") { onClose() }
            Button("Quit SpeakIt") { NSApp.terminate(nil) }
        }
    }

    private var content: some View {
        HStack(spacing: mode == .mini ? 8 : 10) {
            if showGrip { DotDragHandle(window: window) }

            // Art + text double as a drag surface once the grip is gone.
            HStack(spacing: mode == .mini ? 8 : 10) {
                ProviderArtwork(providerId: engine.activeProviderId,
                                active: engine.isSpeaking && !engine.isPaused)
                    .onTapGesture { window.toggleTranscript() }
                    .help(providerHelp)

                if showMeta { titleBlock }
            }
            .simultaneousGesture(windowDrag)

            Spacer(minLength: 4)

            controls
        }
        .padding(.leading, showGrip ? 6 : 8)
        .padding(.trailing, mode == .mini ? 8 : 14)
        .padding(.top, 2)
        .padding(.bottom, showBottomSeek ? 4 : 2)
    }

    private var windowDrag: some Gesture {
        DragGesture(minimumDistance: 3, coordinateSpace: .global)
            .onChanged { v in
                if !dragging { window.beginDrag(); dragging = true }
                window.updateDrag(translation: v.translation)
            }
            .onEnded { _ in dragging = false; window.endDrag() }
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 1) {
            Text(mode == .mini ? voiceName : nowReading)
                .font(.system(size: 12.5, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)
                .truncationMode(.tail)

            if mode != .mini { SubtitleLink(engine: engine) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// The active provider's selected voice (shown in mini mode where the full
    /// sentence won't fit). Falls back to the provider name, then a label.
    private var voiceName: String {
        if let p = engine.activeProvider, let vid = engine.selectedVoiceId,
           let v = p.availableVoices.first(where: { $0.id == vid }) {
            return v.name
        }
        return engine.activeProvider?.displayName ?? "SpeakIt"
    }

    private var controls: some View {
        HStack(spacing: mode == .mini ? 8 : 10) {
            if showPrev {
                Button { engine.previousChunk() } label: {
                    Image(systemName: "backward.end.fill")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(enabled ? .white.opacity(0.85) : .white.opacity(0.3))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help("Previous sentence")
            }

            PlayButton(engine: engine, showRing: ringProgress)

            if showNext {
                Button { engine.nextChunk() } label: {
                    Image(systemName: "forward.end.fill")
                        .font(.system(size: 12, weight: .heavy))
                        .foregroundStyle(enabled ? .white.opacity(0.85) : .white.opacity(0.3))
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .disabled(!enabled)
                .help("Next sentence")
            }
        }
    }

    private var cardBackground: some View {
        LinearGradient(
            colors: [Color(red: 0.16, green: 0.16, blue: 0.17),
                     Color(red: 0.09, green: 0.09, blue: 0.10)],
            startPoint: .top, endPoint: .bottom
        )
    }

    private var providerHelp: String {
        let name = engine.activeProvider?.displayName ?? "Voice"
        return "\(name) — click for transcript"
    }

    /// Primary line: the sentence currently being spoken (falls back to the
    /// start of the loaded text, then the title, then a resting label).
    private var nowReading: String {
        let ns = engine.currentText as NSString
        if let h = engine.highlightRange, h.length > 0,
           h.location != NSNotFound, h.location + h.length <= ns.length {
            let s = ns.substring(with: h).trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { return s }
        }
        let full = engine.currentText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !full.isEmpty { return String(full.prefix(140)) }
        if !engine.currentTitle.isEmpty { return engine.currentTitle }
        return "SpeakIt"
    }
}

/// White circular play/pause. In `showRing` (mini) mode it wears a progress
/// ring so the bottom seek line can be dropped when the card is narrow.
private struct PlayButton: View {
    @ObservedObject var engine: TTSEngine
    var showRing: Bool

    private var isPlay: Bool { engine.isPaused || !engine.isSpeaking }

    var body: some View {
        Button { engine.togglePause() } label: {
            ZStack {
                if showRing {
                    Circle().stroke(.white.opacity(0.18), lineWidth: 2.5)
                    Circle()
                        .trim(from: 0, to: max(0, min(1, engine.progress)))
                        .stroke(.white, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                        .rotationEffect(.degrees(-90))
                        .animation(.linear(duration: 0.12), value: engine.progress)
                }
                Circle().fill(.white)
                    .frame(width: 32, height: 32)
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                Image(systemName: isPlay ? "play.fill" : "pause.fill")
                    .font(.system(size: 13, weight: .black))
                    .foregroundStyle(.black)
                    .offset(x: isPlay ? 0.5 : 0)
            }
            .frame(width: showRing ? 40 : 32, height: showRing ? 40 : 32)
        }
        .buttonStyle(.plain)
        .help(isPlay ? "Play" : "Pause")
    }
}

/// Album-art tile branded with the active voice provider's logo, so it's clear
/// at a glance which engine is speaking (ElevenLabs, Apple, Microsoft Edge).
private struct ProviderArtwork: View {
    let providerId: String
    let active: Bool

    var body: some View {
        RoundedRectangle(cornerRadius: 8, style: .continuous)
            .fill(background)
            .overlay(mark)
            .overlay(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .strokeBorder(.white.opacity(0.12), lineWidth: 0.5)
            )
            .frame(width: 42, height: 42)
            .overlay(alignment: .bottomTrailing) {
                if active {
                    Image(systemName: "waveform")
                        .font(.system(size: 8, weight: .bold))
                        .foregroundStyle(.white)
                        .padding(2)
                        .background(Circle().fill(.black.opacity(0.55)))
                        .padding(2)
                        .symbolEffect(.variableColor.iterative, isActive: active)
                }
            }
    }

    private var background: AnyShapeStyle {
        switch providerId {
        case "elevenlabs":
            return AnyShapeStyle(Color.black)
        case "av-speech":
            return AnyShapeStyle(LinearGradient(
                colors: [Color(white: 0.30), Color(white: 0.10)],
                startPoint: .top, endPoint: .bottom))
        case "edge-tts":
            return AnyShapeStyle(Color(white: 0.96))
        case "kokoro":
            return AnyShapeStyle(LinearGradient(
                colors: [Color(red: 0.92, green: 0.36, blue: 0.56),
                         Color(red: 0.55, green: 0.15, blue: 0.42)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        default:
            let hue = Double(abs(providerId.hashValue) % 360) / 360.0
            return AnyShapeStyle(LinearGradient(
                colors: [Color(hue: hue, saturation: 0.55, brightness: 0.80),
                         Color(hue: hue, saturation: 0.65, brightness: 0.55)],
                startPoint: .topLeading, endPoint: .bottomTrailing))
        }
    }

    @ViewBuilder private var mark: some View {
        switch providerId {
        case "elevenlabs":
            // The ElevenLabs "11" mark: two rounded bars.
            HStack(spacing: 3) {
                Capsule().fill(.white).frame(width: 3.5, height: 16)
                Capsule().fill(.white).frame(width: 3.5, height: 16)
            }
        case "av-speech":
            Image(systemName: "apple.logo")
                .font(.system(size: 17, weight: .medium))
                .foregroundStyle(.white)
        case "edge-tts":
            MicrosoftSquares()
        case "kokoro":
            // Kokoro (心 — "heart"): a heart mark for the local neural voice.
            Image(systemName: "heart.fill")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white)
        default:
            Image(systemName: "waveform")
                .font(.system(size: 15, weight: .semibold))
                .foregroundStyle(.white.opacity(0.95))
        }
    }
}

/// The four-square Microsoft mark, drawn (no bundled asset needed).
private struct MicrosoftSquares: View {
    private let s: CGFloat = 9
    private let g: CGFloat = 2
    var body: some View {
        VStack(spacing: g) {
            HStack(spacing: g) {
                Rectangle().fill(Color(red: 0.95, green: 0.33, blue: 0.15)).frame(width: s, height: s)
                Rectangle().fill(Color(red: 0.51, green: 0.74, blue: 0.02)).frame(width: s, height: s)
            }
            HStack(spacing: g) {
                Rectangle().fill(Color(red: 0.02, green: 0.65, blue: 0.94)).frame(width: s, height: s)
                Rectangle().fill(Color(red: 1.00, green: 0.73, blue: 0.03)).frame(width: s, height: s)
            }
        }
    }
}

/// Bottom-right corner grip: drag to resize the mini-player (width + height).
private struct ResizeHandle: View {
    @ObservedObject var window: BubbleWindow
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 16, height: 16)
            .overlay(alignment: .bottomTrailing) {
                Image(systemName: "line.diagonal")
                    .font(.system(size: 9, weight: .heavy))
                    .foregroundStyle(.white.opacity(hovering || dragging ? 0.5 : 0.18))
                    .rotationEffect(.degrees(90))
                    .padding(.trailing, 3)
                    .padding(.bottom, 2)
            }
            .contentShape(Rectangle())
            .onHover { inside in
                hovering = inside
                if inside { NSCursor.crosshair.push() } else { NSCursor.pop() }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { v in
                        if !dragging { window.beginResize(); dragging = true }
                        window.updateResize(dw: v.translation.width, dh: v.translation.height)
                    }
                    .onEnded { _ in dragging = false; window.endResize() }
            )
    }
}

/// Secondary line: the source / project label. Clickable to open in the reader
/// when a source path is known (keeps the old SourceTitleBar behavior).
private struct SubtitleLink: View {
    @ObservedObject var engine: TTSEngine
    @State private var hovering = false

    private var hasSource: Bool { engine.currentSource != nil }
    private var label: String { engine.currentTitle.isEmpty ? "SpeakIt" : engine.currentTitle }

    var body: some View {
        HStack(spacing: 3) {
            Text(label)
                .font(.system(size: 10.5, weight: .medium))
                .foregroundStyle(hasSource && hovering ? Color.white.opacity(0.9) : Color.white.opacity(0.55))
                .underline(hasSource && hovering)
                .lineLimit(1)
                .truncationMode(.middle)
            if hasSource {
                Image(systemName: "arrow.up.forward")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(hovering ? Color.white.opacity(0.9) : Color.white.opacity(0.4))
            }
        }
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture { if hasSource { engine.openSource() } }
        .help(hasSource ? "Open in reader: \(engine.currentSource ?? "")" : label)
    }
}

/// Thin progress line along the bottom edge; drag anywhere on it to seek.
private struct SeekBar: View {
    @ObservedObject var engine: TTSEngine
    @State private var hovering = false
    @State private var dragFraction: Double?

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let shown = dragFraction ?? max(0, min(1, engine.progress))
            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.14))
                Capsule().fill(.white.opacity(hovering || dragFraction != nil ? 0.95 : 0.55))
                    .frame(width: max(0, w * shown))
            }
            .frame(height: hovering || dragFraction != nil ? 4 : 2.5)
            .frame(maxHeight: .infinity, alignment: .bottom)
            .contentShape(Rectangle().inset(by: -6))
            .onHover { hovering = $0 }
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in dragFraction = max(0, min(1, v.location.x / w)) }
                    .onEnded { v in
                        let f = max(0, min(1, v.location.x / w))
                        engine.seek(to: f)
                        dragFraction = nil
                    }
            )
            .animation(.easeOut(duration: 0.12), value: hovering)
        }
        .frame(height: 8)
    }
}

/// Six-dot drag handle (2×3), the Spotify-style grip. Moves the whole window.
private struct DotDragHandle: View {
    @ObservedObject var window: BubbleWindow
    @State private var dragging = false
    @State private var hovering = false

    var body: some View {
        let dot = Circle().fill(.white.opacity(hovering ? 0.7 : 0.35)).frame(width: 2.5, height: 2.5)
        HStack(spacing: 3) {
            VStack(spacing: 3) { dot; dot; dot }
            VStack(spacing: 3) { dot; dot; dot }
        }
        .frame(width: 18, height: 40)
        .contentShape(Rectangle())
        .onHover { inside in
            hovering = inside
            if inside { NSCursor.openHand.push() } else { NSCursor.pop() }
        }
        .gesture(
            DragGesture(minimumDistance: 0, coordinateSpace: .global)
                .onChanged { value in
                    if !dragging { window.beginDrag(); dragging = true }
                    window.updateDrag(translation: value.translation)
                }
                .onEnded { _ in dragging = false; window.endDrag() }
        )
    }
}

/// macOS-traffic-light control cluster in the top-left corner: red closes the
/// player, amber collapses it back to the circular micro view.
private struct WindowControls: View {
    let onClose: () -> Void
    let onMinimize: () -> Void

    var body: some View {
        HStack(spacing: 6) {
            TrafficDot(color: Color(red: 0.98, green: 0.35, blue: 0.33),
                       symbol: "xmark", help: "Close player", action: onClose)
            TrafficDot(color: Color(red: 0.99, green: 0.74, blue: 0.20),
                       symbol: "minus", help: "Minimize to circle", action: onMinimize)
        }
        .padding(.leading, 6)
        .padding(.top, 5)
    }
}

/// One traffic-light dot: colored circle that reveals its glyph on hover.
private struct TrafficDot: View {
    let color: Color
    let symbol: String
    let help: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Circle()
                .fill(color)
                .frame(width: 11, height: 11)
                .overlay(
                    Image(systemName: symbol)
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(.black.opacity(0.6))
                        .opacity(hovering ? 1 : 0)
                )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
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
            HStack(spacing: 8) {
                TrafficDot(color: Color(red: 0.98, green: 0.35, blue: 0.33),
                           symbol: "xmark", help: "Close player", action: onClose)
                Text(engine.currentTitle.isEmpty ? "SpeakIt" : engine.currentTitle)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.7))
                    .lineLimit(1)
                Spacer()
                HoverChip(symbol: "minus", action: onCollapse)
            }
            .padding(.horizontal, 8)
            .padding(.top, 4)

            TranscriptView(
                text: engine.currentText,
                highlight: engine.highlightRange,
                onTapSentence: { range in engine.seekToCharacter(range.location) }
            )
                .frame(maxWidth: .infinity, maxHeight: .infinity)

            ExpandedBar(
                engine: engine,
                window: window,
                onCollapse: onCollapse,
                onClose: onClose,
                embedded: true
            )
            .frame(height: 56)
        }
        .background(
            LinearGradient(
                colors: [Color(red: 0.14, green: 0.14, blue: 0.15),
                         Color(red: 0.08, green: 0.08, blue: 0.09)],
                startPoint: .top, endPoint: .bottom
            )
        )
        .clipShape(RoundedRectangle(cornerRadius: 15, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 15, style: .continuous)
                .strokeBorder(.white.opacity(0.10), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.35), radius: 10, y: 4)
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
                            .foregroundStyle(isActive(s.range) ? Color.white : Color.white.opacity(0.45))
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(
                                RoundedRectangle(cornerRadius: 5)
                                    .fill(isActive(s.range) ? Color.white.opacity(0.14) : .clear)
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
