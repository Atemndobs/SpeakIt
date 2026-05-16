// Service worker: registers the right-click menu item and forwards selected
// text to SpeakIt via the speakit:// URL scheme.

const MENU_ID = "speakit-speak-selection";
// URL length safety margin — most macOS URL handlers comfortably accept
// several KB; we cap to keep things sane. Long selections are truncated.
const MAX_TEXT_LEN = 4000;

chrome.runtime.onInstalled.addListener(() => {
  chrome.contextMenus.create({
    id: MENU_ID,
    title: "Speak with SpeakIt",
    contexts: ["selection"],
  });
});

chrome.contextMenus.onClicked.addListener((info, tab) => {
  if (info.menuItemId !== MENU_ID) return;
  const text = (info.selectionText || "").trim();
  if (!text || !tab) return;
  invokeSpeakIt(tab, text);
});

// Chrome forbids scripting on its own pages — bail before we get an error.
function isRestrictedUrl(url) {
  if (!url) return true;
  return (
    url.startsWith("chrome://") ||
    url.startsWith("chrome-extension://") ||
    url.startsWith("chrome-untrusted://") ||
    url.startsWith("edge://") ||
    url.startsWith("about:") ||
    url.startsWith("devtools://") ||
    url.startsWith("view-source:") ||
    url.startsWith("https://chromewebstore.google.com") ||
    url.startsWith("https://chrome.google.com/webstore")
  );
}

function invokeSpeakIt(tab, text) {
  if (!tab?.id || isRestrictedUrl(tab.url)) return;

  const clipped = text.length > MAX_TEXT_LEN ? text.slice(0, MAX_TEXT_LEN) : text;
  const url = `speakit://speak?text=${encodeURIComponent(clipped)}`;

  // Trigger the external protocol via an anchor click in the page, so we
  // don't navigate the current tab. Chrome will hand the URL to macOS,
  // which launches SpeakIt (or focuses it if running).
  chrome.scripting
    .executeScript({
      target: { tabId: tab.id },
      func: (u) => {
        const a = document.createElement("a");
        a.href = u;
        a.rel = "noopener";
        a.style.display = "none";
        document.body.appendChild(a);
        a.click();
        a.remove();
      },
      args: [url],
    })
    .catch((err) => console.warn("[SpeakIt] injection failed:", err));
}

// Content scripts forward two message types:
//   - "speakit:selection" — auto-popup on text selection (gated by user toggle)
//   - "speakit:speak"     — explicit click on an injected speaker button (always fires)
chrome.runtime.onMessage.addListener((msg, sender) => {
  const tab = sender?.tab;
  if (!tab?.id || !msg?.text) return;

  if (msg.type === "speakit:speak") {
    invokeSpeakIt(tab, msg.text);
    return;
  }

  if (msg.type === "speakit:selection") {
    chrome.storage.sync.get({ autoSpeak: false }, ({ autoSpeak }) => {
      if (autoSpeak) invokeSpeakIt(tab, msg.text);
    });
  }
});
