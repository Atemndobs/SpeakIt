// Watches for text selection in the page. When the user finishes selecting
// (mouseup / keyup), forwards the selection to the background worker, which
// decides whether to invoke SpeakIt based on the user's auto-speak setting.

let debounce;

function onSelectionSettled() {
  const text = (window.getSelection()?.toString() || "").trim();
  if (!text) return;
  chrome.runtime.sendMessage({ type: "speakit:selection", text });
}

function schedule() {
  clearTimeout(debounce);
  debounce = setTimeout(onSelectionSettled, 250);
}

document.addEventListener("mouseup", schedule, true);
document.addEventListener("keyup", (e) => {
  // Shift+Arrow / Cmd+A and friends
  if (e.shiftKey || e.key === "a" || e.key === "A") schedule();
}, true);
