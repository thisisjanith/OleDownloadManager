"use strict";
const api = globalThis.browser ?? globalThis.chrome;
const $ = (id) => document.getElementById(id);

async function load() {
  const stored = await api.storage.local.get("settings");
  const s = Object.assign({}, OLEDM.DEFAULT_SETTINGS, stored.settings || {});
  $("intercept").checked = s.interceptEnabled;
  $("mode").value = s.mode;
  $("extensions").value = s.extensions.join(", ");
}

async function save() {
  const settings = {
    interceptEnabled: $("intercept").checked,
    mode: $("mode").value,
    extensions: OLEDM.normalizeExtensions($("extensions").value),
    minSizeKB: OLEDM.DEFAULT_SETTINGS.minSizeKB,
  };
  await api.storage.local.set({ settings });
}

async function refreshStatus() {
  const el = $("status");
  try {
    const res = await api.runtime.sendMessage({ kind: "status" });
    if (res && res.connected) {
      const capture = res.reply && res.reply.captureEnabled === false ? " (capture is off in the app)" : "";
      el.textContent = "Connected to OleDownloadManager" + capture;
      el.className = "status ok";
    } else if (res && res.reply && res.reply.code === "appNotRunning") {
      el.textContent = "OleDownloadManager is not running. It opens when you send a download.";
      el.className = "status bad";
    } else {
      el.textContent = "Not connected. Install the native host from the app's Settings › Browser.";
      el.className = "status bad";
    }
  } catch (_) {
    el.textContent = "Not connected.";
    el.className = "status bad";
  }
}

document.addEventListener("DOMContentLoaded", () => {
  load();
  refreshStatus();
  for (const id of ["intercept", "mode", "extensions"]) $(id).addEventListener("change", save);
  $("send").addEventListener("click", async () => {
    const url = $("url").value.trim();
    const res = await api.runtime.sendMessage({ kind: "submit", url });
    $("result").textContent = res ? res.text : "";
  });
});
