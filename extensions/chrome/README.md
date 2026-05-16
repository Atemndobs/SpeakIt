# SpeakIt — Chrome extension

Adds two ways to hand selected text to the SpeakIt macOS app:

1. **Right-click → "Speak with SpeakIt"** — always available.
2. **Auto-speak on selection** — optional toggle in the toolbar popup.

Both call the `speakit://speak?text=...` URL scheme, which the SpeakIt app
registers on first launch.

## Install (unpacked)

1. Build & launch the SpeakIt app at least once so macOS registers the URL
   scheme:
   ```bash
   ./scripts/build-app.sh
   open ~/Applications/SpeakIt.app
   ```
2. In Chrome: `chrome://extensions` → enable **Developer mode** →
   **Load unpacked** → pick this `extensions/chrome` directory.
3. First time you trigger it, Chrome will ask whether to allow opening
   `speakit://` links. Accept and tick "remember".

## How it works

- `background.js` registers the context-menu item and listens for selection
  events from the content script.
- `content.js` watches `mouseup` / `keyup` and reports finished selections.
- The background worker injects an `<a href="speakit://…">` into the page
  and clicks it — this hands the URL to macOS without navigating the tab.
- The SpeakIt app's `URLSchemeHandler` decodes the `text` query param and
  passes it to the TTS engine.

## Limits

- Long selections are truncated to 4000 characters (URL length safety).
  For full-document reading, use the right-click → Services menu instead,
  which has no length limit.
- Works in any Chromium-based browser (Chrome, Edge, Brave, Arc). For
  Safari, a Safari Web Extension would need to be built separately.
