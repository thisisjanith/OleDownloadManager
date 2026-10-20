# Testing

## Commands

```sh
Scripts/test.sh                 # everything that runs headless: Swift package tests + extension tests
swift test                      # Swift unit and integration tests only
swift test --filter Engine      # one suite (by name)
node --test BrowserExtensions/tests
Scripts/test.sh --ui            # adds the XCUITest suite (see "UI tests" below)
```

No test uses the internet. Integration tests start a local HTTP server (`Tests/OleDownloadCoreTests/Support/TestHTTPServer.swift`, built on Network.framework and bound to `127.0.0.1` on a random port), whose behaviour is chosen per request with query parameters.

| Server option | What it simulates |
| --- | --- |
| `size`, `seed`, `version` | Deterministic file content (small, large, or a "replaced" file) |
| default `/file` | Known length, range-capable, with ETag and Last-Modified |
| `nolength=1` | No `Content-Length` (close-delimited body) |
| `ranges=0` | A server that ignores `Range` |
| `badrange=1` | Wrong `Content-Range` |
| `fail500=N` | Transient HTTP 500 for the first N requests |
| `/status/404`, `/status/401` | Permanent errors |
| `interruptAfter=N` | Connection dropped mid-body |
| `disposition=` | Content-Disposition with an RFC 5987 UTF-8 name |
| `/redirect?to=` | 302 redirect |
| `etag=changing` | A different ETag on every request |
| `maxParallel=N` | HTTP 503 when too many connections are open |
| `rangeLimit=N` | Short `206` responses |
| `chunkSize`, `delayMs` | Slow streaming, for pause, cancel and restart tests |

## Automated coverage

Latest run: **113 Swift tests in 13 suites passed** (10 consecutive full runs clean), **10 Node tests passed**. The UI test target (8 tests) compiles but was not executed. See below.

| Suite | Scenarios |
| --- | --- |
| State machine | Happy path, every legal and illegal transition listed in the spec, `completed` is terminal, `canceled` only restarts through `queued`. |
| URL validation | Accepted and rejected schemes, malformed and over-long URLs, bare hosts, credentials embedded in the URL, private-address classification, redirect policy (downgrade, private network, scheme, count). |
| Header parsing | `Content-Range` (valid, `*`, unsatisfied, inverted, overflowing), Content-Disposition (quoted, token, RFC 5987 UTF-8 and Latin-1, escapes), validators and If-Range, `Retry-After` (seconds and HTTP date), custom header validation (reserved names, header injection). |
| File names | Sanitization table (traversal, separators, hidden files, control and bidi characters, Unicode normalization, CJK), 255-byte limit, name suggestion order, safe destination, numbering, category classification, log redaction. |
| Segments and speed | Exact 100 MiB / 4 example, tiling for odd sizes and counts (including 1 TiB), invalid tilings, connection count, rolling-window speed, degenerate samples (zero time, reset counter, `Int64.max`), ETA and progress (no invented percentage). |
| Retry policy | Backoff with deterministic jitter, the cap, overflow safety, `Retry-After` priority and cap, which errors are retried (5xx, 408, 429, network and DNS) and which are not (404, 401, 403, TLS, disk full). |
| Persistence | Fresh migration, upgrade from v1 with data kept, refusing a newer schema, rollback of a failed migration, every field round-tripped, secrets excluded, progress and queue order updates, cascade delete, no duplicate rows, settings persisted, clamped and tolerant of missing keys, diagnostic events. |
| Destinations and finalization | Conflict rename, replace (old file to Trash), skip never drops downloaded data, hostile name can't escape the folder, quarantine applied, missing volume never created, volume UUID mismatch, category and partial folders, disk-space estimate, streaming SHA-256. |
| HTTP engine (local server) | Small file; segmented download byte-identical to a single connection (odd size, 4 connections); server ignoring `Range`; unknown length; wrong `Content-Range` falls back to a single connection; transient 500; interrupted connection resumes at the exact offset; 404 permanent; 401 reported once; Content-Disposition name; redirect; 503 throttling of parallel connections; short range responses; pause and resume without duplicated or skipped bytes; source changed between runs restarts cleanly; changing ETags; zero-length file; speed limit. |
| Coordinator | Downloads to the chosen folder, persists history across a relaunch, cleans up partial data; pause and resume (bytes frozen while paused; live speed, ETA and progress); cancel deletes partial data, canceled items never auto-start, restart; permanent failure not retried; transient failure retried with backoff; manual retry; queue concurrency limit (never above 2 with 5 items) and order after reordering; pause queue; conflict rename; skip policy; duplicate URL; interrupted download survives relaunch and resumes without restarting from zero; opt-in auto resume; queue order survives relaunch; missing destination waits, is never created, and resumes when it appears; checksum mismatch and match; organize by category; trash, restore and empty trash keep completed files; credentials never reach the raw database file; browser requests (hello, accept with sanitized name, duplicate, unauthorized origin, capture disabled); database consistent after errors. |
| Queue scheduling | Limits and order, stopped queue, per-download start times, moving, weekly schedule start and stop, sleeping through boundaries, weekdays, next start. |
| Browser protocol and host | Valid and invalid messages (version, type, URL scheme, mode, source, id), malformed and oversized input, origin allowlist (Chrome and Firefox), framing round trip and size cap, IPC server permissions and round trip, app not running. Manifest install and remove. **The real `OleNativeHost` executable** driven exactly like a browser: relays to the app and overwrites a spoofed origin, rejects `file://` locally, refuses unlisted extensions, accepts Firefox's arguments, reports when the app is not running. |
| Extension logic (Node) | URL filtering, base names and extensions, interception filter (private windows, blob, file types, size, other extensions), protocol v1 message shape, duplicate window, extension list parsing, reply descriptions, Chrome key → extension ID matches the host allowlist, minimal manifest permissions, Chrome and Firefox folders in sync with the shared source. |

