# OleDownloadManager

A native macOS download manager in the spirit of Internet Download Manager, built with Swift 6 and SwiftUI.
It downloads HTTP and HTTPS files with pause and resume, optional multi-connection (segmented) transfers,
a persistent queue with scheduling, Chrome and Firefox integration, and a SQLite-backed history.

- **Bundle identifier:** `com.oledownloadmanager.app`
- **Requires:** macOS 14 Sonoma or later. Apple Silicon and Intel (release builds are universal).
- **License:** MIT

## Features

### Implemented

| Area | What works |
| --- | --- |
| Downloads | HTTP/HTTPS with streaming writes (never whole files in memory), progress, current and smoothed speed, ETA, total and received bytes. Unknown-size downloads show bytes only. |
| Pause and resume | Real pause that stops network activity. Resume uses `Range` + `If-Range` after validating ETag, Last-Modified and size. Falls back to a clean restart when the server can't resume or the file changed. |
| Segmented downloads | Up to 8 connections per file (default 4), used only after the server proves range support with a `206` and a matching `Content-Range`. Every response is checked before a byte is written; a misbehaving server triggers a single-connection fallback. Parallel connections are reduced when the server answers 429/503. |
| Reliability | Automatic retries with exponential backoff, jitter and `Retry-After`. Permanent errors (404, 401, 403, TLS, disk full) are not retried in a loop. Retry Now and Cancel are available while retrying. |
| Integrity | Size verification against the server's length and every segment. SHA-256 after each download (optional). Comparison with a checksum you supply. Files are only marked Completed after they are moved into place. |
| Files | Content-Disposition / URL / MIME-based names, sanitized against path traversal and spoofing. Conflict policy: keep both (numbered), replace (old file to Trash, with confirmation), or skip. Atomic no-overwrite finalize. Downloads are quarantine-tagged so Gatekeeper checks them. |
| Queue | Persistent queue, global concurrency limit, start/pause queue, resume all, move up/down, drag to reorder, per-download start time, weekly queue schedule with start/stop times. |
| Storage | Any folder, including external drives. If the drive is unplugged, downloads wait instead of writing elsewhere, and continue when it is reconnected. Free-space check before starting. Partial data stays on the destination drive. |
| History | SQLite database with migrations. Downloads, segments, queue order, settings and diagnostic events survive restarts. Interrupted transfers are restored as Interrupted and only restart automatically if you enable it. |
| Interface | Sidebar with live counts (status and categories), searchable and sortable list, multi-select, context menus enabled per state, details inspector with a segment map and activity log, toolbar, Settings window, menu bar item, notifications, launch at login, light/dark/system appearance, compact or comfortable rows. |
| Browser integration | Chrome and Firefox MV3 extensions with a context-menu action and filtered automatic capture, a native messaging host, and a versioned, validated JSON protocol. The host has been tested end to end against the running app (see [TESTING.md](TESTING.md)). |

### Partially implemented

- **Browser extensions.** The native host, the app side and the extension logic are tested. Loading the extensions in a real browser and capturing a live download is a manual checklist that has not been run yet. See the browser acceptance checklist in [TESTING.md](TESTING.md).
- **UI tests.** An XCUITest suite covers the main workflows and compiles. Running it requires approving macOS UI automation, which was not possible on the build machine.
- **Signing.** Builds are ad-hoc signed with the hardened runtime. Developer ID signing and notarization are scripted but need your credentials.

### Not yet implemented (planned)

- Dynamic segment splitting (letting a finished connection take over part of a slow one).
- Per-host connection limits, bandwidth schedules and speed presets.
- Clipboard monitoring, import/export of download lists, duplicate detection across history.
- Direct media detection in the browser, a floating progress window.
- Waking the Mac for scheduled downloads.

## Getting started

### Prerequisites

