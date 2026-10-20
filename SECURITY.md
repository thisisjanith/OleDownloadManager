# Security

This document describes what OleDownloadManager protects against, how, and where the limits are.

## Threat assumptions

| Source | Trusted? | Notes |
| --- | --- | --- |
| Servers and everything they send (headers, file names, redirects, content) | No | Treated as hostile input. |
| URLs typed, pasted, dropped or received from a browser | No | Validated before use. |
| Browser extensions and web pages | No | Only the two registered extension identities may talk to the app, and every message is validated twice: in the host and in the app. A web page cannot reach the app directly. |
| Other local user accounts | No | They can't reach the IPC socket or the data folder. |
| Processes running as the same user | Partly | They could already read the user's files or the database. We don't defend against them beyond peer-uid checks and input validation, but they can't bypass the validation that applies to the extensions. |
| Downloaded files | Never executed | The app does not open, run or inspect downloaded files. |

## Network and TLS

- **TLS is never weakened.** HTTPS certificate validation is always the system's default trust evaluation. The server-trust challenge is answered with `performDefaultHandling` and there is no setting to disable it.
- **Plain HTTP links are allowed, with a warning.** `NSAllowsArbitraryLoads` is set in Info.plist only so that user-supplied `http://` links can be downloaded. It doesn't disable certificate checks for HTTPS. The Add Download sheet warns when a link is unencrypted.
- **No cookies, no cache.** Sessions are ephemeral: no cookie storage, no URL cache, no credential storage.
- **Byte ranges stay consistent.** `Accept-Encoding: identity` is sent so that byte ranges refer to the file as stored.
- **Timeouts.** A connection timeout (time to first response) and a read timeout (time without data) are configurable within safe bounds.

## URL and redirect rules

- **Accepted URLs.** Only absolute `http` and `https` URLs with a host are accepted, up to 8 KiB, with no control characters. Every other scheme is rejected: `file:`, `ftp:`, `data:`, `javascript:`, `blob:`.
- **Credentials embedded in a URL are moved out.** `user:password@host` is removed from the URL and treated as credentials, so they are never stored in the database.
- **Redirects** (`RedirectPolicy`):
  - at most 10 redirects, and only to `http` or `https`;
  - an HTTPS → HTTP downgrade is blocked;
  - when the original host is public, redirects to loopback, private (RFC 1918, CGNAT, unique-local IPv6), link-local, `.local` or single-label hosts are blocked. This stops a website from using the app to probe services on your machine or network. Downloads you start yourself from a local address keep working. The check can be turned off in Settings › Network.
  - on any cross-host redirect, `Authorization`, `Cookie`, `Proxy-Authorization` and similar headers are removed.
- **Authentication.** Basic and Digest credentials are answered only when the challenge comes from the original host, and only once. A wrong password gives one clear 401 error instead of a retry loop. 401 and 403 are not retried automatically.
- **There is no local HTTP control server.** The app doesn't listen on any TCP port.

## Secrets

- **Stored in the Keychain, only with consent.** Passwords and sensitive headers (Authorization, Cookie, Proxy-Authorization, X-Api-Key, X-Auth-Token, X-CSRF-Token) are separated from the download record when it is added. They stay in memory for the session and are saved to the login Keychain only if the user ticks "Remember credentials". The Keychain item is a generic password with `AfterFirstUnlockThisDeviceOnly` and is deleted when the download completes or is removed.
- **Never written to SQLite.** The database stores only non-sensitive custom headers. A test inspects the raw database file to confirm secrets never appear in it.
- **Never in the repository.** No signing credentials, private keys or notarization passwords are stored in the repository, and `.gitignore` excludes certificate and key files. The Chrome extension manifest contains only a public key, which fixes the extension ID. The private key was discarded.

## Logging and diagnostics

- **Redaction.** Logs go through `os.Logger` with explicit privacy. URLs are logged only after `Redactor`, which masks user info and sensitive query parameters: tokens, signatures, keys, AWS/GCS/Azure signing parameters, session identifiers.
- **Bounded diagnostics.** Diagnostic events in the database are redacted the same way and capped at 5,000 rows.
- **Full URL in the details panel only.** The details inspector shows the full source URL, because it is the user's own data, but it is never logged unredacted.

