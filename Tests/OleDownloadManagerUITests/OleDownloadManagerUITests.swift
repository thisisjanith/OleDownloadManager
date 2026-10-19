import XCTest

/// End-to-end UI tests. Each test launches the real app in an isolated UI-test mode
/// (temporary database and download folder) against a local HTTP server, so nothing
/// depends on the internet or on the user's own data.
final class OleDownloadManagerUITests: XCTestCase {
    var server: TestHTTPServer!
    var dataDir: URL!
    var downloadDir: URL!
    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        server = try TestHTTPServer()
        let base = FileManager.default.temporaryDirectory.appendingPathComponent("oledm-ui-\(UUID().uuidString)")
        dataDir = base.appendingPathComponent("data")
        downloadDir = base.appendingPathComponent("Downloads")
        try FileManager.default.createDirectory(at: dataDir, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: downloadDir, withIntermediateDirectories: true)
        app = makeApp()
        app.launch()
    }

    override func tearDownWithError() throws {
        app?.terminate()
        server?.stop()
        try? FileManager.default.removeItem(at: dataDir.deletingLastPathComponent())
    }

    func makeApp(extraEnvironment: [String: String] = [:]) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-UITestMode", "-ApplePersistenceIgnoreState", "YES"]
        app.launchEnvironment["OLEDM_DATA_DIR"] = dataDir.path
        app.launchEnvironment["OLEDM_DOWNLOAD_DIR"] = downloadDir.path
        for (k, v) in extraEnvironment { app.launchEnvironment[k] = v }
        return app
    }

    // MARK: Helpers

    func addDownload(_ path: String, start: Bool = true) {
        app.typeKey("n", modifierFlags: .command)
        let field = app.textFields["add.url"]
        XCTAssertTrue(field.waitForExistence(timeout: 5))
        field.click()
        field.typeText(server.url(path).absoluteString)
        let button = app.buttons[start ? "add.start" : "add.queue"]
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        waitUntil(button, "isEnabled == true")
        button.click()
    }

    func status(_ fileName: String) -> XCUIElement { app.staticTexts["status.\(fileName)"] }

    func waitUntil(_ element: XCUIElement, _ format: String, timeout: TimeInterval = 20) {
        let e = expectation(for: NSPredicate(format: format), evaluatedWith: element)
        wait(for: [e], timeout: timeout)
    }

    func waitForStatus(_ fileName: String, _ value: String, timeout: TimeInterval = 20) {
        let s = status(fileName)
        XCTAssertTrue(s.waitForExistence(timeout: timeout), "row for \(fileName) did not appear")
        waitUntil(s, "value == '\(value)'", timeout: timeout)
    }

    // MARK: Tests

    func testAddStartAndOpenCompletedFile() throws {
        addDownload("/file?size=200000&seed=1&disposition=ui-first.bin")
        waitForStatus("ui-first.bin", "Completed")
        let file = downloadDir.appendingPathComponent("ui-first.bin")
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))
        XCTAssertEqual(try Data(contentsOf: file), TestHTTPServer.body(size: 200000, seed: 1))

        status("ui-first.bin").click()
        let open = app.buttons["details.open"]
        XCTAssertTrue(open.waitForExistence(timeout: 5))
        open.click()
        waitUntil(app.staticTexts["test.lastWorkspaceAction"], "value == 'open:ui-first.bin'", timeout: 5)
    }

    func testPauseAndResume() throws {
        addDownload("/file?size=3000000&seed=2&chunkSize=16384&delayMs=20&disposition=ui-pause.bin")
        waitForStatus("ui-pause.bin", "Downloading")
        app.buttons["action.Pause.ui-pause.bin"].click()
        waitForStatus("ui-pause.bin", "Paused")
        app.buttons["action.Resume.ui-pause.bin"].click()
        waitForStatus("ui-pause.bin", "Completed", timeout: 60)
        XCTAssertEqual(try Data(contentsOf: downloadDir.appendingPathComponent("ui-pause.bin")), TestHTTPServer.body(size: 3000000, seed: 2))
    }

    func testCancelDownload() throws {
        addDownload("/file?size=3000000&seed=3&chunkSize=16384&delayMs=20&disposition=ui-cancel.bin")
        waitForStatus("ui-cancel.bin", "Downloading")
        app.buttons["action.Cancel.ui-cancel.bin"].click()
        let delete = app.buttons["Cancel and Delete Data"]
        XCTAssertTrue(delete.waitForExistence(timeout: 5))
        delete.click()
        waitForStatus("ui-cancel.bin", "Canceled")
        XCTAssertFalse(FileManager.default.fileExists(atPath: downloadDir.appendingPathComponent("ui-cancel.bin").path))
    }

    func testRetryFailedDownload() throws {
        addDownload("/file?size=1000&seed=4&fail500=1&key=uiretry&disposition=ui-retry.bin")
        // Retries are disabled in UI-test mode, so the first 500 fails the download.
        let row = app.staticTexts.matching(NSPredicate(format: "identifier BEGINSWITH 'status.' AND value == 'Failed'")).firstMatch
        XCTAssertTrue(row.waitForExistence(timeout: 20))
        let retry = app.buttons.matching(NSPredicate(format: "identifier BEGINSWITH 'action.Retry.'")).firstMatch
        XCTAssertTrue(retry.waitForExistence(timeout: 5))
        retry.click()
        waitForStatus("ui-retry.bin", "Completed")
    }

    func testSearchAndSidebarFilter() throws {
        addDownload("/file?size=100&seed=5&disposition=alpha-report.pdf")
        waitForStatus("alpha-report.pdf", "Completed")
        addDownload("/file?size=100&seed=6&disposition=beta-movie.mp4", start: false)
        waitForStatus("beta-movie.mp4", "Waiting")

        let search = app.searchFields.firstMatch
        XCTAssertTrue(search.waitForExistence(timeout: 5))
        search.click()
        search.typeText("alpha")
        waitUntil(status("beta-movie.mp4"), "exists == false", timeout: 5)
        XCTAssertTrue(status("alpha-report.pdf").exists)
        search.typeKey("a", modifierFlags: .command)
        search.typeKey(.delete, modifierFlags: [])

        app.outlines.staticTexts["Completed"].firstMatch.click()
        waitUntil(status("beta-movie.mp4"), "exists == false", timeout: 5)
        XCTAssertTrue(status("alpha-report.pdf").exists)

        app.outlines.staticTexts["Video"].firstMatch.click()
        XCTAssertTrue(status("beta-movie.mp4").waitForExistence(timeout: 5))
        XCTAssertFalse(status("alpha-report.pdf").exists)
    }

    func testHistoryPersistsAcrossRelaunch() throws {
        addDownload("/file?size=500&seed=7&disposition=ui-persist.bin")
        waitForStatus("ui-persist.bin", "Completed")
        addDownload("/file?size=500&seed=8&disposition=ui-queued.bin", start: false)
        waitForStatus("ui-queued.bin", "Waiting")
        app.terminate()

        app = makeApp()
        app.launch()
        waitForStatus("ui-persist.bin", "Completed", timeout: 10)
        waitForStatus("ui-queued.bin", "Waiting", timeout: 10)
    }

    func testChangeDestinationDirectoryInSettings() throws {
        let newFolder = dataDir.deletingLastPathComponent().appendingPathComponent("External Drive Folder")
        try FileManager.default.createDirectory(at: newFolder, withIntermediateDirectories: true)
        app.terminate()
        app = makeApp(extraEnvironment: ["OLEDM_CHOOSE_FOLDER": newFolder.path])
        app.launch()

        app.typeKey(",", modifierFlags: .command)
        let choose = app.buttons["settings.chooseFolder"]
        XCTAssertTrue(choose.waitForExistence(timeout: 5))
        choose.click()
        waitUntil(app.staticTexts["settings.downloadFolder"], "value CONTAINS 'External Drive Folder'", timeout: 5)
        app.typeKey("w", modifierFlags: .command)

        addDownload("/file?size=300&seed=9&disposition=ui-dest.bin")
        waitForStatus("ui-dest.bin", "Completed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: newFolder.appendingPathComponent("ui-dest.bin").path))
    }

    func testSettingsArePersisted() throws {
        app.typeKey(",", modifierFlags: .command)
        let downloadsTab = app.toolbars.buttons["Downloads"]
        XCTAssertTrue(downloadsTab.waitForExistence(timeout: 5))
        downloadsTab.click()
        let stepper = app.steppers["settings.maxConcurrent"]
        XCTAssertTrue(stepper.waitForExistence(timeout: 5))
        stepper.incrementArrows.firstMatch.click()
        XCTAssertTrue(app.staticTexts["4"].waitForExistence(timeout: 5))
        app.typeKey("w", modifierFlags: .command)
        app.terminate()

        app = makeApp()
        app.launch()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.toolbars.buttons["Downloads"].waitForExistence(timeout: 5))
        app.toolbars.buttons["Downloads"].click()
        XCTAssertTrue(app.staticTexts["4"].waitForExistence(timeout: 5))
    }
}
