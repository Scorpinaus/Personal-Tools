const state = {
  videos: [],
  selectedVideo: null,
  currentJobId: null,
  pollTimer: null,
};

const els = {
  folderPaths: document.querySelector("#folderPaths"),
  refreshButton: document.querySelector("#refreshButton"),
  uploadInput: document.querySelector("#uploadInput"),
  videoList: document.querySelector("#videoList"),
  metadataStrip: document.querySelector("#metadataStrip"),
  extractForm: document.querySelector("#extractForm"),
  intervalInput: document.querySelector("#intervalInput"),
  startButton: document.querySelector("#startButton"),
  cancelButton: document.querySelector("#cancelButton"),
  progressBar: document.querySelector("#progressBar"),
  jobStatus: document.querySelector("#jobStatus"),
  frameCount: document.querySelector("#frameCount"),
  timeCount: document.querySelector("#timeCount"),
  outputPath: document.querySelector("#outputPath"),
  logOutput: document.querySelector("#logOutput"),
};

document.addEventListener("DOMContentLoaded", init);

function init() {
  els.refreshButton.addEventListener("click", loadVideos);
  els.uploadInput.addEventListener("change", uploadVideo);
  els.extractForm.addEventListener("submit", startExtraction);
  els.cancelButton.addEventListener("click", cancelJob);
  document.querySelectorAll("input[name='mode']").forEach((radio) => {
    radio.addEventListener("change", syncMode);
  });
  syncMode();
  loadHealth();
  loadVideos();
}

async function loadHealth() {
  try {
    const data = await api("/api/health");
    els.folderPaths.textContent = `Input: ${data.input_dir} | Output: ${data.output_dir}`;
  } catch (error) {
    els.folderPaths.textContent = error.message;
  }
}

async function loadVideos() {
  els.videoList.innerHTML = `<div class="empty">Loading...</div>`;
  try {
    const data = await api("/api/videos");
    state.videos = data.videos;
    els.folderPaths.textContent = `Input: ${data.input_dir}`;
    renderVideos();
  } catch (error) {
    els.videoList.innerHTML = `<div class="empty">${escapeHtml(error.message)}</div>`;
  }
}

function renderVideos() {
  if (!state.videos.length) {
    els.videoList.innerHTML = `<div class="empty">No videos in input folder.</div>`;
    els.startButton.disabled = true;
    return;
  }

  els.videoList.innerHTML = "";
  state.videos.forEach((video) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = `videoItem${video.name === state.selectedVideo ? " active" : ""}`;
    button.innerHTML = `
      <span class="videoName">${escapeHtml(video.name)}</span>
      <span class="videoSize">${formatBytes(video.size)}</span>
    `;
    button.addEventListener("click", () => selectVideo(video.name));
    els.videoList.append(button);
  });
}

async function selectVideo(videoName) {
  state.selectedVideo = videoName;
  els.startButton.disabled = false;
  renderVideos();
  els.metadataStrip.innerHTML = `<span>Reading metadata...</span>`;
  try {
    const data = await api(`/api/metadata?video=${encodeURIComponent(videoName)}`);
    renderMetadata(data);
  } catch (error) {
    els.metadataStrip.innerHTML = `<span>${escapeHtml(error.message)}</span>`;
  }
}

function renderMetadata(data) {
  const parts = [
    data.duration ? `Duration: ${formatDuration(data.duration)}` : "Duration: --",
    data.fps ? `FPS: ${round(data.fps, 3)}` : "FPS: --",
    data.width && data.height ? `${data.width} x ${data.height}` : "Size: --",
    data.estimated_frame_count ? `Frames: ${data.estimated_frame_count.toLocaleString()}` : "Frames: --",
  ];
  if (data.large_output_warning) {
    parts.push("Large output");
  }
  els.metadataStrip.innerHTML = parts
    .map((item) => `<span class="${item === "Large output" ? "warning" : ""}">${escapeHtml(item)}</span>`)
    .join("");
}

function syncMode() {
  const mode = getMode();
  els.intervalInput.disabled = mode === "all";
  if (mode === "all") {
    els.intervalInput.value = "1";
  } else if (mode === "milliseconds") {
    els.intervalInput.step = "1";
    els.intervalInput.min = "1";
  } else if (mode === "frames") {
    els.intervalInput.step = "1";
    els.intervalInput.min = "1";
  } else {
    els.intervalInput.step = "0.001";
    els.intervalInput.min = "0.001";
  }
}

