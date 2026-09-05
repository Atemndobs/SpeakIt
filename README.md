# SpeakIt

System-wide macOS text-to-speech menu-bar app. Hit a hotkey, hear the current selection. A floating bubble appears near your cursor with play/pause/stop. Also reads Claude Code responses aloud and speaks the contents of the clipboard when you copy from Claude desktop.

---

## Quick install (recommended)

```bash
brew tap Atemndobs/speakit https://github.com/Atemndobs/SpeakIt
brew install --cask speakit
open -a SpeakIt
```

That single tap-then-install pulls a pre-built universal `.app`, installs `pipx`, runs `pipx install edge-tts` for the neural voices, and registers the binary with Launch Services. **No Xcode required.**

First launch checklist:
1. **Right-click** SpeakIt in `/Applications` → **Open** → confirm. One-time Gatekeeper bypass (app is signed ad-hoc, not yet Apple-notarized).
2. macOS will ask for **Accessibility permission** → System Settings → Privacy & Security → Accessibility → enable **SpeakIt**.
3. Quit (menu bar icon → Quit SpeakIt) and relaunch once.

Test it: select text anywhere → press **⌃⌘S** → you should hear it.

---

## Supported platforms

| Architecture | Status | Notes |
| --- | --- | --- |
| Apple Silicon (arm64, M1/M2/M3/M4) | ✅ Supported | Native, primary dev target |
| Intel (x86_64) | ✅ Supported | Universal binary since v0.2.1 |

**OS:** macOS 14 (Sonoma) or later. macOS 13 and below are unsupported.

The `.app` is shipped as a universal binary; `lipo -info /Applications/SpeakIt.app/Contents/MacOS/SpeakIt` should report `x86_64 arm64`.

---

## What gets installed

