import Foundation
import OleBrowserBridge

// OleNativeHost — native messaging host for Chrome and Firefox.
//
// The browser launches this executable and talks to it over stdin/stdout using
// length-prefixed JSON. stdout is reserved for protocol frames; all diagnostics go to stderr.
// Each request is validated, stamped with the caller's extension identity and forwarded
// to the running OleDownloadManager app over a private Unix-domain socket.

func log(_ message: String) {
    FileHandle.standardError.write(Data("OleNativeHost: \(message)\n".utf8))
}

/// Chrome passes the caller origin ("chrome-extension://<id>/") as the first argument.
/// Firefox passes the manifest path first and the extension ID second.
func callerIdentity(_ args: [String]) -> String? {
    let rest = args.dropFirst()
    if let chrome = rest.first(where: { $0.hasPrefix("chrome-extension://") }) { return chrome }
    if rest.count >= 2 { return rest[rest.index(after: rest.startIndex)] }
    return nil
}

func reply(_ message: BrowserMessage) {
    guard let data = try? message.encoded() else { return }
    do {
        try MessageFraming.writeFrame(fd: STDOUT_FILENO, payload: data)
    } catch {
        log("failed to write reply: \(error)")
        exit(1)
    }
}

func launchApp() {
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/open")
    task.arguments = ["-g", "-b", "com.oledownloadmanager.app"]
    task.standardOutput = FileHandle.nullDevice   // never let child output reach the protocol stream
    task.standardError = FileHandle.standardError
    do {
        try task.run()
        task.waitUntilExit()
    } catch {
        log("could not launch app: \(error.localizedDescription)")
    }
}

func forward(_ payload: Data, launchIfNeeded: Bool) -> Result<Data, IPCError> {
    do {
        return .success(try IPCClient.send(payload))
    } catch {
        guard error.appNotRunning, launchIfNeeded else { return .failure(error) }
        log("app not running; launching it")
        launchApp()
        let deadline = Date().addingTimeInterval(10)
        while Date() < deadline {
            Thread.sleep(forTimeInterval: 0.4)
            if let data = try? IPCClient.send(payload) { return .success(data) }
        }
        return .failure(error)
    }
}

guard let origin = callerIdentity(CommandLine.arguments), BrowserProtocol.isAllowedOrigin(origin) else {
    log("refusing to run: caller is not an authorized extension")
    reply(.error(id: nil, code: "unauthorizedOrigin", message: BrowserProtocolError.unauthorizedOrigin.description))
    exit(1)
}

while true {
    let frame: Data
    do {
        frame = try MessageFraming.readFrame(fd: STDIN_FILENO)
    } catch MessageFraming.FramingError.endOfStream {
        exit(0)  // browser closed the port
    } catch {
        log("read error: \(error)")
        reply(.error(id: nil, code: "tooLarge", message: "Message could not be read."))
        exit(1)
    }

    // Validate locally first so malformed input never reaches the app.
    let request: BrowserRequest
    switch BrowserMessageValidator.validateRequest(frame, requireOrigin: false) {
    case .failure(let error):
        reply(.error(id: nil, code: error.code, message: error.description))
        continue
    case .success(let r):
        request = r
    }

    // Re-encode with the origin stamped by the host (any origin sent by the extension is overwritten).
    guard var message = try? JSONDecoder().decode(BrowserMessage.self, from: frame) else { continue }
    message.origin = origin
    guard let outgoing = try? message.encoded() else { continue }

    let isAdd: Bool = if case .addDownload = request { true } else { false }
    switch forward(outgoing, launchIfNeeded: isAdd) {
    case .success(let data):
        // Pass through only well-formed, size-limited JSON objects.
        if data.count <= BrowserProtocol.maxMessageBytes, let response = try? JSONDecoder().decode(BrowserMessage.self, from: data) {
            reply(response)
        } else {
            reply(.error(id: request.id, code: "badAppResponse", message: "The app sent an invalid response."))
        }
    case .failure(let error):
        if error.appNotRunning {
            var status = BrowserMessage(type: isAdd ? .error : .status, id: request.id)
            status.connected = false
            status.code = "appNotRunning"
            status.message = "OleDownloadManager is not running."
            reply(status)
        } else {
            log("IPC failure: \(error)")
            reply(.error(id: request.id, code: "ipcFailure", message: "Could not reach OleDownloadManager."))
        }
    }
}