async function uploadVideo() {
  const file = els.uploadInput.files[0];
  if (!file) return;
  const form = new FormData();
  form.append("file", file);
  setStatus("running", "Uploading");
  try {
    await api("/api/videos/upload", {
      method: "POST",
      body: form,
    });
    await loadVideos();
  } catch (error) {
    setStatus("failed", "Upload failed");
    els.logOutput.textContent = error.message;
  } finally {
    els.uploadInput.value = "";
  }
}

async function startExtraction(event) {
  event.preventDefault();
  if (!state.selectedVideo) return;

  const payload = {
    video: state.selectedVideo,
    mode: getMode(),
    interval: Number(els.intervalInput.value || 1),
    format: document.querySelector("#formatSelect").value,
    overwrite: document.querySelector("#overwriteSelect").value,
  };

  setControlsRunning(true);
  setStatus("running", "Queued");
  els.logOutput.textContent = "";
  els.progressBar.value = 0;

  try {
    const job = await api("/api/extract", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    state.currentJobId = job.id;
    updateJob(job);
    pollJob();
  } catch (error) {
    setControlsRunning(false);
    setStatus("failed", "Failed");
    els.logOutput.textContent = error.message;
  }
}

async function pollJob() {
  clearTimeout(state.pollTimer);
  if (!state.currentJobId) return;
  try {
    const job = await api(`/api/jobs/${state.currentJobId}`);
    updateJob(job);
    if (["queued", "running"].includes(job.status)) {
      state.pollTimer = setTimeout(pollJob, 700);
    } else {
      setControlsRunning(false);
    }
  } catch (error) {
    setControlsRunning(false);
    setStatus("failed", "Polling failed");
    els.logOutput.textContent = error.message;
  }
}

async function cancelJob() {
  if (!state.currentJobId) return;
  els.cancelButton.disabled = true;
  try {
    const job = await api(`/api/jobs/${state.currentJobId}/cancel`, { method: "POST" });
    updateJob(job);
  } catch (error) {
    els.logOutput.textContent = error.message;
  }
}

function updateJob(job) {
  setStatus(job.status, job.status);
  const progress = typeof job.progress === "number" ? Math.round(job.progress * 100) : 0;
  els.progressBar.value = progress;
  els.frameCount.textContent = `Frames: ${job.frame || 0}`;
  els.timeCount.textContent = `Time: ${formatDuration(job.current_time)} / ${formatDuration(job.duration)}`;
  els.outputPath.textContent = `Output: ${job.output_dir || "--"}`;
  els.logOutput.textContent = job.error || (job.recent_output || []).slice(-12).join("\n");
}

function setControlsRunning(isRunning) {
  els.startButton.disabled = isRunning || !state.selectedVideo;
  els.cancelButton.disabled = !isRunning;
}

function setStatus(kind, label) {
  els.jobStatus.className = `status ${kind}`;
  els.jobStatus.textContent = label || kind;
}

function getMode() {
  return document.querySelector("input[name='mode']:checked").value;
}

async function api(url, options = {}) {
  const response = await fetch(url, options);
  if (!response.ok) {
    let detail = response.statusText;
    try {
      const data = await response.json();
      detail = data.detail || detail;
    } catch {
      detail = await response.text();
    }
    throw new Error(detail);
  }
  return response.json();
}

function formatBytes(bytes) {
  if (!Number.isFinite(bytes)) return "--";
  const units = ["B", "KB", "MB", "GB", "TB"];
  let value = bytes;
  let index = 0;
  while (value >= 1024 && index < units.length - 1) {
    value /= 1024;
    index += 1;
  }
  return `${round(value, value >= 10 ? 1 : 2)} ${units[index]}`;
}

function formatDuration(seconds) {
  if (!Number.isFinite(seconds) || seconds < 0) return "--";
  const total = Math.floor(seconds);
  const hours = Math.floor(total / 3600);
  const minutes = Math.floor((total % 3600) / 60);
  const secs = total % 60;
  if (hours) {
    return `${hours}:${String(minutes).padStart(2, "0")}:${String(secs).padStart(2, "0")}`;
  }
  return `${minutes}:${String(secs).padStart(2, "0")}`;
}

function round(value, digits) {
  const factor = 10 ** digits;
  return Math.round(value * factor) / factor;
}

function escapeHtml(value) {
  return String(value)
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}
