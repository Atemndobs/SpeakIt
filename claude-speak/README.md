# claude-speak

Hear Claude Code responses aloud, via [SpeakIt](https://github.com/Atemndobs/SpeakIt) — a native macOS TTS app with high-quality voices and continuous playback.

- `/speak <text>` — speak arbitrary text
- `/speak-file <path>` — speak the contents of a file
- `/speak-stop` — halt playback
- **Stop hook** — auto-reads every Claude response (toggle via `CLAUDE_SPEAK=0`)

## Prerequisites

1. **macOS 14+** (Sonoma or later)
2. **SpeakIt.app** installed and running — `brew install Atemndobs/SpeakIt/speakit` or build from source at [github.com/Atemndobs/SpeakIt](https://github.com/Atemndobs/SpeakIt)
3. **Claude Code** with plugin support

## Install

```
/plugin marketplace add Atemndobs/SpeakIt
/plugin install claude-speak
```

That registers the slash commands and the Stop hook. SpeakIt.app needs to be running for any of it to do anything.

## Toggle auto-read

The Stop hook is on by default. To silence it for a session:

```bash
export CLAUDE_SPEAK=0
```

Or remove the plugin entirely with `/plugin uninstall claude-speak`.

## How it works

Everything is a thin wrapper around SpeakIt's `speakit://` URL scheme. The Stop hook reads the last assistant message from your Claude Code transcript, strips markdown so the voice doesn't say "asterisk asterisk", URL-encodes the text, and opens `speakit://speak?text=...`. The slash commands do the same for ad-hoc text or files.

No network, no API keys, no data leaves your Mac.

## Troubleshooting

- **Nothing happens** — confirm SpeakIt.app is running. Try `open "speakit://speak?text=hello"` in Terminal.
- **It speaks the markdown literally** — open an issue with a sample of the response that broke the stripper.
- **Long responses get cut off** — macOS has a URL-length limit (~64KB). For huge replies, prefer `/speak-file` against a saved transcript.

## License

MIT
