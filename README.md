# SpeakIt

System-wide macOS text-to-speech menu-bar app. Hit a hotkey, hear the current selection. A floating bubble appears near your cursor with play/pause/stop.

## Install

```bash
brew tap Atemndobs/speakit https://github.com/Atemndobs/SpeakIt
brew install --cask speakit
open -a SpeakIt   # grant Accessibility, relaunch
```

Pre-built `.app`, no Xcode required. Or build from source — see [Run from source](#run-dev--hotkey--bubble-only-no-services-menu) below.

## Claude Code integration

Hear every Claude Code response aloud, plus `/speak`, `/speak-file`, `/speak-stop` slash commands. See [claude-speak/](claude-speak/).

```
/plugin marketplace add Atemndobs/SpeakIt
/plugin install claude-speak
```

## v0.2 — what works
- Menu-bar app (no Dock icon)
- Global hotkey (default **⌃⌘S**) → captures current selection → speaks it
- Floating bubble near cursor with pause/stop
- **Two engines:** Apple Speech (offline) + Microsoft Edge Neural (online, free, higher quality)
- Voice picker per engine
- Speed slider
- Provider abstraction (next: ElevenLabs / OpenAI as paid options)

### Note on hotkeys
The `fn` key is intercepted by macOS at a level below standard global hotkey APIs, so combos like `fn+⌘+S` aren't possible without a CGEventTap (intrusive, extra permissions). Default is `⌃⌘S`; rebind to anything you like from the menu bar.

## Prerequisites
1. **macOS 14+** (Sonoma, Sequoia)
2. **Xcode Command Line Tools**: `xcode-select --install`
3. **Premium voice installed** (for Apple Speech engine): System Settings → Accessibility → Spoken Content → System Voice → Manage Voices → download **Ava (Premium)**
4. **edge-tts** (for Edge engine): `brew install pipx && pipx install edge-tts`

## Run (dev — hotkey + bubble only, no Services menu)
```bash
cd ~/sites/SpeakIt
swift run
```

## Install as .app (enables the macOS Services menu)
```bash
cd ~/sites/SpeakIt
./scripts/build-app.sh
open ~/Applications/SpeakIt.app
```
This builds release, assembles `~/Applications/SpeakIt.app`, ad-hoc signs it, and registers with Launch Services. After launching once, **right-click any selected text anywhere in macOS → Services → "Speak with SpeakIt"**.

Services indexing is async — if the menu item doesn't appear right away, wait a few seconds, or check System Settings → Keyboard → Keyboard Shortcuts → Services → Text. Last resort: log out / log in.

First launch:
1. macOS will prompt for **Accessibility permission** — required for the global hotkey and selection capture. Toggle SpeakIt ON in System Settings → Privacy & Security → Accessibility.
2. Quit (`Ctrl+C` in terminal or click "Quit SpeakIt" in the menu bar) and `swift run` again.

## Use
1. Select text anywhere
2. Press `⌥⌘S`
3. A bubble appears near your cursor; the voice starts speaking
4. Click pause/stop on the bubble, or use the menu bar item

## Architecture
```
SpeakItApp.swift          — @main + MenuBarExtra scene
AppDelegate.swift         — lifecycle, hotkey registration, AX prompt
TTSProvider.swift         — protocol (so we can add Edge TTS, ElevenLabs, etc.)
AVSpeechProvider.swift    — Apple AVSpeechSynthesizer adapter
TTSEngine.swift           — singleton state, current provider, voice, rate
SelectionReader.swift     — sends ⌘C, reads pasteboard, restores
BubbleWindow.swift        — floating NSPanel near cursor
MenuBarView.swift         — SwiftUI menu bar dropdown
AccessibilityPermission.swift — TCC helpers
```

## Roadmap
- **v0.3** Selection-anchored bubble via AX `AXBoundsForRange` (Apple Translate style)
- **v0.3** Sentence-level highlighting (karaoke mode)
- **v0.4** Streaming Edge TTS playback (currently buffers full audio before playing)
- **v0.4** Bundling as `.app` + DMG + notarization

## Known limitations
- Selection capture uses synthetic ⌘C — won't work in apps that block paste (rare). Falls back silently.
- Siri voices (best Apple ships) are **not** exposed to `AVSpeechSynthesizer` — system limitation. We use Premium voices, which are the next tier and still very good.
- TCC permissions bind to binary path. If you move the build output, you'll be re-prompted.
