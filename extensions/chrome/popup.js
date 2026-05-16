const box = document.getElementById("autoSpeak");

chrome.storage.sync.get({ autoSpeak: false }, ({ autoSpeak }) => {
  box.checked = !!autoSpeak;
});

box.addEventListener("change", () => {
  chrome.storage.sync.set({ autoSpeak: box.checked });
});