## Browser IPC

- **The browser decides who may launch the host.** Chrome launches the host only for origins in the manifest's `allowed_origins` (one fixed extension ID), and Firefox only for IDs in `allowed_extensions`. The manifests are written only when the user clicks Install or runs the script.
- **The host checks again.**
  - It verifies the caller identity the browser passes on the command line and refuses to run for any other.
  - It overwrites the message's `origin` with that identity.
  - It validates the message: size ≤ 64 KiB, protocol version, known request type, URL scheme and length, field types and lengths.
  - stdout carries only protocol frames.
- **The socket is private.**
  - The app listens on a Unix-domain socket in the per-user Darwin temp directory, not on a network port.
  - The directory must be owned by the user and is forced to 0700. The socket is chmod'ed to 0600 before `listen()`, and a stale socket is only removed if it is a socket owned by the user.
  - The peer must have the same uid (`getpeereid`). Each connection has a 5-second read timeout and handles one request.
- **The app validates everything again.**
  - It re-validates every message and requires an allowlisted origin.
  - It applies the "automatic capture" setting and suppresses duplicates within 10 seconds.
  - It treats the URL and file name like any other untrusted input.
- **Browser data is never collected.** The extensions don't collect history or cookies and request no host permissions. Their permissions are `nativeMessaging`, `contextMenus`, `downloads` and `storage`. Downloads in private (incognito) windows are never captured. Cookie or session sharing is deliberately not implemented. Adding it would need an explicit, scoped design and its own review.

## File safety

- **File names.** `FileNameSanitizer` NFC-normalizes names and keeps only the last path component. It replaces `/`, `\` and `:`, and removes control characters, NULs and bidirectional overrides, which could otherwise disguise an extension. It strips leading dots so files can't become hidden, never returns `.`, `..` or an empty name, and limits names to 255 bytes while keeping the extension. `safeDestination` checks that the resolved path stays inside the destination folder.
- **Unmounted drives.** The destination root is never created. A missing `/Volumes/Drive/...` path means the drive is unplugged, and creating it would write to the startup disk. Such downloads wait until the drive is back. The volume UUID is recorded, and a different drive mounted at the same path is detected.
- **Partial data.** Partial data goes to a hidden `.oledownload-partial` folder on the destination drive. It is removed after completion, cancellation with deletion, or permanent removal.
- **Finalizing.** The finished file is moved with `renamex_np(..., RENAME_EXCL)`, which is atomic and never overwrites. An incomplete file never appears under the final name. "Replace" moves the old file to the Trash and requires confirmation in Settings.
- **Quarantine.** Downloaded files get `com.apple.quarantine` (agent OleDownloadManager, source URL, page URL), so Gatekeeper checks them when they are first opened. The app never removes quarantine attributes and never opens or executes downloads by itself. "Open" passes the file to Finder's normal handling.
- **Full Disk Access.** The app never asks for it. Access to protected folders such as Downloads or removable volumes goes through the normal macOS consent prompts and folder pickers.

## App hardening and distribution

- **Hardened runtime with no extra entitlements.** No JIT, no unsigned memory, no library-validation exceptions, no Apple Events.
- **Not sandboxed, by design.** The browser host launched by Chrome or Firefox must reach the app over IPC. A sandboxed app's container is protected by macOS app-data protection, which would prompt users when the host accesses it. Because the app isn't sandboxed, it uses ordinary bookmark data (not security-scoped bookmarks) to remember the download folder. Distribution is planned through Developer ID with notarization (see README).
- **No tracking.** There is no analytics, telemetry, advertising or remote tracking. `PrivacyInfo.xcprivacy` declares no tracking and no collected data. Its required-reason APIs are disk space, used before writing; system boot time, used for speed measurement; and file timestamp, used to validate partial files.

## Reporting a vulnerability

Please open a private security advisory on the GitHub repository rather than a public issue.
