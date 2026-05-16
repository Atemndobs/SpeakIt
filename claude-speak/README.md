# claude-speak

**Hear Claude Code talk back.** Every assistant response is spoken aloud automatically via [SpeakIt](https://github.com/Atemndobs/SpeakIt) — a native macOS TTS app with high-quality voices and continuous playback.

No copying, no clicking — just type, send, listen. Hands-free Claude Code while you cook, walk, or stare at the wall.

## What you get

- **Auto-read Stop hook** — speaks every Claude response as soon as it finishes generating. The whole point of this plugin.
- **Markdown stripping** — code fences, bullets, tables, asterisks, links: all stripped before TTS so you hear prose, not punctuation.
- **Toggle off without uninstalling** — `export CLAUDE_SPEAK=0` in any session.

## Prerequisites

1. **macOS 14+** (Sonoma or later)
2. **SpeakIt.app** installed and running:
   ```bash
   brew tap Atemndobs/speakit https://github.com/Atemndobs/SpeakIt
   brew install --cask speakit
   open -a SpeakIt
   ```
3. **Claude Code**

## Install

```
/plugin marketplace add Atemndobs/SpeakIt
/plugin install claude-speak
/reload-plugins
```

That's it. The next response Claude generates will be read aloud.

## How it works

A Stop hook fires when Claude finishes a turn. It reads the last assistant message from your Claude Code transcript, strips markdown (code fences, headers, bullets, bold, italic, links, tables), URL-encodes the plain text, and opens `speakit://speak?text=...` to hand it to SpeakIt.

No network, no API keys, no data leaves your Mac.

## Toggle auto-read

The hook fires every turn. Silence it for a session:
```bash
export CLAUDE_SPEAK=0
```

Or remove it entirely with `/plugin uninstall claude-speak`.

## Minor utilities

Three slash commands are bundled but you'll rarely use them — the Stop hook covers the main case. They exist for the edge cases:

- `/speak <text>` — speak arbitrary text. Useful if you want SpeakIt to say something *outside* of a Claude response.
- `/speak-file <path>` — read a file aloud. Or just select-all in any editor and hit ⌃⌘S, same thing.
- `/speak-stop` — halt playback mid-sentence. Also achievable by clicking the floating bubble or menu bar dropdown.

## Beyond the plugin

SpeakIt does more than read Claude Code responses:

- **⌃⌘S** anywhere on macOS — speak the current selection
- **Menu bar → "Speak copies from Claude"** — speaks whatever you copy from the Claude *desktop* app
- **Chrome extension** — adds a speaker button next to Copy on claude.ai / claude.com

See the [main README](https://github.com/Atemndobs/SpeakIt) for those.

## Troubleshooting

- **Nothing happens** — confirm SpeakIt.app is running (look for the menu bar icon). Test directly with `open "speakit://speak?text=hello"` in Terminal.
- **It speaks markdown literally** — open an issue with a sample of the response that broke the stripper.
- **Long responses get cut off** — macOS URL-length limit (~64KB). For huge replies, save and use `/speak-file`.
- **Plugin commands say "Unknown skill"** — run `/reload-plugins` or restart your Claude Code session.

## License

MIT
