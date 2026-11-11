"use strict";

// No external scripts, HTML injection, cookies, service worker or offline command
// queue. A dropped POST is reconciled with a read, never automatically repeated.
const $ = id => document.getElementById(id);
const storage = {
  get(name, fallback = null) { try { return JSON.parse(sessionStorage.getItem(`exec.${name}`)) ?? fallback; } catch { return fallback; } },
  set(name, value) { try { sessionStorage.setItem(`exec.${name}`, JSON.stringify(value)); } catch { /* Private browsing may disable storage. */ } }
};
// Remove the obsolete browser credential without disturbing drafts or receipts.
for (const store of ["sessionStorage", "localStorage"]) {
  try { window[store].removeItem("exec.key"); } catch { /* Storage may be disabled. */ }
}
let selected = storage.get("selected", "");
let drafts = storage.get("drafts", {});
let pending = storage.get("pending");
let serverID = null;
let snapshot = null;
let revealPending = Boolean(selected);
let online = false;
let refreshing = false;
let sending = false;
let timer;
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)");
// Use the same eight-spoke activity indicator in the chat and the chat list.
function addSpinnerSpokes(spinner) {
  for (let index = 0; index < 8; index++) {
    const spoke = document.createElement("span");
    spoke.style.transform = `rotate(${index * 45}deg)`;
    spoke.style.opacity = String(.18 + index * .1);
    spinner.append(spoke);
  }
  return spinner;
}
addSpinnerSpokes($("working-indicator"));
addSpinnerSpokes($("chat-loading").firstElementChild);
let chatLoadingTimer = null;
function stopChatLoading() {
  clearTimeout(chatLoadingTimer);
  chatLoadingTimer = null;
  $("chat-loading").hidden = true;
}
function startChatLoading(id) {
  stopChatLoading();
  chatLoadingTimer = setTimeout(() => {
    chatLoadingTimer = null;
    if (selected === id && !snapshot && !document.hidden && !$("chat-page").hidden) {
      $("chat-loading").hidden = false;
    }
  }, 500);
}
function syncActivityIndicator() {
  const active = online && !$("chat-page").hidden && Boolean(snapshot?.operationID);
  const indicator = $("working-indicator");
  const transcript = $("transcript");
  const atBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 100;
  const wasHidden = indicator.hidden;
  indicator.hidden = !active;
  if (active && wasHidden && atBottom) transcript.scrollTop = transcript.scrollHeight;
}
let rows = [];
let folderListing = null;
let folderErrorParent = null;
let folderLoading = false;
let folderVersion = 0;
let openingCreatedID = null;
const cache = new Map();
let descriptiveShellTitles = false;

