import ElevenLabsKit
import SwiftUI
import AVFoundation
import KeyboardShortcuts
import UniformTypeIdentifiers

struct MenuBarView: View {
    @EnvironmentObject var engine: TTSEngine
    @ObservedObject private var bubble = BubbleWindow.shared
    @ObservedObject private var loginItem = LoginItem.shared
    @ObservedObject private var server = LocalFileServer.shared
    @ObservedObject private var llm = LLMSettings.shared
    @AppStorage(HoverSpeakButton.autoShowKey) private var autoShowOnSelection: Bool = false
    @AppStorage(ClipboardWatcher.Keys.enabled) private var speakOnCopy: Bool = false
    @AppStorage(AutoSpeechSettings.Keys.claudeCodeEnabled) private var speakClaudeResponses: Bool = false
    @AppStorage(CodexTranscriptWatcher.Keys.enabled) private var speakCodexResponses: Bool = false
    @AppStorage(VoiceAvatarStore.Keys.mode) private var avatarMode: String = VoiceAvatarStore.modePhoto
    @AppStorage(VoiceAvatarStore.Keys.style) private var avatarStyle: String = VoiceAvatarStore.defaultStyle

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("SpeakIt").font(.headline)
                Spacer()
                if engine.isSpeaking {
                    Image(systemName: "waveform").foregroundStyle(.tint)
                }
            }

            Divider()

            HStack(spacing: 8) {
                Button { engine.togglePause() } label: {
                    Image(systemName: engine.isPaused ? "play.fill" : "pause.fill")
                }
                .disabled(!engine.isSpeaking && !engine.isPaused)

                Button { engine.stop() } label: {
                    Image(systemName: "stop.fill")
                }
                .disabled(!engine.isSpeaking && !engine.isPaused)

                Spacer()

                if (engine.isSpeaking || engine.isPaused) && !bubble.isVisible {
                    Button("Show Player") {
                        BubbleWindow.shared.show()
                    }
                    .controlSize(.small)
                }
            }

            Picker(selection: Binding(
                get: { engine.activeProviderId },
                set: { engine.switchProvider(to: $0) }
            )) {
                ForEach(engine.providers, id: \.id) { p in
                    EngineLabel(providerId: p.id, title: p.displayName).tag(p.id)
                }
            } label: {
                Label("Engine", systemImage: "cpu")
            }
            .pickerStyle(.menu)

            if let provider = engine.activeProvider {
                Picker(selection: $engine.selectedVoiceId) {
                    ForEach(provider.availableVoices) { v in
                        // Middle dot, not a dash. Several voice names already
                        // carry parentheses ("Ava (Multilingual)"), so a
                        // parenthetical quality would nest awkwardly.
                        Text("\(v.name) · \(v.quality)").tag(Optional(v.id))
                    }
                } label: {
                    Label("Voice", systemImage: "person.wave.2")
                }
                .pickerStyle(.menu)

                Picker(selection: $avatarMode) {
                    Label("Photos", systemImage: "photo").tag(VoiceAvatarStore.modePhoto)
                    Label("Illustrated", systemImage: "paintpalette").tag(VoiceAvatarStore.modeGenerated)
                    Label("Logos only", systemImage: "square.on.square").tag(VoiceAvatarStore.modeLogo)
                } label: {
                    Label("Avatar", systemImage: "person.crop.square")
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: avatarMode) { _, _ in VoiceAvatarStore.shared.refresh() }

                if avatarMode == VoiceAvatarStore.modePhoto {
                    HStack(spacing: 6) {
                        Button {
                            pickAvatarForCurrentVoice()
                        } label: {
                            Label("Set voice avatar…", systemImage: "person.crop.circle.badge.plus")
                        }
                        .controlSize(.small)
                        .disabled(engine.selectedVoiceId == nil)

                        Button {
                            NSWorkspace.shared.open(VoiceAvatarStore.shared.directory)
                        } label: {
                            Image(systemName: "folder")
                        }
                        .controlSize(.small)
                        .help("Open the avatars folder")
                    }
                }

                if avatarMode != VoiceAvatarStore.modeLogo {
                    HStack(spacing: 6) {
                        Picker("Style", selection: $avatarStyle) {
                            ForEach(VoiceAvatarStore.styles, id: \.self) { Text($0).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .onChange(of: avatarStyle) { _, _ in VoiceAvatarStore.shared.refresh() }

                        Button {
                            VoiceAvatarStore.shared.regenerate()
                        } label: {
                            Image(systemName: "arrow.clockwise")
                        }
                        .controlSize(.small)
                        .help("Re-generate illustrated avatars")
                    }
                }
            }

            if engine.activeProviderId == "elevenlabs", let eleven = engine.elevenLabs {
                ElevenLabsSection(engine: engine, provider: eleven)
            }

            if engine.activeProviderId == "kokoro", let kokoro = engine.kokoro {
                KokoroSection(provider: kokoro)
            }

            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Label("Speed", systemImage: "gauge").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Text(speedLabel)
                        .font(.caption)
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                Slider(
                    value: $engine.rate,
                    in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                )
            }

            Divider()

            HStack {
                Label("Hotkey", systemImage: "keyboard").font(.caption).foregroundStyle(.secondary)
                Spacer()
                KeyboardShortcuts.Recorder(for: .speakSelection)
            }

            if !AccessibilityPermission.check(prompt: false) {
                Button("Grant Accessibility Permission…") {
                    AccessibilityPermission.openSettings()
                }
                .foregroundStyle(.orange)
            }

            Divider()

            Toggle(isOn: $autoShowOnSelection) {
                Label("Show play button on selection", systemImage: "cursorarrow.rays")
            }
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle(isOn: $speakClaudeResponses) {
                BrandLabel(title: "Speak Claude Code responses",
                           bundleIDs: BrandIcon.Brand.claude, symbol: "terminal")
            }
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle(isOn: Binding(
                get: { speakOnCopy },
                set: { speakOnCopy = $0; ClipboardWatcher.shared.isEnabled = $0 }
            )) {
                // Two products share this row, so the clipboard is the honest
                // icon here rather than picking one brand over the other.
                Label("Speak copied text (Claude, Codex)", systemImage: "doc.on.clipboard")
            }
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle(isOn: Binding(
                get: { speakCodexResponses },
                set: { speakCodexResponses = $0; CodexTranscriptWatcher.shared.isEnabled = $0 }
            )) {
                BrandLabel(title: "Speak Codex final responses",
                           bundleIDs: BrandIcon.Brand.openAI,
                           symbol: "chevron.left.forwardslash.chevron.right")
            }
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            LocalServerSection(server: server)

            Divider()

            ReaderAISection(llm: llm)

            Divider()

            Toggle(isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            )) {
                Label("Start at Login", systemImage: "power")
            }
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            Button { NSApp.terminate(nil) } label: {
                Label("Quit SpeakIt", systemImage: "xmark.circle")
            }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }

    /// Speed shown as a multiplier and a percentage, relative to normal
    /// (the default rate = 1.0× = 100%).
    private var speedLabel: String {
        let mult = Double(engine.rate / AVSpeechUtteranceDefaultSpeechRate)
        let pct = Int((mult * 100).rounded())
        return String(format: "%.1f×  ·  %d%%", mult, pct)
    }

    /// Pick an image and install it as the avatar for the current voice.
    private func pickAvatarForCurrentVoice() {
        guard let voiceId = engine.selectedVoiceId else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.image]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "Use as avatar"
        panel.message = "Choose an image for this voice"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? VoiceAvatarStore.shared.install(
            from: url, providerId: engine.activeProviderId, voiceId: voiceId)
    }
}

