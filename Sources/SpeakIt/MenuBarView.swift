import SwiftUI
import AVFoundation
import KeyboardShortcuts

struct MenuBarView: View {
    @EnvironmentObject var engine: TTSEngine
    @ObservedObject private var bubble = BubbleWindow.shared
    @ObservedObject private var loginItem = LoginItem.shared
    @ObservedObject private var server = LocalFileServer.shared
    @ObservedObject private var llm = LLMSettings.shared
    @AppStorage(HoverSpeakButton.autoShowKey) private var autoShowOnSelection: Bool = false
    @AppStorage(ClipboardWatcher.Keys.enabled) private var speakOnCopy: Bool = false

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

            Picker("Engine", selection: Binding(
                get: { engine.activeProviderId },
                set: { engine.switchProvider(to: $0) }
            )) {
                ForEach(engine.providers, id: \.id) { p in
                    Text(p.displayName).tag(p.id)
                }
            }
            .pickerStyle(.menu)

            if let provider = engine.activeProvider {
                Picker("Voice", selection: $engine.selectedVoiceId) {
                    ForEach(provider.availableVoices) { v in
                        Text("\(v.name) — \(v.quality)").tag(Optional(v.id))
                    }
                }
                .pickerStyle(.menu)
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Speed").font(.caption).foregroundStyle(.secondary)
                Slider(
                    value: $engine.rate,
                    in: AVSpeechUtteranceMinimumSpeechRate...AVSpeechUtteranceMaximumSpeechRate
                )
            }

            Divider()

            HStack {
                Text("Hotkey").font(.caption).foregroundStyle(.secondary)
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

            Toggle("Show play button on selection", isOn: $autoShowOnSelection)
                .toggleStyle(.switch)
                .controlSize(.small)

            Toggle("Speak copies from Claude", isOn: Binding(
                get: { speakOnCopy },
                set: { speakOnCopy = $0; ClipboardWatcher.shared.isEnabled = $0 }
            ))
                .toggleStyle(.switch)
                .controlSize(.small)

            Divider()

            LocalServerSection(server: server)

            Divider()

            ReaderAISection(llm: llm)

            Divider()

            Toggle("Start at Login", isOn: Binding(
                get: { loginItem.isEnabled },
                set: { loginItem.setEnabled($0) }
            ))
            .toggleStyle(.switch)
            .controlSize(.small)

            Divider()

            Button("Quit SpeakIt") { NSApp.terminate(nil) }
                .keyboardShortcut("q")
        }
        .padding(14)
        .frame(width: 320)
    }
}

private struct LocalServerSection: View {
    @ObservedObject var server: LocalFileServer

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Local file server").font(.caption).foregroundStyle(.secondary)
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
                            Text(share.name)
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

            Picker("Bind", selection: $server.bindMode) {
                ForEach(LocalFileServer.BindMode.allCases) { mode in
                    Text(mode.label).tag(mode)
                }
            }
            .pickerStyle(.menu)
            .controlSize(.small)
            .padding(.top, 2)

            if server.bindMode == .tailnet {
                Toggle("Use Tailscale HTTPS (proxy :443)", isOn: $server.tailscaleHTTPS)
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

private struct ReaderAISection: View {
    @ObservedObject var llm: LLMSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Reader AI search").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if llm.enabled {
                    Circle().fill(.green).frame(width: 6, height: 6)
                }
            }

            Toggle("Enable Ask AI in reader", isOn: $llm.enabled)
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