class APIError extends Error {
  constructor(message, status) { super(message); this.status = status; }
}
// getRandomValues also works on authenticated private-resource HTTP origins.
function commandID() {
  const bytes = crypto.getRandomValues(new Uint8Array(16));
  bytes[6] = (bytes[6] & 15) | 64; bytes[8] = (bytes[8] & 63) | 128;
  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, "0")).join("");
  return `${hex.slice(0, 8)}-${hex.slice(8, 12)}-${hex.slice(12, 16)}-${hex.slice(16, 20)}-${hex.slice(20)}`;
}
function showError(id, text) { $(id).textContent = text || ""; $(id).hidden = !text; }
function setConnectionError(text) {
  showError("connection-error", text);
  showError("list-error", text);
}
function savePending(value) { pending = value; storage.set("pending", value); updateControls(); }
function rememberDraft() {
  if (selected) { drafts[selected] = $("message").value; storage.set("drafts", drafts); }
  updateControls();
}
function updateControls() {
  $("composer").hidden = !selected;
  $("send").disabled = !online || !snapshot?.canSend || !$("message").value.trim() || sending || !!pending;
  const working = online && !!snapshot?.operationID;
  $("send").hidden = working;
  $("stop").hidden = !working;
  $("message").style.height = "auto";
  $("message").style.height = `${Math.min($("message").scrollHeight, 132)}px`;
  syncActivityIndicator();
  $("stop").disabled = !online || sending || !!pending;
  $("uncertain").hidden = !pending || sending;
  $("new-conversation").disabled = !online || !serverID || sending || !!pending;
  $("folder-select").classList.toggle("navigating", folderLoading && !!folderListing);
  $("folder-select").disabled = !online || !folderListing || folderLoading || sending || !!pending;
  $("folder-up").classList.toggle("navigating", folderLoading && !!(folderErrorParent || folderListing?.parent));
  $("folder-up").disabled = folderLoading || !(folderErrorParent || folderListing?.parent);
}
async function request(path, body) {
  const headers = { "X-Exec-Request": "1" };
  if (body) headers["Content-Type"] = "application/json";
  else if (cache.has(path)) headers["If-None-Match"] = cache.get(path).etag;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(path, { method: body ? "POST" : "GET", headers,
      body: body ? JSON.stringify(body) : undefined, signal: controller.signal,
      cache: "no-store", credentials: "same-origin", redirect: "error" });
    if (response.headers.get("X-Exec-Response") !== "1") {
      throw new Error("Reload this page to check Pangolin sign-in. No command was resent.");
    }
    if (response.status === 304 && cache.has(path)) return cache.get(path).data;
    if (!(response.headers.get("Content-Type") || "").includes("application/json")) {
      throw new Error("Unexpected response. Reload the page to check Pangolin sign-in.");
    }
    const data = await response.json();
    if (!response.ok) {
      throw new APIError(data.error || "Request rejected.", response.status);
    }
    const etag = response.headers.get("ETag");
    if (!body && etag) cache.set(path, { etag, data });
    return data;
  } finally { clearTimeout(timeout); }
}

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}
// Small, safe formatting subset. Unrecognized Markdown remains readable text.
// Tool output always bypasses formatting and renders as literal text.
function inline(parent, text) {
  const pattern = /(`[^`\n]+`|\*\*[^*\n]+\*\*|\[[^\]\n]+\]\(https?:\/\/[^\s)]+\))/g;
  let offset = 0;
  for (const match of text.matchAll(pattern)) {
    parent.append(document.createTextNode(text.slice(offset, match.index)));
    const token = match[0];
    if (token.startsWith("`")) parent.append(element("code", token.slice(1, -1)));
    else if (token.startsWith("**")) parent.append(element("strong", token.slice(2, -2)));
    else {
      const split = token.indexOf("](");
      const link = element("a", token.slice(1, split));
      link.href = token.slice(split + 2, -1); link.target = "_blank"; link.rel = "noopener noreferrer";
      parent.append(link);
    }
    offset = match.index + token.length;
  }
  parent.append(document.createTextNode(text.slice(offset)));
}
function markdown(parent, text) {
  const chunks = text.split(/^```[^\n]*\n|^```\s*$/gm);
  chunks.forEach((chunk, index) => {
    if (index % 2) { const pre = element("pre"); pre.append(element("code", chunk.replace(/\n$/, ""))); parent.append(pre); }
    else {
      for (const paragraph of chunk.split(/\n\s*\n/)) {
        if (!paragraph) continue;
        const heading = paragraph.match(/^(#{1,3}) (.*)$/);
        const block = element(heading ? `h${heading[1].length + 1}` : "p");
        inline(block, heading ? heading[2] : paragraph);
        parent.append(block);
      }
    }
  });
}
// Match the native unified DiffDocument classification. Keep markers, whitespace
// and trailing newlines intact; file contents never pass through HTML/Markdown.
function diffView(source) {
  const pre = element("pre", undefined, "diff");
  source.split("\n").forEach((text, index) => {
    if (index) pre.append(document.createTextNode("\n"));
    const header = (index < 2 && (text.startsWith("--- ") || text.startsWith("+++ "))) ||
      text.startsWith("@@ ") || text.startsWith("\\");
    const kind = header ? "header" : text.startsWith("+") ? "added" : text.startsWith("-") ? "removed" : "context";
    pre.append(element("span", text, `diff-${kind}`));
  });
  return pre;
}
function renderList() {
  const fragment = document.createDocumentFragment();
  for (const row of rows) {
    const button = element("button", undefined, "conversation");
    button.setAttribute("aria-current", row.id === selected ? "page" : "false");
    button.disabled = row.unreadable;
    button.append(element("span", row.title, "conversation-title"));
    const detail = [row.workspace, row.needsApproval ? "Approval required" : ""].filter(Boolean).join(" ");
    if (detail) button.append(element("span", detail, "conversation-meta"));
    if (row.running && !row.needsApproval) {
      const spinner = addSpinnerSpokes(element("span", undefined, "small-spinner"));
      spinner.setAttribute("role", "img"); spinner.setAttribute("aria-label", "Conversation running");
      button.append(spinner);
    }
    button.addEventListener("click", () => selectConversation(row.id));
    fragment.append(button);
  }
  $("conversations").replaceChildren(fragment);
  $("empty-list").hidden = rows.length !== 0;
}
function showChat() {
  $("chat-page").hidden = false;
  $("list-page").hidden = true;
  $("folder-page").hidden = true;
  updateControls();
}
function showList() {
  stopChatLoading();
  $("chat-page").hidden = true;
  $("list-page").hidden = false;
  $("folder-page").hidden = true;
  syncActivityIndicator();
}
function selectConversation(id) {
  rememberDraft();
  selected = id; storage.set("selected", id); snapshot = null; revealPending = true;
  $("transcript-messages").replaceChildren(); $("approval").hidden = true;
  showError("conversation-error", "");
  $("title").textContent = rows.find(row => row.id === id)?.title || "Conversation";
  $("message").value = drafts[id] || "";
  renderList(); showChat(); startChatLoading(id);
  void refresh();
}
// Tool headers mirror the Mac's compact disclosure rows. Untrusted argument
// values are rendered only via textContent; only fixed icon markup is HTML.
function toolHeader(tool) {
  const icons = {
    Search: '<circle cx="11" cy="11" r="6"/><path d="m16 16 5 5"/>',
    Read: '<path d="M6 2h8l5 5v15H6zM14 2v5h5M9 12h7M9 16h7"/>',
    List: '<path d="M2 6h8l2 2h10v12H2z"/>',
    Shell: '<rect x="2.5" y="4" width="19" height="16" rx="2"/><path d="m6 9 3 3-3 3M11 16h5"/>',
    Edit: '<path d="m4 20 4-.5L20 7.5 16.5 4 4.5 16z"/>',
    'Fetch page': '<path d="M6 2h8l5 5v15H6zM14 2v5h5M9 12h7"/>',
    'Web search': '<circle cx="12" cy="12" r="9"/><path d="M3 12h18M12 3c-5 5-5 13 0 18M12 3c5 5 5 13 0 18"/>',
    'Generate image': '<rect x="3" y="3" width="18" height="18" rx="2"/><circle cx="8" cy="8" r="1"/><path d="m3 18 6-6 4 4 3-3 5 5"/>',
    Screenshot: '<rect x="3" y="5" width="18" height="14" rx="2"/><circle cx="12" cy="12" r="3"/>'
  };
  const summary = element("summary");
  const chevron = element("span", undefined, "tool-chevron");
  chevron.innerHTML = '<svg viewBox="0 0 16 16" aria-hidden="true"><path d="m6 3 5 5-5 5"/></svg>';
  const icon = element("span", undefined, "tool-icon");
  icon.innerHTML = `<svg viewBox="0 0 24 24" aria-hidden="true">${icons[tool.title] || '<path d="M4 6h16v12H4zM8 10h8M8 14h5"/>'}</svg>`;
  summary.append(chevron, icon, element("span", tool.title, "tool-name"));
  let args = {};
  try { args = JSON.parse(tool.arguments); } catch { /* Show the raw arguments when expanded. */ }
  if (!args || typeof args !== "object" || Array.isArray(args)) args = {};
  const text = value => typeof value === "string" ? value.replace(/[\r\n\t]+/g, " ") : "";
  const description = tool.title === "Search" ? [text(args.query), text(args.path)].filter(Boolean).join(" · ") :
    tool.title === "Web search" ? text(args.query) :
    tool.title === "Fetch page" ? text(args.url) :
    tool.title === "Generate image" ? text(args.prompt) :
    tool.title === "Shell" ? (descriptiveShellTitles ? text(args.description).trim() || text(args.command) : text(args.command)) : text(args.path);
  if (description) summary.append(element("span", description, "tool-summary"));
  if (tool.title === "Read" && Number.isInteger(args.start_line) && Number.isInteger(args.end_line)) {
    summary.append(element("span", `Lines ${args.start_line}–${args.end_line}`, "tool-detail"));
  }
  return summary;
}
// Fade the transcript once when its initial snapshot arrives; later updates
// and scrolling remain immediate.
function revealTranscript() {
  if (!revealPending) return;
  revealPending = false;
  if (reduceMotion.matches || document.hidden || $("chat-page").hidden) return;
  const transcript = $("transcript");
  const finish = event => {
    if (event.target !== transcript) return;
    transcript.classList.remove("transcript-reveal");
    transcript.removeEventListener("animationend", finish);
  };
  transcript.classList.add("transcript-reveal");
  transcript.addEventListener("animationend", finish);
}
function renderTranscript(data) {
  stopChatLoading();
  const transcript = $("transcript");
  const messages = $("transcript-messages");
  const atBottom = !messages.children.length || transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 100;
  const existing = new Map(Array.from(messages.children, node => [node.dataset.id, node]));
  const wanted = new Set(data.messages.map(row => row.id));
  for (const [id, node] of existing) if (!wanted.has(id)) node.remove();
  let previous = null;
  for (const row of data.messages) {
    const signature = JSON.stringify(row) + (row.tool?.title === "Shell" ? descriptiveShellTitles : "");
    let node = existing.get(row.id);
    if (!node) { node = element("article", undefined, `message ${row.role}`); node.dataset.id = row.id; }
    if (node.signature !== signature) {
      const open = node.querySelector("details")?.open || false;
      node.replaceChildren(); node.signature = signature;
      const status = row.role === "assistant" && row.status === "failed" ? "Failed" : "";
      if (status) node.append(element("div", status, "message-label"));
      if (row.tool) {
        const details = element("details", undefined, "tool"); details.open = open;
        details.append(toolHeader(row.tool));
        const content = element("div", undefined, "tool-content");
        // A completed edit already shows its file in the header and its changes
        // in the diff. Keep raw inputs only when no diff is available (e.g. errors).
        if (!row.tool.isDiff) content.append(element("pre", row.tool.arguments));
        if (row.tool.output) {
          content.append(row.tool.isDiff ? diffView(row.tool.output) : element("pre", row.tool.output));
        }
        details.append(content); node.append(details);
      } else {
        const body = element("div", undefined, "message-body");
        if (row.role === "assistant") markdown(body, row.text); else body.textContent = row.text;
        node.append(body);
      }
      if (row.imageCount) node.append(element("div", `${row.imageCount} image${row.imageCount === 1 ? "" : "s"} · view on Mac`, "context"));
    }
    const expected = previous ? previous.nextElementSibling : messages.firstElementChild;
    if (expected !== node) messages.insertBefore(node, expected);
    previous = node;
  }
  if (atBottom) transcript.scrollTop = transcript.scrollHeight;
  revealTranscript();
  $("title").textContent = data.title;
  $("approval").hidden = !data.needsApproval;
  showError("conversation-error", data.error || (!data.canSend ? "Messaging is unavailable. Check this conversation on the Mac." : ""));
}

async function refresh() {
  clearTimeout(timer);
  if (refreshing || document.hidden) return;
  refreshing = true;
  const destination = selected;
  try {
    const catalog = await request("/api/conversations");
    serverID = catalog.serverID;
    const listChanged = JSON.stringify(rows) !== JSON.stringify(catalog.conversations);
    rows = catalog.conversations;
    if (typeof catalog.descriptiveShellTitles === "boolean" && catalog.descriptiveShellTitles !== descriptiveShellTitles) {
      descriptiveShellTitles = catalog.descriptiveShellTitles;
      if (snapshot?.id === selected) renderTranscript(snapshot);
    }
    if (openingCreatedID && rows.some(row => row.id === openingCreatedID)) {
      const id = openingCreatedID; openingCreatedID = null;
      selectConversation(id);
    }
    if (selected && !rows.some(row => row.id === selected && !row.unreadable)) {
      rememberDraft(); selected = ""; snapshot = null; storage.set("selected", "");
      $("transcript-messages").replaceChildren(); $("title").textContent = "Your chats";
      $("approval").hidden = true; showError("conversation-error", "");
      showList();
    }
    // Resume the tab's selected chat, or open the first readable conversation.
    if (!selected) {
      const first = rows.find(row => !row.unreadable);
      if (first) selectConversation(first.id);
    }
    if (listChanged) renderList();
    if (destination && destination === selected) {
      const data = await request(`/api/conversations/${destination}`);
      if (selected !== destination) return;
      if (snapshot !== data) renderTranscript(data);
      snapshot = data;
    }
    online = true; setConnectionError("");
  } catch (error) {
    stopChatLoading();
    online = false;
    setConnectionError(error instanceof APIError ? error.message : "Cannot reach Exec. Check the Mac and connection, or reload this page to sign in to Pangolin. No command was resent.");
  } finally {
    refreshing = false;
    updateControls();
    if (!document.hidden) timer = setTimeout(refresh, 1000);
  }
}

function closeFolders() {
  folderVersion++; folderListing = null; folderErrorParent = null; folderLoading = false;
  $("folders").replaceChildren();
  $("folder-empty").hidden = true; $("folder-limit").hidden = true;
  showError("folder-error", ""); showList(); updateControls();
}
async function browseFolders(path = null) {
  const version = ++folderVersion;
  const previous = folderListing;
  const name = path => path.split("/").filter(Boolean).at(-1) || "/";
  folderLoading = true;
  // Keep the old listing on screen until the next read has completed.
  showError("folder-error", ""); updateControls();
  try {
    const listing = await request("/api/folders", { path });
    if (version !== folderVersion || $("folder-page").hidden) return;
    const nextRows = document.createDocumentFragment();
    for (const folder of listing.folders) {
      const button = element("button", undefined, "folder");
      const icon = element("span", undefined, "folder-icon");
      icon.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M2 6h8l2 2h10v12H2z"/></svg>';
      const chevron = element("span", undefined, "folder-chevron");
      chevron.innerHTML = '<svg viewBox="0 0 24 24" aria-hidden="true"><path d="m9 5 7 7-7 7"/></svg>';
      button.append(icon, element("span", folder.name, "folder-name"), chevron);
      button.addEventListener("click", () => { if (!folderLoading) void browseFolders(folder.path); });
      nextRows.append(button);
    }
    folderListing = listing; folderErrorParent = null;
    $("folders").replaceChildren(nextRows);
    $("folder-current").textContent = name(listing.path);
    $("folder-current-path").textContent = listing.path;
    $("folder-parent").textContent = listing.parent ? name(listing.parent) : "Back";
    $("folder-up").setAttribute("aria-label", listing.parent ? `Back to ${name(listing.parent)}` : "No parent folder");
    $("folder-empty").hidden = listing.folders.length !== 0;
    $("folder-limit").hidden = !listing.truncated;
  } catch (error) {
    if (version === folderVersion) {
      const child = previous && path?.startsWith(previous.path === "/" ? "/" : previous.path + "/");
      if (child) {
        // The unreadable child cannot be selected, but its parent remains reachable.
        folderListing = null; folderErrorParent = previous.path;
        $("folders").replaceChildren();
        $("folder-empty").hidden = true; $("folder-limit").hidden = true;
        $("folder-current").textContent = name(path);
        $("folder-current-path").textContent = path;
        $("folder-parent").textContent = name(previous.path);
        $("folder-up").setAttribute("aria-label", `Back to ${name(previous.path)}`);
      } else {
        folderListing = previous; folderErrorParent = null;
      }
      showError("folder-error", error.message);
    }
  } finally {
    if (version === folderVersion) { folderLoading = false; updateControls(); }
  }
}
async function createConversation() {
  if ($("folder-select").disabled || !folderListing) return;
  const command = { kind: "create", body: { serverID, requestID: commandID(), workspacePath: folderListing.path } };
  closeFolders();
  sending = true; savePending(command); showError("receipt-error", "");
  try {
    const receipt = await request("/api/conversations", command.body);
    if (receipt.accepted) finishAccepted(command);
  } catch (error) {
    // A failed response may follow a successful disk write. Never create again
    // automatically, even if saving the catalog or returning the receipt failed.
    showError("receipt-error", error instanceof APIError ? error.message : "Could not confirm creation. Check its receipt or the conversation list before trying again.");
  } finally {
    sending = false; updateControls(); void refresh();
  }
}

function finishAccepted(command) {
  if (command.kind === "create") openingCreatedID = command.body.requestID.toUpperCase();
  if (command.kind === "messages" && drafts[command.conversationID] === command.body.text) {
    drafts[command.conversationID] = ""; storage.set("drafts", drafts);
    if (selected === command.conversationID) $("message").value = "";
  }
  savePending(null); showError("receipt-error", "");
}
async function submit(kind) {
  if (!online || !serverID || !selected || pending || sending) return;
  if (kind === "messages" && (!snapshot?.canSend || snapshot.operationID || !$("message").value.trim())) return;
  if (kind === "stop" && !snapshot?.operationID) return;
  rememberDraft();
  const command = { kind, conversationID: selected, body: { serverID, requestID: commandID() } };
  if (kind === "messages") {
    command.body.text = $("message").value;
    if (new TextEncoder().encode(command.body.text).length > 32768) {
      showError("conversation-error", "Messages must be at most 32 KiB."); return;
    }
  } else command.body.operationID = snapshot.operationID;
  sending = true; savePending(command); showError("conversation-error", "");
  try {
    const receipt = await request(`/api/conversations/${command.conversationID}/${kind}`, command.body);
    if (receipt.accepted) finishAccepted(command);
  } catch (error) {
    if (error instanceof APIError && error.status !== 401 && error.status !== 403) {
      savePending(null); showError("conversation-error", error.message);
    } else { online = false; }
  } finally {
    sending = false; updateControls(); void refresh();
  }
}
async function checkDelivery() {
  if (!pending) return;
  const command = pending;
  $("check-delivery").disabled = true;
  try {
    const receipt = await request(`/api/commands/${command.body.requestID}`);
    if (pending !== command) return;
    if (receipt.serverID === command.body.serverID && receipt.accepted) finishAccepted(command);
    else showError("receipt-error", "No matching receipt is available. Delivery is still uncertain; inspect the conversation on the Mac before dismissing.");
  } catch { showError("receipt-error", "Could not check the receipt. No command was resent."); }
  finally { $("check-delivery").disabled = false; void refresh(); }
}

$("new-conversation").addEventListener("click", () => {
  if ($("new-conversation").disabled) return;
  $("list-page").hidden = true;
  $("folder-page").hidden = false;
  void browseFolders();
});
$("folder-up").addEventListener("click", () => {
  if (folderLoading) return;
  const parent = folderErrorParent || folderListing?.parent;
  if (parent) void browseFolders(parent);
});
$("folder-cancel").addEventListener("click", closeFolders);
$("folder-select").addEventListener("click", () => void createConversation());
$("back").addEventListener("click", showList);
$("message").addEventListener("input", rememberDraft);
$("message").addEventListener("keydown", event => {
  if (event.key === "Enter" && (event.metaKey || event.ctrlKey)) { event.preventDefault(); void submit("messages"); }
});
$("composer").addEventListener("submit", event => { event.preventDefault(); void submit("messages"); });
$("stop").addEventListener("click", () => void submit("stop"));
$("check-delivery").addEventListener("click", () => void checkDelivery());
$("dismiss-delivery").addEventListener("click", () => {
  if (window.confirm("This command may already have run. Dismiss the warning without resending it?")) { savePending(null); showError("receipt-error", ""); }
});
document.addEventListener("visibilitychange", () => {
  if (document.hidden) { stopChatLoading(); clearTimeout(timer); online = false; updateControls(); }
  else { if (selected && !snapshot && !$("chat-page").hidden) startChatLoading(selected); void refresh(); }
});
window.addEventListener("offline", () => { online = false; updateControls(); });
window.addEventListener("online", () => void refresh());
// Keep the header at the page top. Only the composer follows the visible
// viewport above the iOS keyboard; moving the whole page makes the header jump.
if (window.visualViewport) {
  const fit = () => {
    const viewport = window.visualViewport;
    const inset = window.innerWidth > 700 ? 0 :
      Math.max(0, window.innerHeight - viewport.height - viewport.offsetTop);
    const transcript = $("transcript");
    const nearBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 100;
    $("app").style.setProperty("--keyboard-inset", `${inset}px`);
    if (nearBottom) requestAnimationFrame(() => { transcript.scrollTop = transcript.scrollHeight; });
  };
  window.visualViewport.addEventListener("resize", fit);
  window.visualViewport.addEventListener("scroll", fit);
  window.addEventListener("resize", fit);
  fit();
}
// The transcript scrolls behind the composer, while its bottom inset tracks
// the actual composer height (including multiline drafts and the iOS safe area).
const composerObserver = new ResizeObserver(() => {
  const transcript = $("transcript");
  const nearBottom = transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 100;
  const height = $("composer").hidden ? 0 : $("composer").getBoundingClientRect().height;
  $("app").style.setProperty("--composer-height", `${height}px`);
  if (nearBottom) transcript.scrollTop = transcript.scrollHeight;
});
composerObserver.observe($("composer"));
const folderFooterObserver = new ResizeObserver(() => {
  const folders = $("folders");
  const nearBottom = folders.scrollHeight - folders.scrollTop - folders.clientHeight < 100;
  const height = $("folder-page").hidden ? 0 : $("folder-footer").getBoundingClientRect().height;
  $("folder-page").style.setProperty("--folder-footer-height", `${height}px`);
  if (nearBottom) folders.scrollTop = folders.scrollHeight;
});
folderFooterObserver.observe($("folder-footer"));
const listFooterObserver = new ResizeObserver(() => {
  const list = $("conversations");
  const nearBottom = list.scrollHeight - list.scrollTop - list.clientHeight < 100;
  const height = $("list-page").hidden ? 0 : $("list-footer").getBoundingClientRect().height;
  $("list-page").style.setProperty("--list-footer-height", `${height}px`);
  if (nearBottom) list.scrollTop = list.scrollHeight;
});
listFooterObserver.observe($("list-footer"));
$("message").value = drafts[selected] || "";
if (selected) { showChat(); startChatLoading(selected); } else showList();
renderList();
void refresh();
updateControls();
