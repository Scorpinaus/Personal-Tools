const imageInput = document.querySelector("#images");
const folderInput = document.querySelector("#folder");
const selectedCount = document.querySelector("#selected-count");
const settingsForm = document.querySelector("#settings-form");
const estimate = document.querySelector("#frame-estimate");

function updateSelectedCount() {
  if (!selectedCount) {
    return;
  }

  const imageCount = imageInput?.files?.length || 0;
  const folderCount = folderInput?.files?.length || 0;
  const total = imageCount + folderCount;
  if (total > 0) {
    selectedCount.textContent = `${total} selected image${total === 1 ? "" : "s"}`;
  }
}

function readNumber(name, fallback) {
  const field = settingsForm?.elements?.[name];
  if (!field) {
    return fallback;
  }
  const value = Number.parseFloat(field.value);
  return Number.isFinite(value) ? value : fallback;
}

function updateEstimate() {
  if (!estimate || !settingsForm) {
    return;
  }

  const seconds = Math.max(readNumber("duration_seconds", 4), 0.25);
  const repeats = Math.max(Math.round(readNumber("repeat_count", 1)), 1);
  const fps = Math.max(Math.round(readNumber("fps", 24)), 4);
  const frames = Math.round(seconds * fps) * repeats;
  estimate.textContent = `${frames} exported frames${frames > 2400 ? " - reduce settings before export" : ""}`;
}

imageInput?.addEventListener("change", updateSelectedCount);
folderInput?.addEventListener("change", updateSelectedCount);
settingsForm?.addEventListener("input", updateEstimate);
updateEstimate();
