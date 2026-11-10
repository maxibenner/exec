"use strict";

// No external scripts, HTML injection, cookies, service worker or offline command
// queue. A dropped POST is reconciled with a read, never automatically repeated.
const $ = id => document.getElementById(id);
const storage = {
  get(name, fallback = null) { try { return JSON.parse(sessionStorage.getItem(`exec.${name}`)) ?? fallback; } catch { return fallback; } },
  set(name, value) { try { sessionStorage.setItem(`exec.${name}`, JSON.stringify(value)); } catch { /* Private browsing may disable storage. */ } }
};
let key = storage.get("key", "");
let selected = storage.get("selected", "");
let drafts = storage.get("drafts", {});
let pending = storage.get("pending");
let serverID = null;
let snapshot = null;
let online = false;
let refreshing = false;
let sending = false;
let timer;
let authVersion = 0;
let rows = [];
let folderListing = null;
let folderLoading = false;
let folderVersion = 0;
let openingCreatedID = null;
const cache = new Map();

class APIError extends Error {
  constructor(message, status) { super(message); this.status = status; }
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
  $("stop").hidden = !snapshot?.operationID;
  $("stop").disabled = !online || sending || !!pending;
  $("uncertain").hidden = !pending || sending;
  $("new-conversation").disabled = !online || !serverID || sending || !!pending;
  $("folder-select").disabled = !online || !folderListing || folderLoading || sending || !!pending || $("folder-path").value !== folderListing?.path;
  $("folder-up").disabled = folderLoading || !folderListing?.parent;
  $("folder-home").disabled = folderLoading;
  $("folder-go").disabled = folderLoading;
}
function lock() {
  authVersion++;
  key = ""; storage.set("key", "");
  clearTimeout(timer);
  cache.clear(); snapshot = null; rows = []; serverID = null; online = false;
  openingCreatedID = null; closeFolders();
  $("transcript").replaceChildren(); $("conversations").replaceChildren();
  $("app").hidden = true; $("login").hidden = false;
  $("access-key").value = "";
  updateControls();
}
async function request(path, body) {
  const version = authVersion;
  const headers = { "X-Exec-Key": key };
  if (body) headers["Content-Type"] = "application/json";
  else if (cache.has(path)) headers["If-None-Match"] = cache.get(path).etag;
  const controller = new AbortController();
  const timeout = setTimeout(() => controller.abort(), 12000);
  try {
    const response = await fetch(path, { method: body ? "POST" : "GET", headers,
      body: body ? JSON.stringify(body) : undefined, signal: controller.signal,
      cache: "no-store", credentials: "same-origin", redirect: "error" });
    if (version !== authVersion) throw new Error("Access changed. Check delivery after unlocking.");
    if (response.status === 304 && cache.has(path)) return cache.get(path).data;
    if (!(response.headers.get("Content-Type") || "").includes("application/json")) {
      throw new Error("Unexpected response. Reload the page to check Pangolin sign-in.");
    }
    const data = await response.json();
    if (!response.ok) {
      if (response.status === 401) { lock(); showError("login-error", "Access key rejected. Copy the current key from the Mac."); }
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
function renderList() {
  const fragment = document.createDocumentFragment();
  for (const row of rows) {
    const button = element("button", undefined, "conversation");
    button.setAttribute("aria-current", row.id === selected ? "page" : "false");
    button.disabled = row.unreadable;
    button.append(element("span", row.title, "conversation-title"));
    const detail = [row.workspace, row.needsApproval ? "Approval required" : (row.running ? "●" : "")].filter(Boolean).join(" · ");
    if (detail) button.append(element("span", detail, "conversation-meta"));
    button.addEventListener("click", () => selectConversation(row.id));
    fragment.append(button);
  }
  $("conversations").replaceChildren(fragment);
  $("empty-list").hidden = rows.length !== 0;
}
function selectConversation(id) {
  rememberDraft();
  selected = id; storage.set("selected", id); snapshot = null;
  $("transcript").replaceChildren(); $("approval").hidden = true;
  showError("conversation-error", "");
  $("title").textContent = rows.find(row => row.id === id)?.title || "Conversation";
  $("message").value = drafts[id] || "";
  $("app").classList.add("view-chat");
  renderList(); updateControls();
  void refresh();
}
function renderTranscript(data) {
  const transcript = $("transcript");
  const atBottom = !transcript.children.length || transcript.scrollHeight - transcript.scrollTop - transcript.clientHeight < 100;
  const existing = new Map(Array.from(transcript.children, node => [node.dataset.id, node]));
  const wanted = new Set(data.messages.map(row => row.id));
  for (const [id, node] of existing) if (!wanted.has(id)) node.remove();
  let previous = null;
  for (const row of data.messages) {
    const signature = JSON.stringify(row);
    let node = existing.get(row.id);
    if (!node) { node = element("article", undefined, `message ${row.role}`); node.dataset.id = row.id; }
    if (node.signature !== signature) {
      const open = node.querySelector("details")?.open || false;
      node.replaceChildren(); node.signature = signature;
      const status = row.pending ? "Queued" : (row.status === "interrupted" ? "Interrupted" : row.status === "failed" ? "Failed" : "");
      if (!row.tool) node.append(element("div", [row.role === "user" ? "You" : "Exec", status].filter(Boolean).join(" · "), "message-label"));
      if (row.tool) {
        const details = element("details", undefined, "tool"); details.open = open;
        details.append(element("summary", row.tool.title));
        const content = element("div", undefined, "tool-content");
        content.append(element("pre", row.tool.arguments));
        if (row.tool.output) content.append(element("pre", row.tool.output));
        details.append(content); node.append(details);
      } else {
        const body = element("div", undefined, "message-body");
        if (row.role === "assistant") markdown(body, row.text); else body.textContent = row.text;
        node.append(body);
      }
      if (row.imageCount) node.append(element("div", `${row.imageCount} image${row.imageCount === 1 ? "" : "s"} · view on Mac`, "context"));
    }
    const expected = previous ? previous.nextElementSibling : transcript.firstElementChild;
    if (expected !== node) transcript.insertBefore(node, expected);
    previous = node;
  }
  if (atBottom) transcript.scrollTop = transcript.scrollHeight;
  $("title").textContent = data.title;
  $("approval").hidden = !data.needsApproval;
  showError("conversation-error", data.error || (!data.canSend ? "Messaging is unavailable. Check this conversation on the Mac." : ""));
}

async function refresh() {
  clearTimeout(timer);
  if (!key || refreshing || document.hidden) return;
  refreshing = true;
  const version = authVersion;
  const destination = selected;
  try {
    const catalog = await request("/api/conversations");
    if (version !== authVersion) return;
    serverID = catalog.serverID;
    const listChanged = JSON.stringify(rows) !== JSON.stringify(catalog.conversations);
    rows = catalog.conversations;
    if (openingCreatedID && rows.some(row => row.id === openingCreatedID)) {
      const id = openingCreatedID; openingCreatedID = null;
      selectConversation(id);
    }
    if (selected && !rows.some(row => row.id === selected && !row.unreadable)) {
      rememberDraft(); selected = ""; snapshot = null; storage.set("selected", "");
      $("transcript").replaceChildren(); $("title").textContent = "Conversations";
      $("app").classList.remove("view-chat");
    }
    if (listChanged) renderList();
    if (destination && destination === selected) {
      const data = await request(`/api/conversations/${destination}`);
      if (version !== authVersion || selected !== destination) return;
      if (snapshot !== data) renderTranscript(data);
      snapshot = data;
    }
    online = true; setConnectionError("");
  } catch (error) {
    if (version === authVersion) {
      online = false;
      setConnectionError(error instanceof APIError ? error.message : "Cannot reach Exec. Sending is disabled. Check the Mac and Pangolin connection.");
    }
  } finally {
    refreshing = false;
    updateControls();
    if (key && !document.hidden) timer = setTimeout(refresh, 1000);
  }
}

function closeFolders() {
  folderVersion++; folderListing = null; folderLoading = false;
  if ($("folder-picker").open) $("folder-picker").close();
  $("folders").replaceChildren(); $("folder-path").value = "";
  $("folder-empty").hidden = true; $("folder-limit").hidden = true;
  showError("folder-error", ""); updateControls();
}
async function browseFolders(path = null) {
  const version = ++folderVersion;
  const authentication = authVersion;
  folderLoading = true; folderListing = null;
  $("folders").replaceChildren(); $("folder-empty").hidden = true; $("folder-limit").hidden = true;
  showError("folder-error", ""); updateControls();
  try {
    const listing = await request("/api/folders", { path });
    if (version !== folderVersion || authentication !== authVersion || !$("folder-picker").open) return;
    folderListing = listing; $("folder-path").value = listing.path;
    for (const folder of listing.folders) {
      const button = element("button", folder.name, "folder");
      button.addEventListener("click", () => void browseFolders(folder.path));
      $("folders").append(button);
    }
    $("folder-empty").hidden = listing.folders.length !== 0;
    $("folder-limit").hidden = !listing.truncated;
  } catch (error) {
    if (version === folderVersion && authentication === authVersion) showError("folder-error", error.message);
  } finally {
    if (version === folderVersion) { folderLoading = false; updateControls(); }
  }
}
async function createConversation() {
  if ($("folder-select").disabled || !folderListing) return;
  const command = { kind: "create", body: { serverID, requestID: crypto.randomUUID(), workspacePath: folderListing.path } };
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
  if (kind === "messages" && (!snapshot?.canSend || !$("message").value.trim())) return;
  if (kind === "stop" && !snapshot?.operationID) return;
  rememberDraft();
  const command = { kind, conversationID: selected, body: { serverID, requestID: crypto.randomUUID() } };
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
    if (error instanceof APIError && error.status !== 401) {
      savePending(null); showError("conversation-error", error.message);
    } else { online = false; }
  } finally {
    sending = false; updateControls(); void refresh();
  }
}
async function checkDelivery() {
  if (!pending || !key) return;
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

$("login-form").addEventListener("submit", async event => {
  event.preventDefault();
  if (!window.isSecureContext) { showError("login-error", "Open Exec through HTTPS before entering an access key."); return; }
  key = $("access-key").value.trim(); authVersion++; cache.clear();
  $("connect").disabled = true; showError("login-error", "");
  try {
    await request("/api/conversations");
    storage.set("key", key); $("access-key").value = "";
    $("login").hidden = true; $("app").hidden = false;
    $("message").value = drafts[selected] || "";
    await refresh();
  } catch (error) { showError("login-error", error.message); }
  finally { $("connect").disabled = false; }
});
$("new-conversation").addEventListener("click", () => {
  if ($("new-conversation").disabled) return;
  $("folder-picker").showModal(); void browseFolders();
});
$("folder-form").addEventListener("submit", event => { event.preventDefault(); void browseFolders($("folder-path").value); });
$("folder-path").addEventListener("input", updateControls);
$("folder-home").addEventListener("click", () => void browseFolders());
$("folder-up").addEventListener("click", () => { if (folderListing?.parent) void browseFolders(folderListing.parent); });
$("folder-cancel").addEventListener("click", closeFolders);
$("folder-picker").addEventListener("cancel", event => { event.preventDefault(); closeFolders(); });
$("folder-select").addEventListener("click", () => void createConversation());
$("logout").addEventListener("click", lock);
$("back").addEventListener("click", () => $("app").classList.remove("view-chat"));
$("refresh").addEventListener("click", () => { cache.clear(); void refresh(); });
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
  if (document.hidden) { clearTimeout(timer); online = false; updateControls(); }
  else void refresh();
});
window.addEventListener("offline", () => { online = false; updateControls(); });
window.addEventListener("online", () => void refresh());
// Keep the composer above the iOS software keyboard without page zooming.
if (window.visualViewport) {
  const fit = () => { document.body.style.height = `${window.visualViewport.height}px`; };
  window.visualViewport.addEventListener("resize", fit); fit();
}
if (key && window.isSecureContext) {
  $("login").hidden = true; $("app").hidden = false;
  $("message").value = drafts[selected] || "";
  void refresh();
} else {
  key = ""; storage.set("key", "");
  if (!window.isSecureContext) {
    $("access-key").disabled = true; $("connect").disabled = true;
    showError("login-error", "Open Exec through HTTPS before entering an access key.");
  }
}
updateControls();