| Component | Source | Why |
| --- | --- | --- |
| `SpeakIt.app` → `/Applications/` | [GitHub release zip](https://github.com/Atemndobs/SpeakIt/releases/latest) | The app itself |
| `pipx` (Homebrew formula) | brew | To install edge-tts |
| `edge-tts` (Python package) | pipx | Free, high-quality Microsoft Edge Neural voices |

If you prefer the offline Apple Speech engine only, edge-tts is harmless to leave installed but unused. To skip it entirely, install from source instead (next section).

---

## Install from source

For contributors, or if you don't want pipx/edge-tts on your machine.

**Prerequisites:**
- macOS 14+
- Xcode Command Line Tools: `xcode-select --install`
- Optional: `brew install pipx && pipx install edge-tts` for neural voices

**Build & install the `.app`:**
```bash
git clone https://github.com/Atemndobs/SpeakIt.git
cd SpeakIt
./scripts/build-app.sh
open ~/Applications/SpeakIt.app
```

This produces a universal `.app` under `~/Applications/SpeakIt.app`, ad-hoc signed and registered with Launch Services. The build invokes `swift build -c release --arch arm64 --arch x86_64` and copies SwiftPM resource bundles into the bundle so `Bundle.module` resolves on both architectures.

**Run in dev mode (no `.app`, no Services menu):**
```bash
swift run
```

---

## Claude Code integration

Once SpeakIt.app is installed and running, install the Claude Code plugin:

```
/plugin marketplace add Atemndobs/SpeakIt
/plugin install claude-speak
/reload-plugins
```

That registers:
- `/speak <text>` — speak arbitrary text
- `/speak-file <path>` — speak a file's contents
- `/speak-stop` — halt playback
- Stop hook — auto-reads every Claude Code response

Plugin source lives at [claude-speak/](claude-speak/). To disable auto-read without uninstalling: `export CLAUDE_SPEAK=0`.

In the SpeakIt menu bar dropdown, toggle **"Speak copies from Claude"** ON to also speak whatever you copy from the Claude desktop app (`com.anthropic.claudefordesktop`).

---

## v0.2 — what works
- Menu-bar app (no Dock icon)
- Global hotkey (default **⌃⌘S**) → captures current selection → speaks it
- Floating bubble near cursor with pause/stop
- **Four engines:** Apple Speech (offline) + Microsoft Edge Neural (online, free) + Kokoro-82M (offline, free, neural) + ElevenLabs (online, paid, highest quality)
- Voice picker per engine, speed slider
- Provider abstraction (next: OpenAI as a further paid option)
- Claude Code plugin (`claude-speak`) — auto-read Stop hook + slash commands
- Speak-on-copy from Claude desktop app
- Chrome extension speaker button on `claude.ai` / `claude.com`

### Note on hotkeys
The `fn` key is intercepted by macOS at a level below standard global hotkey APIs, so combos like `fn+⌘+S` aren't possible without a CGEventTap (intrusive, extra permissions). Default is `⌃⌘S`; rebind from the menu bar.

---

## Use
1. Select text anywhere
2. Press `⌃⌘S`
3. A bubble appears near your cursor; the voice starts speaking
4. Click pause/stop on the bubble, or use the menu bar item

For the macOS Services menu entry: right-click selected text → Services → **"Speak with SpeakIt"**. Services indexing is async — if the menu item doesn't appear right away, wait a few seconds, or check System Settings → Keyboard → Keyboard Shortcuts → Services → Text.

---

## Kokoro (local neural voices)

A neural engine that runs entirely on your machine. No network, no API key, no
per-character cost. Useful when you are offline, when you would rather not send
your agent's output to Microsoft or ElevenLabs, or when you just want better
voices than Apple's without paying for them.

```bash
./scripts/kokoro-setup.sh
```

That creates a private virtualenv under `~/.speakit/kokoro`, downloads the
model and voice pack (about 350 MB), and verifies synthesis works. Nothing is
installed system-wide, so removing that one directory undoes all of it. Then
set **Engine** to Kokoro (Local) in the menu bar.

Pass `--int8` instead for a smaller, faster, slightly lower quality model
(114 MB), which is worth it on an older Mac.

### Speed

Measured on an M3 Max with the default fp32 weights:

| | |
|---|---|
| Real-time factor | 0.155, about 5x faster than playback |
| Model load | 0.57 s, once per app launch |
| Voices | 54, across 9 languages |

The model is loaded once by a background daemon and stays resident, so only
the first read of a session pays the load. Sentences are synthesized ahead of
playback, which is why audio starts before the whole passage is rendered.

**It has no German voices.** Kokoro covers American and British English,
Spanish, French, Hindi, Italian, Japanese, Portuguese and Mandarin. For German,
stay on Edge Neural.

### Why not VoxCPM or a larger model

VoxCPM sounds excellent and can clone a voice, but its own benchmarks put it at
a real-time factor of about 1.76 on Apple silicon, meaning it renders slower
than it plays. For a reader that should start talking the moment an agent
finishes, that is disqualifying regardless of quality. Kokoro is roughly eleven
times faster on the same class of hardware.

## ElevenLabs

The highest-quality engine, and the only paid one. Apple Speech is free and
offline, Edge Neural is free and online, ElevenLabs bills per character.

### Setup

1. Get a key at [elevenlabs.io/app/settings/api-keys](https://elevenlabs.io/app/settings/api-keys).
2. Menu bar, set **Engine** to ElevenLabs.
3. Paste the key and press **Save key**.

The key goes into the **macOS Keychain**, not `UserDefaults`. It is a bearer
credential that bills money, and a preferences plist is world-readable to
anything running as your user.

After saving, the panel validates the key, loads your voice catalogue and shows
the remaining character quota. Your own cloned and professional voices sort to
the top of the picker.

### What is different from the free engines

**It costs money per sentence**, so synthesis runs at most three sentences ahead
of playback. Without that cap, pressing play on a long article would bill the
whole thing immediately, including the part you skip. Seeking backwards also
keeps audio already paid for rather than re-synthesizing it.

**There is no speaking-rate parameter** in the API, unlike `edge-tts` where rate
is baked into synthesis. Speed is applied at playback instead. The slider
midpoint maps to exactly 1.0x, which `PlaybackRateTests` guards, because
everyone leaves it there.

**Failures are distinguished.** A rejected key or an exhausted quota stops the
read immediately rather than failing once per sentence and leaving you with
silence and no explanation. A 500 or a rate limit is retryable and behaves that
way. The reason is shown in the menu bar.

### Development

`ElevenLabsKit` is a separate library target holding the client, models,
Keychain storage and rate mapping. SpeakIt is an `@main` executable and
executables are awkward to import from a test target, so the testable half lives
outside the app.

```bash
swift test                                        # 37 tests, network stubbed
ELEVENLABS_API_KEY=xi-... swift test --filter LiveAPITests   # 4 real API calls
```

The live tests skip unless the key is set. They exist because a stubbed client
only proves the code matches my belief about the API, not that the belief is
right. `testLiveSynthesisReturnsPlayableMP3` checks the MP3 frame header rather
than just a byte count, since a JSON error body can arrive with a 200, and it
writes the audio to a temp file so it can actually be listened to.

---

## Source layout

```
SpeakItApp.swift          — @main + MenuBarExtra scene
AppDelegate.swift         — lifecycle, hotkey registration, AX prompt
TTSProvider.swift         — protocol (so we can add Edge TTS, ElevenLabs, etc.)
AVSpeechProvider.swift    — Apple AVSpeechSynthesizer adapter
EdgeTTSProvider.swift     — Microsoft Edge Neural via edge-tts CLI
KokoroProvider.swift      : Kokoro-82M, local ONNX via a resident daemon
ElevenLabsProvider.swift  : ElevenLabs, sentence-queued streaming synthesis
TTSEngine.swift           — singleton state, current provider, voice, rate
SelectionReader.swift     — sends ⌘C, reads pasteboard, restores
BubbleWindow.swift        — floating NSPanel near cursor
MenuBarView.swift         — SwiftUI menu bar dropdown
ClipboardWatcher.swift    — speak Claude desktop copies (10Hz pasteboard poll)
URLSchemeHandler.swift    — speakit:// URL routes
LocalFileServer.swift     — optional HTTP file server (Tailscale-friendly)
AccessibilityPermission.swift — TCC helpers
```

Other directories:
- `claude-speak/` — Claude Code plugin (manifest, hooks, commands)
- `Casks/speakit.rb` — Homebrew cask formula
- `extensions/chrome/` — Chrome extension (context-menu + speaker button on Claude)
- `scripts/build-app.sh` — universal-binary build & assemble
- `scripts/release.sh` — bump version, build, zip, GitHub release, update cask

---

## Roadmap
- **v0.3** Selection-anchored bubble via AX `AXBoundsForRange` (Apple Translate style)
- **v0.3** Sentence-level highlighting (karaoke mode)
- **v0.4** Streaming Edge TTS playback (currently buffers full audio before playing)
- **v0.4** Developer ID signing + notarization (removes the right-click-Open dance)

---

## Known limitations
- App is signed ad-hoc, not notarized — first launch needs right-click → Open.
- Selection capture uses synthetic ⌘C — won't work in apps that block paste (rare). Falls back silently.
- Siri voices (best Apple ships) are **not** exposed to `AVSpeechSynthesizer` — system limitation. We use Premium voices, which are the next tier and still very good.
- TCC permissions bind to binary path. If you move the build output, you'll be re-prompted.
- Claude Code plugin command-loading occasionally requires a `/reload-plugins` or session restart to register commands.

---

## License

MIT — see [LICENSE](LICENSE).