- macOS 14 or later, Xcode 16 or later (developed with Xcode 26.6 and Swift 6.3).
- Optional: [XcodeGen](https://github.com/yonaskolb/XcodeGen) to regenerate the project (`brew install xcodegen`).
- Optional: Node.js 18+ to run the browser extension tests.

Check your environment:

```sh
Scripts/doctor.sh
```

### Build and run

Open `OleDownloadManager.xcodeproj` in Xcode and run the **OleDownloadManager** scheme, or use the scripts:

```sh
Scripts/build.sh                  # Debug build
open build/DerivedData/Build/Products/Debug/OleDownloadManager.app
```

The project is generated from `project.yml`. After adding or removing files, run `xcodegen generate`.
The engine, persistence and browser bridge live in the Swift package at the repository root and can be
built and tested without Xcode's UI:

```sh
swift build
swift test
```

### Run the tests

```sh
Scripts/test.sh          # Swift unit + integration tests and extension tests
Scripts/test.sh --ui     # also the XCUITest suite (requires UI automation approval)
```

See [TESTING.md](TESTING.md) for what is covered.

### Install a development build

```sh
Scripts/build.sh release
Scripts/install-dev.sh            # copies to ~/Applications (use --system for /Applications)
```

## Using the app

- **Add a download.** Press ⌘N, paste a link with ⌘V while the list is focused (or ⇧⌘V anywhere), or drag links onto the window. The Add Download sheet checks the link and shows the file name, size and whether it can resume.
- **Pause and resume.** Use the row buttons, the context menu, or Space. ⌘R retries a failed download.
- **Choose the download folder.** Open Settings (⌘,), then General › Download folder › Choose…. External drives work. Each download can also go to its own folder from the Add Download sheet, and "Ask where to save each file" prompts every time.
- **Queue.** "Add to Queue" downloads wait until you press Start Queue (or the schedule starts it). The number of simultaneous downloads is in Settings › Downloads.
- **Remove.** Delete moves items to Trash. Emptying Trash forgets them and removes partial data. Completed files stay on disk unless you choose otherwise.

## Browser integration

Browser integration is not automatic: the browser can only reach the app after the native messaging host is registered and the extension is loaded.

1. **Register the native host.** In the app, open Settings › Browser and click Install next to your browser, or run:
   ```sh
   Scripts/install-browser-host.sh --app /Applications/OleDownloadManager.app
   ```
   This writes `com.oledownloadmanager.native.json` into the browser's `NativeMessagingHosts` folder in `~/Library/Application Support`. Supported: Chrome, Chromium, Brave, Edge and Firefox.
2. **Load the extension.**
   - Chrome, Brave, Edge: open `chrome://extensions`, enable Developer mode, click "Load unpacked" and choose `BrowserExtensions/Chrome`. The extension ID must be `adndpcefokbkijmccnbhfkhllcpedgfj`. It is fixed by the key in the manifest and is the only ID the host accepts.
   - Firefox: open `about:debugging#/runtime/this-firefox`, click "Load Temporary Add-on…" and choose `BrowserExtensions/Firefox/manifest.json`. Temporary add-ons are removed when Firefox quits. A permanent install needs the add-on signed by Mozilla.
3. **Use it.** Right-click a link and choose "Download with OleDownloadManager". With automatic capture on, downloads of the file types listed in the extension's popup are handed to the app. If the app doesn't accept a download, the browser keeps downloading it itself.

To remove the integration, remove the extension in the browser and run `Scripts/install-browser-host.sh --uninstall` (or click Remove in Settings › Browser).

Browser cookies and sign-ins are never shared with the app. Links that only work in a signed-in browser session, and downloads produced by form submissions (POST), will fail in the app. Download those in the browser.

After changing files in `BrowserExtensions/shared`, run `Scripts/sync-extensions.sh` to update the Chrome and Firefox folders.

## Release builds and distribution

```sh
Scripts/build.sh release          # universal app in build/Release, hardened runtime
Scripts/package-dmg.sh            # dist/OleDownloadManager-<version>.dmg with an Applications shortcut
```

Without credentials the app is **ad-hoc signed and not notarized**. It runs on the Mac that built it. On other Macs, Gatekeeper blocks it until the user approves it under System Settings › Privacy & Security.

For public distribution you need a paid Apple Developer account:

1. Create a "Developer ID Application" certificate and install it in your keychain.
2. Store notarization credentials once:
   ```sh
   xcrun notarytool store-credentials OleDM --apple-id you@example.com --team-id TEAMID
   ```
3. Build, sign, notarize and staple:
   ```sh
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" Scripts/build.sh release
   SIGN_IDENTITY="Developer ID Application: Your Name (TEAMID)" NOTARY_PROFILE=OleDM Scripts/package-dmg.sh
   ```

The app uses the hardened runtime without extra entitlements and is not sandboxed (see [SECURITY.md](SECURITY.md) for why). It is intended for Developer ID distribution, not the Mac App Store. Never commit certificates, private keys or notarization passwords to the repository.

## Privacy

OleDownloadManager stores everything locally:

- **The database.** Download history, the queue, settings and diagnostic notes live in `~/Library/Application Support/OleDownloadManager/OleDownloadManager.sqlite`.
- **Secrets.** Passwords and Authorization/Cookie headers are never written to that database. They are kept in memory, or in your login Keychain only when you tick "Remember credentials".
- **Network traffic.** The only network requests are the ones needed to download the links you add, sent to the servers in those links.

There is no analytics, telemetry, advertising or tracking. The browser extensions send only the link you chose (plus the page URL as referrer) to the app on your Mac.

## Known limitations

- **Multiple connections don't always help.** Many servers serve HTTP/2, where URLSession multiplexes all connections over one TCP connection. Others throttle per client. Segmenting helps most on HTTP/1.1 servers with per-connection limits.
- **Some truncations can't be detected.** If a server sends neither a length nor chunked encoding and the connection drops, the truncation looks like the end of the file. The download is then completed with the bytes received.
- **Schedules need the app running.** Schedules only run while the app is open. If the Mac sleeps through the start time, the queue starts when it wakes, if the stop time has not passed. The app never wakes the Mac.
- **Some servers can't resume.** Downloads from servers without range support restart from the beginning after a pause or crash. The list shows "will restart" for these.
- **Restarted downloads need credentials again.** Credentials that were not saved to the Keychain are forgotten when the app quits, so such downloads ask for them again.
- **Visual review is still pending.** The UI was built and run, but screenshots could not be taken on the build machine. A visual pass on light and dark mode is part of the release checklist.

## Documentation

- [ARCHITECTURE.md](ARCHITECTURE.md): modules, state machine, engine, persistence and browser protocol.
- [SECURITY.md](SECURITY.md): threat model, secrets, URL and redirect rules, IPC and file safety.
- [TESTING.md](TESTING.md): test commands, scenarios, manual checklists and the release checklist.
