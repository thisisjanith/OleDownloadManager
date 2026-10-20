# Architecture

OleDownloadManager is split into a UI-free core (a Swift package) and a thin SwiftUI app. Networking, persistence and file handling never live in views.

```
┌──────────────────────── OleDownloadManager.app ────────────────────────┐
│ App/ (SwiftUI)                                                          │
│   OleDownloadManagerApp · AppDelegate · AppModel · UI/* · Services/*    │
│        │ observes / calls                                               │
│        ▼                                                                │
│ OleDownloadCore (Swift package library)                                 │
│   DownloadCoordinator (@MainActor) ── QueueScheduler, ScheduleEvaluator │
│        │            │             │                │                    │
│        ▼            ▼             ▼                ▼                    │
│   DownloadEngine  DownloadStore  DestinationManager  SecretStore        │
│   (HTTP engine)   (SQLite repo)  FileFinalizer       (Keychain)         │
│        │                                                                │
│   BrowserBridgeService ── OleBrowserBridge (protocol, framing, IPC)     │
│ Contents/Helpers/OleNativeHost  ◀── stdin/stdout ──  Chrome / Firefox   │
└─────────────────────────────────────────────────────────────────────────┘
```

## Modules

| Path | Responsibility |
| --- | --- |
| `Sources/OleDownloadCore/Models` | `DownloadRecord` (persisted model), `DownloadItem` (observable wrapper), `DownloadState`, `DownloadSegment` and `SegmentPlanner`, `AppSettings`, `FileCategory`. |
| `Sources/OleDownloadCore/Engine` | `DownloadStateMachine`, `DownloadCoordinator`, the HTTP engine (`SegmentedDownloadEngine.swift`, `HTTPTransport.swift`, `TransferProgress.swift`), `RetryPolicy`, `DownloadError`, `URLValidator` and `RedirectPolicy`, header parsers, `BandwidthLimiter`, `MetadataProbe`. |
| `Sources/OleDownloadCore/Queue` | `QueueScheduler` (which items may start) and `ScheduleEvaluator` (weekly start/stop). |
| `Sources/OleDownloadCore/Persistence` | `SQLiteDatabase` (thin C API wrapper), `DatabaseMigrations`, `DownloadRepository` (`DownloadStore` protocol). |
| `Sources/OleDownloadCore/FileSystem` | `DestinationManager` (availability, external volumes, category and partial folders), `DiskSpace`, `FileFinalizer` (conflicts, atomic move, quarantine), `IntegrityVerifier` (SHA-256), `FileNameSanitizer`. |
| `Sources/OleDownloadCore/BrowserIntegration` | `BrowserBridgeService` (app-side IPC listener) and `NativeHostInstaller` (manifest registration). |
| `Sources/OleDownloadCore/Services` | `SpeedMonitor`, `SecretStore` (Keychain and in-memory), `Redactor`, `AppLog`. |
| `Sources/OleBrowserBridge` | Versioned message types and validation, length-prefixed framing, the Unix-socket client and server. Shared by the app and the host. |
| `Sources/OleNativeHost` | Native messaging host executable launched by browsers. |
| `App/` | SwiftUI scenes and views, `AppModel` (UI state), notifications, launch at login, app lifecycle. |
| `BrowserExtensions/` | Shared extension source, Chrome and Firefox folders, Node tests. |

Dependencies are only Apple frameworks plus the system `libsqlite3`. XcodeGen is a development tool used to generate the Xcode project from `project.yml`.

## Concurrency model

- **`DownloadCoordinator` is `@MainActor`.** All state changes, scheduling decisions and job bookkeeping happen there. `QueueScheduler.selectToStart` runs synchronously and jobs are registered before it returns, so two scheduling passes can never start more than the concurrency limit.
- **Transfers run off the main actor.** The engine's `download(...)` is a nonisolated `async` function. Each run owns one `URLSession` with a serial delegate queue, and data is written to disk from that queue.
- **Progress is polled, not pushed.** Writers update a lock-protected `TransferProgress`. The coordinator reads a snapshot four times per second, which bounds UI updates regardless of throughput.
- **Database writes go through one serial queue in `DownloadRepository`.** Writes are asynchronous and applied in order, and `flush()` is used at shutdown.
- **Each download is one `Task` owned by the coordinator.** Pausing or canceling cancels that task. Structured child tasks (segments) are canceled with it, and the engine waits for URLSession to drain before closing the file.

