// Injects a "Speak" button next to the Copy button on every Claude assistant
// message. Click → extract message text → background worker hands it to SpeakIt.
//
// Claude's DOM shifts often, so this script is intentionally loose:
// it finds Copy buttons by aria-label/title/text, walks up to the nearest
// plausible message container, and clones styling from the Copy button so
// the new button blends in even after a redesign.
(() => {
  const MARK = "data-speakit-injected";
  const SCANNED = "data-speakit-scanned";

  const SPEAKER_SVG = `
    <svg xmlns="http://www.w3.org/2000/svg" width="16" height="16"
         viewBox="0 0 24 24" fill="none" stroke="currentColor"
         stroke-width="2" stroke-linecap="round" stroke-linejoin="round"
         aria-hidden="true">
      <polygon points="11 5 6 9 2 9 2 15 6 15 11 19 11 5"></polygon>
      <path d="M19.07 4.93a10 10 0 0 1 0 14.14"></path>
      <path d="M15.54 8.46a5 5 0 0 1 0 7.07"></path>
    </svg>`;

  function isCopyButton(btn) {
    const label = (btn.getAttribute("aria-label") || btn.getAttribute("title") || btn.textContent || "").trim();
    return /^copy\b/i.test(label) || /copy (message|response|text)/i.test(label);
  }

  function findMessageRoot(btn) {
    // Walk up looking for an element that wraps the actual response text.
    // Stop conditions: testid hint, "message" in class, <article>, or a
    // reasonably tall block with prose inside.
    let el = btn.parentElement;
    for (let i = 0; i < 12 && el; i++, el = el.parentElement) {
      const tid = el.getAttribute?.("data-testid") || "";
      const cls = el.className?.toString?.() || "";
      if (/message|assistant|response/i.test(tid)) return el;
      if (/message|markdown|prose/i.test(cls)) return el;
      if (el.tagName === "ARTICLE") return el;
    }
    return btn.closest("div");
  }

  function extractText(root) {
    if (!root) return "";
    const clone = root.cloneNode(true);
    // Strip interactive UI so we don't read "Copy Retry Good response..."
    clone.querySelectorAll('button, [role="button"], [aria-hidden="true"]').forEach((n) => n.remove());
    return (clone.innerText || "").trim();
  }

  function makeSpeakerButton(template) {
    const btn = document.createElement("button");
    btn.setAttribute(MARK, "1");
    btn.setAttribute("type", "button");
    btn.setAttribute("aria-label", "Speak with SpeakIt");
    btn.setAttribute("title", "Speak with SpeakIt");
    if (template?.className) btn.className = template.className;
    btn.innerHTML = SPEAKER_SVG;
    return btn;
  }

  function inject(copyBtn) {
    if (copyBtn.hasAttribute(SCANNED)) return;
    copyBtn.setAttribute(SCANNED, "1");

    // Avoid double-inject if a sibling speak button is already there.
    const siblings = copyBtn.parentElement?.children || [];
    for (const s of siblings) if (s.hasAttribute?.(MARK)) return;

    const root = findMessageRoot(copyBtn);
    const speaker = makeSpeakerButton(copyBtn);

    speaker.addEventListener("click", (e) => {
      e.preventDefault();
      e.stopPropagation();
      const text = extractText(root);
      if (!text) return;
      try {
        chrome.runtime.sendMessage({ type: "speakit:speak", text });
      } catch (_) {
        // Extension context invalidated on update — fall back to direct anchor.
        const a = document.createElement("a");
        a.href = `speakit://speak?text=${encodeURIComponent(text.slice(0, 4000))}`;
        a.rel = "noopener";
        a.style.display = "none";
        document.body.appendChild(a);
        a.click();
        a.remove();
      }
    });

    copyBtn.insertAdjacentElement("afterend", speaker);
  }

  function scan(root = document) {
    const buttons = root.querySelectorAll?.(`button:not([${SCANNED}])`) || [];
    for (const b of buttons) if (isCopyButton(b)) inject(b);
  }

  const observer = new MutationObserver((mutations) => {
    for (const m of mutations) {
      for (const n of m.addedNodes) {
        if (n.nodeType === 1) scan(n);
      }
    }
  });
  observer.observe(document.documentElement, { childList: true, subtree: true });
  scan();
})();