private struct LocalServerSection: View {
    @ObservedObject var server: LocalFileServer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Local file server", systemImage: "server.rack")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if server.isRunning {
                    Circle().fill(.green).frame(width: 6, height: 6)
                    Text("localhost:\(server.port)").font(.caption2).foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 6) {
                Toggle(isOn: Binding(
                    get: { server.isRunning },
                    set: { _ in server.toggle() }
                )) {
                    Text(server.isRunning ? "Running" : "Off")
                }
                .toggleStyle(.switch)
                .controlSize(.small)

                Spacer()

                if server.isRunning {
                    Button("Open") { server.openInBrowser() }
                        .controlSize(.small)
                }
            }

            if !server.shares.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(server.shares) { share in
                        HStack(spacing: 4) {
                            Label(share.name, systemImage: "folder")
                                .font(.caption)
                                .lineLimit(1)
                            Spacer()
                            Button {
                                server.removeShare(share.id)
                            } label: {
                                Image(systemName: "minus.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                            .help(share.path)
                        }
                    }
                }
                .padding(.top, 2)
            }

            Button {
                server.pickAndAddShare()
            } label: {
                Label("Add Folder…", systemImage: "plus")
            }
            .controlSize(.small)

            Picker(selection: $server.bindMode) {
                ForEach(LocalFileServer.BindMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            } label: {
                Label("Bind", systemImage: "network")
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .padding(.top, 2)

            if server.bindMode == .tailnet {
                Toggle(isOn: $server.tailscaleHTTPS) {
                    BrandLabel(title: "Use Tailscale HTTPS (proxy :443)",
                               bundleIDs: BrandIcon.Brand.tailscale, symbol: "lock.shield")
                }
                    .toggleStyle(.switch)
                    .controlSize(.small)
                if let err = server.lastTailscaleError, !err.isEmpty {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if server.isRunning && server.bindMode != .localhost {
                RemoteAccessRow(server: server)
            }

            if server.bindMode == .lan {
                Text("⚠︎ Anyone on your Wi-Fi can read these folders. Prefer Tailnet.")
                    .font(.caption2)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// ElevenLabs credential and quota panel.
///
/// Only shown when ElevenLabs is the active engine. Unlike the Apple and Edge
/// providers this one needs a credential and has a metered quota, so both are
/// surfaced here rather than failing silently at playback time.
private struct ElevenLabsSection: View {
    @ObservedObject var engine: TTSEngine
    let provider: ElevenLabsProvider

    @State private var keyInput: String = ""
    @State private var status: String?
    @State private var isError = false
    @State private var busy = false
    @State private var storedMask: String? = ElevenLabsCredentials.shared.maskedKey

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("ElevenLabs").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if storedMask != nil {
                    Circle().fill(isError ? .orange : .green).frame(width: 6, height: 6)
                }
            }

            if let storedMask {
                HStack(spacing: 6) {
                    Text("Key \(storedMask)")
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                    Spacer()
                    Button("Remove") { removeKey() }
                        .controlSize(.small)
                        .disabled(busy)
                }
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    Text("API key (stored in Keychain)")
                        .font(.caption2).foregroundStyle(.secondary)
                    SecureField("xi-...", text: $keyInput)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .onSubmit { saveKey() }
                }
            }

            HStack(spacing: 6) {
                if storedMask == nil {
                    Button("Save key") { saveKey() }
                        .controlSize(.small)
                        .disabled(busy || keyInput.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } else {
                    Button("Refresh voices") { refresh() }
                        .controlSize(.small)
                        .disabled(busy)
                }
                if busy { ProgressView().controlSize(.small) }
                Spacer()
            }

            if let status {
                Text(status)
                    .font(.caption2)
                    .foregroundStyle(isError ? .orange : .secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .task {
            // Populate the quota line on first open without blocking the menu.
            if storedMask != nil, status == nil { refresh() }
        }
    }

    private func saveKey() {
        let trimmed = keyInput.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard ElevenLabsCredentials.shared.store(trimmed) else {
            status = "Could not write to the Keychain."
            isError = true
            return
        }
        keyInput = ""
        storedMask = ElevenLabsCredentials.shared.maskedKey
        refresh()
    }

    private func removeKey() {
        ElevenLabsCredentials.shared.delete()
        storedMask = nil
        status = nil
        isError = false
        Task { await engine.reloadElevenLabsVoices() }
    }

    /// Validate the key, load the catalogue and show the remaining quota.
    private func refresh() {
        busy = true
        status = nil
        Task {
            await engine.reloadElevenLabsVoices()
            busy = false
            if let error = provider.lastError {
                status = error
                isError = true
            } else {
                let count = provider.availableVoices.count
                let quota = provider.subscriptionSummary
                status = [quota, "\(count) voice\(count == 1 ? "" : "s")"]
                    .compactMap { $0 }
                    .joined(separator: " · ")
                isError = false
            }
        }
    }
}

private struct ReaderAISection: View {
    @ObservedObject var llm: LLMSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label("Reader AI search", systemImage: "sparkle.magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                if llm.enabled {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }

            Toggle(isOn: $llm.enabled) {
                Label("Enable Ask AI in reader", systemImage: "wand.and.stars")
            }
                .toggleStyle(.switch)
                .controlSize(.small)

            if llm.enabled {
                Picker("Provider", selection: $llm.provider) {
                    ForEach(LLMProvider.allCases) { p in
                        Text(p.label).tag(p)
                    }
                }
                .pickerStyle(.menu)
                .controlSize(.small)
                .onChange(of: llm.provider) { _, _ in llm.applyProviderDefaults() }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Base URL").font(.caption2).foregroundStyle(.secondary)
                    TextField("https://…", text: $llm.baseURL)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("Model").font(.caption2).foregroundStyle(.secondary)
                    TextField("model name", text: $llm.model)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                        .font(.system(size: 11, design: .monospaced))
                }

                VStack(alignment: .leading, spacing: 2) {
                    Text("API key (stored in Keychain)").font(.caption2).foregroundStyle(.secondary)
                    SecureField(llm.provider == .ollama ? "optional" : "required", text: $llm.apiKey)
                        .textFieldStyle(.roundedBorder)
                        .controlSize(.small)
                }
            }
        }
    }
}

private struct RemoteAccessRow: View {
    @ObservedObject var server: LocalFileServer
    @State private var showQR = false

    var body: some View {
        Group {
            if let url = server.primaryURLString {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        Text(url)
                            .font(.system(size: 11, design: .monospaced))
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(url, forType: .string)
                        } label: {
                            Image(systemName: "doc.on.doc")
                        }
                        .buttonStyle(.plain)
                        .help("Copy URL")
                        Button {
                            showQR.toggle()
                        } label: {
                            Image(systemName: "qrcode")
                        }
                        .buttonStyle(.plain)
                        .help("Show QR code")
                    }

                    if showQR, let qr = QRCode.generate(from: url) {
                        Image(nsImage: qr)
                            .interpolation(.none)
                            .resizable()
                            .frame(width: 160, height: 160)
                            .padding(6)
                            .background(Color.white)
                            .cornerRadius(6)
                    }
                }
            } else {
                Text(server.bindMode == .tailnet
                     ? "Tailscale not detected — is the tailnet up?"
                     : "No LAN interface detected.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }
}