## Download state machine

`DownloadStateMachine` is the single table of legal transitions. Every change in the coordinator goes through it; illegal transitions are bugs (asserted in debug builds).

```
            ┌────────────── restart (explicit user action only) ───────────────┐
            ▼                                                                   │
 queued ─▶ connecting ─▶ downloading ─▶ verifying ─▶ completed            canceled
   │  ▲        │  │           │  │           │                                ▲
   │  │        │  └─▶ retrying ◀─┘           └─▶ failed / interrupted         │
   │  │        │        │                                                     │
   │  └────────┴── paused, interrupted, waitingForDestination, failed ───────┤
   └──────────────────────────── cancel from any non-terminal state ─────────┘
```

| From | Allowed targets |
| --- | --- |
| queued | connecting, paused, canceled, waitingForDestination, failed |
| connecting | downloading, verifying, failed, paused, canceled, retrying, interrupted, waitingForDestination, queued |
| downloading | verifying, paused, failed, retrying, interrupted, canceled, waitingForDestination, queued, connecting |
| verifying | completed, failed, canceled, interrupted, waitingForDestination |
| retrying | connecting, paused, canceled, failed, queued, interrupted |
| paused | connecting, queued, canceled |
| failed | queued, connecting, canceled |
| interrupted | queued, connecting, paused, canceled, failed |
| waitingForDestination | queued, connecting, paused, canceled, failed |
| completed | none (terminal) |
| canceled | queued, reached only through "Restart" |

User-visible labels: Waiting, Connecting, Downloading, Verifying, Completed, Paused, Failed, Retrying, Interrupted, Waiting for destination, Canceled. When a stop request arrives in a state that cannot reach the requested target (for example Verifying → Paused), the download settles in Interrupted, which can always be resumed.

## Download engine

`HTTPDownloadEngine` handles single-connection and segmented transfers through one code path.

1. **Fresh start.** The engine sends `GET` with `Range: bytes=0-` and `Accept-Encoding: identity`.
   - A `206` with `Content-Range: bytes 0-(N-1)/N` proves range support and gives the size N.
   - A `200` means the server ignored the range. If the size is known, a one-byte probe (`bytes=N-1-N-1`) checks whether ranges really work, because `Accept-Ranges` alone is not trusted.
   - Any `Content-Encoding` other than identity disables ranges.
2. **Planning.** When ranges are confirmed and every segment would be at least 1 MiB, `SegmentPlanner.plan` splits `[0, N)` into up to `maxConnections` contiguous, non-overlapping inclusive ranges. Lengths differ by at most one byte. A 100 MiB file with four segments produces exactly `0–26,214,399`, `26,214,400–52,428,799`, `52,428,800–78,643,199` and `78,643,200–104,857,599`. The already-open first connection becomes segment 0 and is cut off at its end. Segmentation is also skipped when credentials are in use and a redirect changed the host.
3. **Segments.** Each segment requests `bytes=<next>-<end>` with `If-Range` (a strong ETag, else Last-Modified) against the post-redirect URL. Before writing a byte, the response must be a `206` whose `Content-Range` starts exactly at the requested offset, ends within the segment, reports the same total, and carries validators that don't conflict.
   - A `200` reply means the server ignored the range, or the file changed if the validators differ.
   - Short `206` replies are continued with further requests.
   - `RangeWriter` truncates anything beyond the segment, so a connection can never write outside its range.
