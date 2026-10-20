// Pure helpers shared by the background script and the tests. No browser APIs in here.
"use strict";

const OLEDM = {
  PROTOCOL_VERSION: 1,
  HOST_NAME: "com.oledownloadmanager.native",
  MAX_URL_LENGTH: 8192,
  DUPLICATE_WINDOW_MS: 10000,

  DEFAULT_SETTINGS: {
    // Automatic capture only applies to the file types below; ordinary links are never touched.
    interceptEnabled: true,
    // "default" = use the app's setting, "start" = start immediately, "queue" = add to queue.
    mode: "default",
    extensions: [
      "zip", "rar", "7z", "tar", "gz", "tgz", "bz2", "xz", "iso", "dmg", "pkg", "exe", "msi",
      "deb", "rpm", "apk", "mp4", "mkv", "mov", "avi", "webm", "mp3", "flac", "wav", "m4a", "pdf",
    ],
    // Skip automatic capture for files smaller than this (when the browser knows the size).
    minSizeKB: 0,
  },

  isHttpUrl(value) {
    if (typeof value !== "string" || value.length === 0 || value.length > OLEDM.MAX_URL_LENGTH) return false;
    try {
      const u = new URL(value);
      return (u.protocol === "http:" || u.protocol === "https:") && u.hostname.length > 0;
    } catch (_) {
      return false;
    }
  },

  /** Last path component of a browser file path or URL, without directories. */
  baseName(pathOrUrl) {
    if (!pathOrUrl) return "";
    let s = String(pathOrUrl);
    if (OLEDM.isHttpUrl(s)) {
      try { s = decodeURIComponent(new URL(s).pathname); } catch (_) { s = new URL(s).pathname; }
    }
    const parts = s.split(/[\\/]/);
    return parts[parts.length - 1] || "";
  },

  extensionOf(name) {
    const base = OLEDM.baseName(name).toLowerCase();
    const dot = base.lastIndexOf(".");
    return dot > 0 ? base.slice(dot + 1) : "";
  },

  normalizeExtensions(text) {
    return String(text || "")
      .split(/[\s,;]+/)
      .map((e) => e.trim().replace(/^\.+/, "").toLowerCase())
      .filter((e) => /^[a-z0-9]{1,10}$/.test(e));
  },

  /**
   * Decides whether a browser download should be handed to the app.
   * Only explicit http(s) downloads of configured file types, outside private windows.
   */
  shouldIntercept(item, settings) {
    const s = Object.assign({}, OLEDM.DEFAULT_SETTINGS, settings || {});
    if (!s.interceptEnabled || !item) return false;
    if (item.incognito) return false;
    const url = item.finalUrl || item.url;
    if (!OLEDM.isHttpUrl(url)) return false;            // skips blob:, data:, file:, ftp:
    if (item.byExtensionId) return false;               // downloads started by other extensions
    const name = OLEDM.baseName(item.filename) || OLEDM.baseName(url);
    const ext = OLEDM.extensionOf(name);
    if (!ext || !s.extensions.includes(ext)) return false;
    const size = item.totalBytes > 0 ? item.totalBytes : (item.fileSize > 0 ? item.fileSize : 0);
    if (size > 0 && s.minSizeKB > 0 && size < s.minSizeKB * 1024) return false;
    return true;
  },

  newRequestId() {
    const r = Math.random().toString(36).slice(2, 10);
    return "r" + Date.now().toString(36) + r;
  },

  buildAddDownload({ url, pageUrl, fileName, mode, source, browser }) {
    const msg = { v: OLEDM.PROTOCOL_VERSION, type: "addDownload", id: OLEDM.newRequestId(), url, source: source || "contextMenu" };
    if (OLEDM.isHttpUrl(pageUrl)) {
      msg.pageUrl = pageUrl;
      msg.referrer = pageUrl;
    }
    const name = OLEDM.baseName(fileName);
    if (name) msg.fileName = name.slice(0, 1024);
    msg.mode = ["start", "queue", "default"].includes(mode) ? mode : "default";
    if (browser) msg.browser = browser;
    return msg;
  },

  buildStatusRequest(browser) {
    return { v: OLEDM.PROTOCOL_VERSION, type: "getStatus", id: OLEDM.newRequestId(), browser };
  },

  /** Remembers recently sent URLs so double clicks or repeated events do not submit twice. */
  createRecentSet(windowMs = OLEDM.DUPLICATE_WINDOW_MS, now = () => Date.now()) {
    const seen = new Map();
    return {
      checkAndAdd(key) {
        const t = now();
        for (const [k, at] of seen) if (t - at > windowMs) seen.delete(k);
        if (seen.has(key)) return false;
        seen.set(key, t);
        return true;
      },
    };
  },

  /** Human-readable summary of an app reply for the badge/popup. */
  describeReply(reply) {
    if (!reply || typeof reply !== "object") return { ok: false, text: "No reply from OleDownloadManager." };
    if (reply.type === "downloadAccepted") return { ok: true, text: "Sent to OleDownloadManager" + (reply.fileName ? ": " + reply.fileName : ".") };
    if (reply.type === "downloadRejected") return { ok: false, text: reply.message || "OleDownloadManager declined the link." };
    if (reply.code === "appNotRunning") return { ok: false, text: "OleDownloadManager is not running." };
    return { ok: false, text: reply.message || "Unexpected reply." };
  },
};

if (typeof module !== "undefined" && module.exports) module.exports = OLEDM;
