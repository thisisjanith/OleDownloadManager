// Background script (Chrome service worker / Firefox background page).
// Talks to OleDownloadManager only through the registered native messaging host.
"use strict";

if (typeof importScripts === "function" && typeof OLEDM === "undefined") {
  importScripts("logic.js");   // Chrome service worker
}

const api = globalThis.browser ?? globalThis.chrome;
const BROWSER = typeof globalThis.browser !== "undefined" && navigator.userAgent.includes("Firefox") ? "firefox" : "chrome";
const recent = OLEDM.createRecentSet();
const MENU_ID = "oledm-download";

async function getSettings() {
  const stored = await api.storage.local.get("settings");
  return Object.assign({}, OLEDM.DEFAULT_SETTINGS, stored.settings || {});
}

function sendNative(message, timeoutMs = 15000) {
  const call = api.runtime.sendNativeMessage(OLEDM.HOST_NAME, message);
  const timeout = new Promise((_, reject) => setTimeout(() => reject(new Error("timeout")), timeoutMs));
  return Promise.race([call, timeout]);
}

async function flashBadge(ok) {
  try {
    await api.action.setBadgeBackgroundColor({ color: ok ? "#2a7de1" : "#d93025" });
    await api.action.setBadgeText({ text: ok ? "✓" : "!" });
    setTimeout(() => api.action.setBadgeText({ text: "" }), 4000);
  } catch (_) { /* badge is cosmetic */ }
}

/** Sends one URL to the app. Returns {ok, text}. Never throws. */
async function submit({ url, pageUrl, fileName, source }) {
  if (!OLEDM.isHttpUrl(url)) return { ok: false, text: "Only http and https links can be sent." };
  if (!recent.checkAndAdd(url)) return { ok: true, text: "Already sent." };
  const settings = await getSettings();
  const message = OLEDM.buildAddDownload({ url, pageUrl, fileName, mode: settings.mode, source, browser: BROWSER });
  try {
    const reply = await sendNative(message);
    const result = OLEDM.describeReply(reply);
    await flashBadge(result.ok);
    return result;
  } catch (error) {
    await flashBadge(false);
    const missing = String(error && error.message || error).match(/not found|host|specified native messaging/i);
    return { ok: false, text: missing ? "The OleDownloadManager native host is not installed. Install it from the app's Settings › Browser." : "Could not reach OleDownloadManager." };
  }
}

function createMenu() {
  api.contextMenus.removeAll(() => {
    api.contextMenus.create({
      id: MENU_ID,
      title: "Download with OleDownloadManager",
      contexts: ["link", "video", "audio", "image"],
    });
  });
}

api.runtime.onInstalled.addListener(createMenu);
if (api.runtime.onStartup) api.runtime.onStartup.addListener(createMenu);

api.contextMenus.onClicked.addListener((info) => {
  if (info.menuItemId !== MENU_ID) return;
  const url = info.linkUrl || info.srcUrl;
  submit({ url, pageUrl: info.pageUrl, fileName: null, source: "contextMenu" });
});

// Automatic capture: pause the browser's download, offer it to the app, and only cancel it
// in the browser once the app has accepted it. If the app is unavailable, the browser continues.
api.downloads.onCreated.addListener(async (item) => {
  const settings = await getSettings();
  if (!OLEDM.shouldIntercept(item, settings)) return;
  const url = item.finalUrl || item.url;
  try { await api.downloads.pause(item.id); } catch (_) { /* may already be finished */ }
  const message = OLEDM.buildAddDownload({
    url, pageUrl: item.referrer, fileName: OLEDM.baseName(item.filename), mode: settings.mode, source: "interception", browser: BROWSER,
  });
  let accepted = false;
  if (recent.checkAndAdd(url)) {
    try {
      const reply = await sendNative(message);
      accepted = reply && reply.type === "downloadAccepted";
    } catch (_) {
      accepted = false;
    }
  }
  try {
    if (accepted) {
      await api.downloads.cancel(item.id);
      await api.downloads.erase({ id: item.id });
      await flashBadge(true);
    } else {
      await api.downloads.resume(item.id);
    }
  } catch (_) { /* the download may have completed or been removed meanwhile */ }
});

api.runtime.onMessage.addListener((request, _sender, sendResponse) => {
  if (!request || typeof request !== "object") return false;
  if (request.kind === "status") {
    sendNative(OLEDM.buildStatusRequest(BROWSER), 5000)
      .then((reply) => sendResponse({ connected: !!(reply && reply.connected), reply }))
      .catch((error) => sendResponse({ connected: false, error: String(error && error.message || error) }));
    return true;
  }
  if (request.kind === "submit") {
    submit({ url: request.url, pageUrl: null, fileName: null, source: "popup" }).then(sendResponse);
    return true;
  }
  return false;
});