4. **Writing.** All connections write with `pwrite` at explicit offsets into one partial file, through `PartialFile`. A lock guards writes against `close`, so a late callback can never write into a reused file descriptor. Data is never merged by arrival order.
5. **Failures inside a run.**
   - Transient segment errors are retried a few times from the segment's current offset.
   - 429 and 503 replies reduce the number of parallel connections.
   - An inconsistent range response restarts the download over one plain connection.
   - A changed source restarts once from zero. If the validators keep changing, the engine continues over one plain connection.
   - Anything else ends the run, and the coordinator's job-level retry policy takes over.
6. **Checkpoints.** Every 2 seconds the engine captures the segment counters, `fsync`s the file, and publishes the captured counters as durable. On pause or cancel, the session is invalidated and drained, then the file is fsync'ed and closed, and only then is the final state published. The coordinator persists only durable counters, so the database never claims bytes that are not on disk.
7. **Completion.** The file size must equal the announced size, and every segment must be complete. When the size is unknown, the byte count at the end of a successful transfer is used.

**Resume** reuses `ResumeState` (validators, size, segments). The first remaining segment is requested from the original URL, following redirects again in case a signed mirror URL expired, and must prove the same representation. Saved progress is discarded when:

- the partial file is missing or shorter than the bytes it claims,
- the segments don't tile the file, or
- the server no longer supports ranges.

**Why not `URLSessionDownloadTask` resume data?** That data is opaque, cannot be validated, may become unusable, and keeps its partial file in a system temporary folder, which could fill the startup disk when the destination is an external drive. One explicit range engine gives verifiable, persistable state for both single and multi-connection downloads. Streaming uses a `URLSessionDataDelegate`, so large files never sit in memory.

**Speed limits.** A token bucket (`BandwidthLimiter`) is shared per download and globally. When over budget, the download's serial delegate queue waits in 50 ms slices. URLSession then stops reading, and TCP flow control slows the server.

**Transport rules.** These live in `TransferSession`:

- ephemeral configuration with no cookies, cache or credential storage;
- system TLS evaluation, never overridden;
- the redirect policy (see SECURITY.md), with sensitive headers stripped on cross-host redirects;
- Basic or Digest credentials answered only for the original host, and only once, so a wrong password produces a single 401.

## Coordinator responsibilities

`DownloadCoordinator` owns the following:

- **Adding downloads.** It runs duplicate and skip-policy checks, splits secrets out of the request, and assigns the queue position.
- **Launching jobs.** Before calling the engine it checks the destination (`DestinationManager.availability`, which never creates the root folder), resolves the partial folder, and checks free space.
- **Polling progress.** Four times a second it reads engine snapshots. `SpeedMonitor` turns them into a 5-second rolling speed, an exponential smoothing of it, and an ETA (only when the size is known).
- **Retries.** It applies `RetryPolicy`: exponential backoff with ±20 % jitter and `Retry-After` capped at 10 minutes. Retries are counted per attempt.
- **Finishing.** It verifies the file and computes SHA-256, compares the user's checksum if one was given, then finalizes: conflict policy, atomic exclusive rename, quarantine. Only then does the download become Completed and the completion notification fire.
- **Stopping.** Pause, requeue, cancel, trash, waiting for a destination, and shutdown are all handled after the job task has fully stopped.
- **Startup reconciliation.** Active states become Interrupted, partial files are checked, and invalid progress is reset. Restarting interrupted downloads needs explicit user action or the "Resume interrupted downloads when the app opens" setting.
- **Volume changes.** On mount and unmount it moves downloads between Waiting for destination and Queued.
- **Schedules.** Once a second it starts per-download scheduled items and evaluates the weekly queue schedule, and it does so again after wake.
- **Browser requests.** It validates incoming messages against the origin allowlist, the capture setting, a 10-second duplicate window, and the protocol rules.

## Persistence

SQLite via the system library, with WAL, `synchronous=NORMAL` and foreign keys on. Timestamps are stored as UTC Unix epoch seconds (`REAL`).

