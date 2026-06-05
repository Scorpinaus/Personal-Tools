const state = {
  config: null,
  posts: [],
  pollTimer: null,
};

const els = {
  apiStatus: document.querySelector("#apiStatus"),
  syncButton: document.querySelector("#syncButton"),
  refreshButton: document.querySelector("#refreshButton"),
  communityForm: document.querySelector("#communityForm"),
  communityInput: document.querySelector("#communityInput"),
  communityList: document.querySelector("#communityList"),
  communityCount: document.querySelector("#communityCount"),
  termForm: document.querySelector("#termForm"),
  termInput: document.querySelector("#termInput"),
  caseSensitiveInput: document.querySelector("#caseSensitiveInput"),
  termList: document.querySelector("#termList"),
  termCount: document.querySelector("#termCount"),
  syncStatus: document.querySelector("#syncStatus"),
  syncRequests: document.querySelector("#syncRequests"),
  syncSeen: document.querySelector("#syncSeen"),
  syncSaved: document.querySelector("#syncSaved"),
  syncErrors: document.querySelector("#syncErrors"),
  textFilter: document.querySelector("#textFilter"),
  subredditFilter: document.querySelector("#subredditFilter"),
  termFilter: document.querySelector("#termFilter"),
  readFilter: document.querySelector("#readFilter"),
  archivedFilter: document.querySelector("#archivedFilter"),
  resultCount: document.querySelector("#resultCount"),
  postsTable: document.querySelector("#postsTable"),
  toast: document.querySelector("#toast"),
};

document.addEventListener("DOMContentLoaded", init);

function init() {
  bindEvents();
  loadAll();
}

function bindEvents() {
  els.refreshButton.addEventListener("click", loadAll);
  els.syncButton.addEventListener("click", runSync);
  els.communityForm.addEventListener("submit", addCommunity);
  els.termForm.addEventListener("submit", addTerm);

  for (const el of [els.textFilter, els.subredditFilter, els.termFilter, els.readFilter, els.archivedFilter]) {
    el.addEventListener("input", debounce(loadPosts, 180));
    el.addEventListener("change", loadPosts);
  }
}

async function loadAll() {
  await loadConfig();
  await loadPosts();
}

async function loadConfig() {
  const config = await api("/api/config");
  state.config = config;
  renderConfig();
  renderSync(config.latest_sync, config.sync_running);
  if (config.sync_running) {
    startPolling();
  }
}

async function loadPosts() {
  const params = new URLSearchParams();
  const text = els.textFilter.value.trim();
  const subreddit = els.subredditFilter.value;
  const term = els.termFilter.value;
  if (text) params.set("q", text);
  if (subreddit) params.set("subreddit", subreddit);
  if (term) params.set("term_id", term);
  if (els.archivedFilter.checked) params.set("include_archived", "1");
  if (els.readFilter.value !== "all") params.set("read", els.readFilter.value);
  params.set("limit", "200");

  const payload = await api(`/api/posts?${params}`);
  state.posts = payload.posts || [];
  renderPosts();
}

function renderConfig() {
  const config = state.config;
  const communities = config.communities || [];
  const terms = config.terms || [];

  if (config.credentials_ready) {
    els.apiStatus.textContent = `OAuth ready. Full content expires after ${config.retention_hours} hours.`;
    els.syncButton.disabled = false;
  } else {
    els.apiStatus.textContent = `Add Reddit OAuth settings to .env: ${config.missing_credentials.join(", ")}`;
    els.syncButton.disabled = true;
  }

  els.communityCount.textContent = communities.length;
  els.termCount.textContent = terms.length;
  renderCommunityList(communities);
  renderTermList(terms);
  renderFilterOptions(communities, terms);
}

function renderCommunityList(communities) {
  if (!communities.length) {
    els.communityList.innerHTML = `<p class="muted">No communities yet.</p>`;
    return;
  }
  els.communityList.innerHTML = communities.map((community) => `
    <div class="list-item">
      <input type="checkbox" ${community.active ? "checked" : ""} data-community-active="${community.id}" title="Toggle active">
      <span class="item-name">r/${escapeHtml(community.name)}</span>
      <button class="icon-button" type="button" data-community-delete="${community.id}" title="Delete community">&times;</button>
    </div>
  `).join("");

  els.communityList.querySelectorAll("[data-community-active]").forEach((checkbox) => {
    checkbox.addEventListener("change", () => patchCommunity(checkbox.dataset.communityActive, {
      active: checkbox.checked,
    }));
  });
  els.communityList.querySelectorAll("[data-community-delete]").forEach((button) => {
    button.addEventListener("click", () => deleteCommunity(button.dataset.communityDelete));
  });
}