## Manual end-to-end check performed

The universal Release build ran with an isolated data folder against `Scripts/dev-server.py`. The embedded native host was driven with the exact frames Chrome sends.

- **Status.** `hello` returned connected, capture enabled and the app version.
- **A real download.** `addDownload` was accepted. The 6 MB file downloaded over four parallel range connections, completed with a SHA-256 hash, and carries the `com.apple.quarantine` attribute.
- **Hostile name.** A browser-supplied name of `../../../../etc/evil.zip` was saved as `evil.zip` inside the download folder.
- **Rejections.** A duplicate submission was rejected, and a `file:///etc/passwd` URL was rejected by the host.
- **Earlier debug run, before the destination fix in this run.** Several downloads, a 404, conflict renaming (`Album (1).zip`) and queued items behaved correctly. That run had no isolated download folder, so its test files landed in the real Downloads folder and were moved to the Trash afterwards.

## UI tests

`Tests/OleDownloadManagerUITests` covers:

- add a URL, start it, and open the completed file;
- pause and resume;
- cancel and delete partial data;
- retry a failed download;
- search and sidebar filtering;
- history after a relaunch;
- changing the download folder;
- settings persisted across a relaunch.

Each test launches the app with `-UITestMode`, a temporary database (`OLEDM_DATA_DIR`) and a temporary download folder (`OLEDM_DOWNLOAD_DIR`), against the same local test server. In this mode notifications and the browser bridge are off, retries are disabled (`OLEDM_MAX_RETRIES`), Finder actions are recorded instead of performed, and the folder picker returns `OLEDM_CHOOSE_FOLDER`. These are explicit test fixtures. Waits use XCTest predicates, not fixed sleeps.

**Status: compiled, not yet executed.** The test runner requires macOS UI automation. On the build machine macOS asked for an administrator to authenticate ("Authentication canceled. System authentication is running"), and nobody was there to approve it. To run them:

```sh
sudo automationmodetool enable-automationmode-without-authentication   # once, or approve the prompt
Scripts/test.sh --ui
```

## Manual test checklist

Use `python3 Scripts/dev-server.py` (port 8765) for controllable files, for example `http://127.0.0.1:8765/file/Big.iso?size=200000000&rate=3000000`.

- [ ] Light, dark and system appearance; compact and comfortable rows; sidebar counts update live.
- [ ] VoiceOver reads rows as "name, status, percent, speed"; the list, toolbar and sheet are reachable with the keyboard.
- [ ] ⌘N, ⌘V (list focused), ⇧⌘V, Space, Delete, ⌘R, ⌥⌘I, ⌘, all work.
- [ ] Drag a link from a browser onto the list.
- [ ] Start a large download on an external drive, eject the drive: the download shows "Waiting for destination", nothing is written to `/Volumes`. Reconnect: it continues.
- [ ] Quit (⌘Q) during a download, relaunch: it shows Interrupted; Resume continues from the saved position.
- [ ] Turn Wi-Fi off during a download: it retries with a countdown, then fails with a readable message; Retry works when online.
- [ ] A notification appears for completion and failure after granting permission; denying permission causes no errors.
- [ ] Settings › General › Open at login registers the app (System Settings › General › Login Items).
- [ ] Menu bar item shows active downloads and can start or pause the queue.
- [ ] Opening a downloaded `.dmg` or `.app` shows the Gatekeeper "downloaded from the internet" prompt.

## Browser integration acceptance checklist

Browser integration counts as complete only when every item below has passed in a real browser. **Status: not yet run.** The host, protocol and app side are covered by automated tests. Chrome is installed on the build machine, but loading an unpacked extension requires interactive steps. Firefox is not installed.

Chrome (and Brave or Edge):

- [ ] Settings › Browser › Install for Google Chrome shows "Host installed".
- [ ] `chrome://extensions` › Load unpacked › `BrowserExtensions/Chrome`; the ID is `adndpcefokbkijmccnbhfkhllcpedgfj`.
- [ ] The popup says "Connected to OleDownloadManager" while the app runs, and "not running" after quitting it.
- [ ] Right-click a link › "Download with OleDownloadManager" → it appears in the app; the badge shows ✓.
- [ ] Same link again within 10 seconds → no second entry.
- [ ] With capture on, clicking a `.zip` link → the browser download disappears and the app downloads it.
- [ ] With the app quit, the same click launches the app and hands over the download. If the app is unavailable, the browser download resumes instead of being lost.
- [ ] Clicking an `.html` link or any ordinary link is never captured; private windows are never captured.
- [ ] Capture off in the popup, or in the app's Settings › Browser → downloads stay in the browser.
- [ ] "Uninstall" in the app, or `Scripts/install-browser-host.sh --uninstall`, removes the manifest; the popup reports "not installed".

Firefox:

- [ ] Same steps with `about:debugging` › Load Temporary Add-on › `BrowserExtensions/Firefox/manifest.json`.

## Release checklist

1. `Scripts/doctor.sh`: confirm Xcode, the SDK and the signing identity.
2. `Scripts/test.sh` all green; `Scripts/test.sh --ui` on a machine with UI automation enabled.
3. Bump `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml` and the extension manifests; run `xcodegen generate`.
4. `SIGN_IDENTITY="Developer ID Application: …" Scripts/build.sh release`; confirm `codesign -dv` shows `runtime` and `lipo -archs` shows `x86_64 arm64`.
5. `SIGN_IDENTITY=… NOTARY_PROFILE=… Scripts/package-dmg.sh`; confirm `spctl -a -t open --context context:primary-signature -v dist/*.dmg` reports "accepted, Notarized Developer ID".
6. Install from the DMG on a clean Mac or user account; run the manual and browser checklists.
7. Tag the release and attach the DMG.
