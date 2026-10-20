// Run with: node --test BrowserExtensions/tests
"use strict";
const test = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const crypto = require("node:crypto");
const OLEDM = require("../shared/logic.js");

const root = path.join(__dirname, "..");

test("only http(s) URLs are accepted", () => {
  assert.ok(OLEDM.isHttpUrl("https://example.com/a.zip"));
  assert.ok(OLEDM.isHttpUrl("http://example.com"));
  for (const bad of ["blob:https://x/1", "data:text/plain,hi", "file:///etc/passwd", "javascript:alert(1)", "ftp://x/y", "", null, "https://" + "a".repeat(9000)]) {
    assert.equal(OLEDM.isHttpUrl(bad), false, String(bad).slice(0, 40));
  }
});

test("base names and extensions", () => {
  assert.equal(OLEDM.baseName("/Users/me/Downloads/file.tar.gz"), "file.tar.gz");
  assert.equal(OLEDM.baseName("C:\\Users\\me\\x.exe"), "x.exe");
  assert.equal(OLEDM.baseName("https://e.com/dir/My%20File.dmg?x=1"), "My File.dmg");
  assert.equal(OLEDM.extensionOf("archive.TAR.GZ"), "gz");
  assert.equal(OLEDM.extensionOf("README"), "");
  assert.equal(OLEDM.extensionOf(".hidden"), "");
});

test("interception is limited to configured, explicit http downloads", () => {
  const base = { url: "https://e.com/a.zip", filename: "/Users/me/Downloads/a.zip", incognito: false, totalBytes: 5e6 };
  assert.ok(OLEDM.shouldIntercept(base, {}));
  assert.equal(OLEDM.shouldIntercept(base, { interceptEnabled: false }), false);
  assert.equal(OLEDM.shouldIntercept({ ...base, incognito: true }, {}), false);
  assert.equal(OLEDM.shouldIntercept({ ...base, url: "blob:https://e.com/1", filename: "a.zip" }, {}), false);
  assert.equal(OLEDM.shouldIntercept({ ...base, url: "https://e.com/page.html", filename: "page.html" }, {}), false);
  assert.equal(OLEDM.shouldIntercept({ ...base, byExtensionId: "other" }, {}), false);
  assert.equal(OLEDM.shouldIntercept({ ...base, totalBytes: 1000 }, { minSizeKB: 100 }), false);
  assert.ok(OLEDM.shouldIntercept({ ...base, filename: "", finalUrl: "https://cdn.e.com/x.iso" }, {}));
  assert.ok(OLEDM.shouldIntercept({ ...base, filename: "a.custom" }, { extensions: ["custom"] }));
});

test("add message follows protocol v1", () => {
  const m = OLEDM.buildAddDownload({ url: "https://e.com/a.zip", pageUrl: "https://e.com/", fileName: "../../a.zip", mode: "queue", source: "interception", browser: "chrome" });
  assert.equal(m.v, 1);
  assert.equal(m.type, "addDownload");
  assert.match(m.id, /^[A-Za-z0-9_-]{1,64}$/);
  assert.equal(m.fileName, "a.zip");
  assert.equal(m.mode, "queue");
  assert.equal(m.referrer, "https://e.com/");
  assert.equal(m.origin, undefined, "the extension never claims an origin; the host adds it");
  const m2 = OLEDM.buildAddDownload({ url: "https://e.com/a", pageUrl: "chrome://newtab", mode: "weird" });
  assert.equal(m2.pageUrl, undefined);
  assert.equal(m2.mode, "default");
});

test("duplicate suppression window", () => {
  let now = 0;
  const set = OLEDM.createRecentSet(10000, () => now);
  assert.ok(set.checkAndAdd("u"));
  assert.equal(set.checkAndAdd("u"), false);
  now = 10001;
  assert.ok(set.checkAndAdd("u"));
});

test("extension list normalization", () => {
  assert.deepEqual(OLEDM.normalizeExtensions(".ZIP, dmg;  iso  bad/ext, toolongextension"), ["zip", "dmg", "iso"]);
});

test("reply descriptions", () => {
  assert.equal(OLEDM.describeReply({ type: "downloadAccepted", fileName: "a.zip" }).ok, true);
  assert.equal(OLEDM.describeReply({ type: "status", connected: false, code: "appNotRunning" }).text, "OleDownloadManager is not running.");
  assert.equal(OLEDM.describeReply(null).ok, false);
});

test("Chrome manifest key matches the extension ID allowed by the native host", () => {
  const manifest = JSON.parse(fs.readFileSync(path.join(root, "Chrome/manifest.json"), "utf8"));
  const der = Buffer.from(manifest.key, "base64");
  const hex = crypto.createHash("sha256").update(der).digest("hex").slice(0, 32);
  const id = [...hex].map((c) => String.fromCharCode(97 + parseInt(c, 16))).join("");
  assert.equal(id, "adndpcefokbkijmccnbhfkhllcpedgfj");
  const swift = fs.readFileSync(path.join(root, "../Sources/OleBrowserBridge/BrowserMessage.swift"), "utf8");
  assert.ok(swift.includes(id));
  const firefox = JSON.parse(fs.readFileSync(path.join(root, "Firefox/manifest.json"), "utf8"));
  assert.ok(swift.includes(firefox.browser_specific_settings.gecko.id));
});

test("manifests request only the minimum permissions", () => {
  for (const b of ["Chrome", "Firefox"]) {
    const m = JSON.parse(fs.readFileSync(path.join(root, b, "manifest.json"), "utf8"));
    assert.deepEqual([...m.permissions].sort(), ["contextMenus", "downloads", "nativeMessaging", "storage"]);
    assert.equal(m.host_permissions, undefined);
    assert.equal(m.content_scripts, undefined);
  }
});

test("browser folders are in sync with shared sources", () => {
  for (const b of ["Chrome", "Firefox"]) {
    for (const f of ["logic.js", "background.js", "popup.html", "popup.css", "popup.js"]) {
      assert.equal(fs.readFileSync(path.join(root, b, f), "utf8"), fs.readFileSync(path.join(root, "shared", f), "utf8"), `${b}/${f} is stale; run Scripts/sync-extensions.sh`);
    }
  }
});