function renderTermList(terms) {
  if (!terms.length) {
    els.termList.innerHTML = `<p class="muted">No terms yet.</p>`;
    return;
  }
  els.termList.innerHTML = terms.map((term) => `
    <div class="list-item">
      <input type="checkbox" ${term.active ? "checked" : ""} data-term-active="${term.id}" title="Toggle active">
      <span class="item-name">${escapeHtml(term.phrase)}${term.case_sensitive ? " - case" : ""}</span>
      <button class="icon-button" type="button" data-term-delete="${term.id}" title="Delete term">&times;</button>
    </div>
  `).join("");

  els.termList.querySelectorAll("[data-term-active]").forEach((checkbox) => {
    checkbox.addEventListener("change", () => patchTerm(checkbox.dataset.termActive, {
      active: checkbox.checked,
    }));
  });
  els.termList.querySelectorAll("[data-term-delete]").forEach((button) => {
    button.addEventListener("click", () => deleteTerm(button.dataset.termDelete));
  });
}

function renderFilterOptions(communities, terms) {
  const selectedCommunity = els.subredditFilter.value;
  const selectedTerm = els.termFilter.value;
  els.subredditFilter.innerHTML = `<option value="">All communities</option>` +
    communities.map((community) => `<option value="${escapeHtml(community.name)}">r/${escapeHtml(community.name)}</option>`).join("");
  els.termFilter.innerHTML = `<option value="">All terms</option>` +
    terms.map((term) => `<option value="${term.id}">${escapeHtml(term.phrase)}</option>`).join("");
  els.subredditFilter.value = selectedCommunity;
  els.termFilter.value = selectedTerm;
}

function renderSync(latest, running) {
  els.syncButton.disabled = running || !state.config?.credentials_ready;
  if (!latest) {
    els.syncStatus.textContent = running ? "Running" : "No sync yet";
    els.syncRequests.textContent = "0";
    els.syncSeen.textContent = "0";
    els.syncSaved.textContent = "0";
    els.syncErrors.textContent = "";
    return;
  }
  els.syncStatus.textContent = running ? "Running" : latest.status.replaceAll("_", " ");
  els.syncRequests.textContent = latest.requests_made ?? 0;
  els.syncSeen.textContent = latest.posts_seen ?? 0;
  els.syncSaved.textContent = latest.posts_saved ?? 0;
  els.syncErrors.textContent = latest.errors?.length ? latest.errors.join(" ") : "";
}

function renderPosts() {
  els.resultCount.textContent = state.posts.length;
  if (!state.posts.length) {
    els.postsTable.innerHTML = `<tr><td colspan="5" class="empty">No saved matches found.</td></tr>`;
    return;
  }

  els.postsTable.innerHTML = state.posts.map((post) => {
    const title = post.title || "(content expired or removed)";
    const excerpt = post.selftext || post.url || "";
    const matchedTerms = splitCsv(post.matched_terms);
    const permalink = post.permalink || "";
    return `
      <tr>
        <td>
          ${permalink ? `<a class="post-title link" href="${escapeAttr(permalink)}" target="_blank" rel="noreferrer">${escapeHtml(title)}</a>` : `<span class="post-title">${escapeHtml(title)}</span>`}
          <p class="post-excerpt">${escapeHtml(truncate(excerpt, 260))}</p>
        </td>
        <td>r/${escapeHtml(post.subreddit)}</td>
        <td><div class="tag-row">${matchedTerms.map((term) => `<span class="tag">${escapeHtml(term)}</span>`).join("")}</div></td>
        <td>
          <div>${post.score} score</div>
          <div class="muted">${post.num_comments} comments</div>
        </td>
        <td>
          <div class="action-row">
            <button type="button" data-post-read="${escapeAttr(post.reddit_id)}">${post.read ? "Unread" : "Read"}</button>
            <button type="button" data-post-archive="${escapeAttr(post.reddit_id)}">${post.archived ? "Restore" : "Archive"}</button>
          </div>
        </td>
      </tr>
    `;
  }).join("");

  els.postsTable.querySelectorAll("[data-post-read]").forEach((button) => {
    button.addEventListener("click", () => {
      const post = state.posts.find((item) => item.reddit_id === button.dataset.postRead);
      patchPost(button.dataset.postRead, { read: !Boolean(post?.read) });
    });
  });
  els.postsTable.querySelectorAll("[data-post-archive]").forEach((button) => {
    button.addEventListener("click", () => {
      const post = state.posts.find((item) => item.reddit_id === button.dataset.postArchive);
      patchPost(button.dataset.postArchive, { archived: !Boolean(post?.archived) });
    });
  });
}