| Table | Contents |
| --- | --- |
| `downloads` | One row per download. Covers the source and final URL, name, destination root and volume UUID, final and partial paths, category, state, sizes, timestamps, retry count, HTTP status, ETag and Last-Modified, content type, range support, last error (JSON), SHA-256, expected SHA-256 and whether it matched, origin, page URL, referrer, non-sensitive custom headers (JSON), whether Keychain secrets exist, conflict policy, max connections, speed limit, start mode, queue position, scheduled time, average speed, and trash time. Completed rows are the history. |
| `download_segments` | Segment index, range start and end, and durable completed bytes. Deleted with their download. |
| `settings` | Key/value JSON. `AppSettings` decoding tolerates missing keys and clamps every number to a safe range. |
| `diagnostic_events` | Redacted per-download activity, capped at 5,000 rows. |

Migrations live in `DatabaseMigrations.all`. Each runs inside a transaction and bumps `PRAGMA user_version`. A database written by a newer version is refused with a clear error. State changes are written immediately. Progress is written only from durable checkpoints, at most every 2 seconds per download. Speed samples are never stored.

## Browser integration

```
Extension ──sendNativeMessage──▶ OleNativeHost ──Unix socket──▶ App (BrowserBridgeService → coordinator)
          ◀────── reply ───────               ◀─── reply ────
```

Both hops use the native messaging framing: a 4-byte little-endian length, then UTF-8 JSON, with each message capped at 64 KiB.

**Protocol v1.** Every message has `v` (1), `type` and an optional `id` (up to 64 characters from `[A-Za-z0-9_-]`).

| Type | Direction | Fields |
| --- | --- | --- |
| `hello` | extension → app | `browser`, `extensionVersion` |
| `getStatus` | extension → app | none |
| `addDownload` | extension → app | `url` (http/https, ≤ 8 KiB, required), `pageUrl`, `referrer`, `fileName` (≤ 1024 characters, sanitized by the app), `mode` (`start` / `queue` / `default`), `source` (`contextMenu` / `interception` / `popup`) |
| `status` | app → extension | `connected`, `captureEnabled`, `captureAction`, `appVersion`. Sent as `connected:false` with `code: appNotRunning` when the host cannot reach the app. |
| `downloadAccepted` | app → extension | `downloadId`, `fileName` |
| `downloadRejected` | app → extension | `reason` (`duplicate`, `captureDisabled`, `invalidURL`, `rejected`), `message` |
| `error` | app or host → extension | `code` (`malformed`, `unsupportedVersion`, `unknownType`, `notARequest`, `invalidField`, `unauthorizedOrigin`, `tooLarge`, `ipcFailure`, `appNotRunning`), `message` |

**The host's job.** `OleNativeHost`:

- reads the caller identity the browser passes on the command line (Chrome: the origin; Firefox: the extension ID) and exits unless it is on the allowlist;
- validates each message;
- overwrites `origin` with that identity, so an extension can never claim another identity;
- forwards the message and relays the reply.

For `addDownload`, the host launches the app in the background if it isn't running. stdout carries only protocol frames; diagnostics go to stderr.

**The app side.** `BrowserBridgeService` listens on `$(getconf DARWIN_USER_TEMP_DIR)/com.oledownloadmanager.app/ipc.sock`. The directory is mode 0700, the socket 0600, and the peer must have the same uid. Every request is validated again (`requireOrigin: true`) before the coordinator sees it.

To add another browser, add its manifest folder to `NativeHostInstaller.Browser` and `install-browser-host.sh`, and add its extension identity to `BrowserProtocol`.

## App layer

- **`AppModel`** holds UI state (sidebar filter, search, sort, selection, sheets, confirmations) and forwards actions to the coordinator. It also performs Finder actions and reads the UI-test fixtures (`-UITestMode`, `OLEDM_DATA_DIR`, `OLEDM_DOWNLOAD_DIR`, `OLEDM_CHOOSE_FOLDER`).
- **`AppDelegate`** handles graceful termination: it pauses transfers, persists checkpoints and flushes the database before replying to `applicationShouldTerminate`. It also observes volume mount/unmount and wake notifications.
- **Scenes.** The app has a single main `Window` (restored by the system), the `Settings` scene, and an optional `MenuBarExtra`.