async function addCommunity(event) {
  event.preventDefault();
  const name = els.communityInput.value.trim();
  if (!name) return;
  await api("/api/communities", {
    method: "POST",
    body: JSON.stringify({ name }),
  });
  els.communityInput.value = "";
  showToast("Community saved.");
  await loadAll();
}

async function patchCommunity(id, payload) {
  await api(`/api/communities/${id}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
  await loadAll();
}

async function deleteCommunity(id) {
  await api(`/api/communities/${id}`, { method: "DELETE" });
  showToast("Community deleted.");
  await loadAll();
}

async function addTerm(event) {
  event.preventDefault();
  const phrase = els.termInput.value.trim();
  if (!phrase) return;
  await api("/api/terms", {
    method: "POST",
    body: JSON.stringify({
      phrase,
      case_sensitive: els.caseSensitiveInput.checked,
    }),
  });
  els.termInput.value = "";
  els.caseSensitiveInput.checked = false;
  showToast("Term saved.");
  await loadAll();
}

async function patchTerm(id, payload) {
  await api(`/api/terms/${id}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
  await loadAll();
}

async function deleteTerm(id) {
  await api(`/api/terms/${id}`, { method: "DELETE" });
  showToast("Term deleted.");
  await loadAll();
}

async function patchPost(redditId, payload) {
  await api(`/api/posts/${encodeURIComponent(redditId)}`, {
    method: "PATCH",
    body: JSON.stringify(payload),
  });
  await loadPosts();
}

async function runSync() {
  await api("/api/sync", { method: "POST" });
  showToast("Sync started.");
  startPolling();
  await loadConfig();
}

function startPolling() {
  if (state.pollTimer) return;
  state.pollTimer = window.setInterval(async () => {
    const payload = await api("/api/sync/latest");
    renderSync(payload.latest_sync, payload.sync_running);
    if (!payload.sync_running) {
      window.clearInterval(state.pollTimer);
      state.pollTimer = null;
      await loadAll();
    }
  }, 1500);
}

async function api(path, options = {}) {
  const response = await fetch(path, {
    headers: {
      "Content-Type": "application/json",
      ...(options.headers || {}),
    },
    ...options,
  });
  if (response.status === 204) {
    return {};
  }
  const payload = await response.json();
  if (!response.ok) {
    showToast(payload.error || "Request failed.");
    throw new Error(payload.error || "Request failed.");
  }
  return payload;
}

function showToast(message) {
  els.toast.textContent = message;
  els.toast.classList.add("visible");
  window.clearTimeout(showToast.timeout);
  showToast.timeout = window.setTimeout(() => {
    els.toast.classList.remove("visible");
  }, 2600);
}

function debounce(fn, wait) {
  let timeout;
  return (...args) => {
    window.clearTimeout(timeout);
    timeout = window.setTimeout(() => fn(...args), wait);
  };
}

function splitCsv(value) {
  if (!value) return [];
  return String(value).split(",").map((part) => part.trim()).filter(Boolean);
}

function truncate(value, maxLength) {
  const text = String(value || "");
  if (text.length <= maxLength) return text;
  return `${text.slice(0, maxLength - 3)}...`;
}

function escapeHtml(value) {
  return String(value ?? "")
    .replaceAll("&", "&amp;")
    .replaceAll("<", "&lt;")
    .replaceAll(">", "&gt;")
    .replaceAll('"', "&quot;")
    .replaceAll("'", "&#039;");
}

function escapeAttr(value) {
  return escapeHtml(value).replaceAll("`", "&#096;");
}
