import OleDownloadCore
import SwiftUI

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            DownloadSettingsTab().tabItem { Label("Downloads", systemImage: "arrow.down.circle") }
            CategorySettings().tabItem { Label("Categories", systemImage: "folder") }
            NetworkSettings().tabItem { Label("Network", systemImage: "network") }
            ScheduleSettings().tabItem { Label("Schedule", systemImage: "calendar.badge.clock") }
            BrowserSettings().tabItem { Label("Browser", systemImage: "puzzlepiece.extension") }
            AppearanceSettings().tabItem { Label("Appearance", systemImage: "paintbrush") }
            PrivacySettings().tabItem { Label("Privacy", systemImage: "hand.raised") }
        }
        .frame(width: 600)
        .frame(minHeight: 420)
    }
}

/// Binding into one settings field; every change is validated and saved immediately.
@MainActor
private func setting<T>(_ model: AppModel, _ keyPath: WritableKeyPath<AppSettings, T>) -> Binding<T> {
    Binding(get: { model.settings[keyPath: keyPath] }, set: { value in model.updateSettings { $0[keyPath: keyPath] = value } })
}

private struct GeneralSettings: View {
    @Environment(AppModel.self) private var model
    @State private var launchError: String?
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Section("Saving") {
                LabeledContent("Download folder") {
                    HStack {
                        Text(DestinationManager().defaultDirectory(settings: model.settings).path(percentEncoded: false))
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                            .accessibilityIdentifier("settings.downloadFolder")
                        Button("Choose…") {
                            let current = DestinationManager().defaultDirectory(settings: model.settings)
                            if let url = model.chooseFolder(startingAt: current) {
                                model.updateSettings {
                                    $0.defaultDirectoryPath = url.path
                                    $0.defaultDirectoryBookmark = DestinationManager.bookmark(for: url)
                                }
                            }
                        }
                        .accessibilityIdentifier("settings.chooseFolder")
                    }
                }
                Button("Use the Downloads Folder") {
                    model.updateSettings { $0.defaultDirectoryPath = nil; $0.defaultDirectoryBookmark = nil }
                }
                .disabled(model.settings.defaultDirectoryPath == nil)
                Toggle("Ask where to save each file", isOn: setting(model, \.askWhereToSave))
                Picker("When adding a download", selection: setting(model, \.defaultAddAction)) {
                    ForEach(AddAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .accessibilityIdentifier("settings.defaultAddAction")
            }
            Section("App") {
                Toggle("Open at login", isOn: Binding(get: { launchAtLogin }, set: { newValue in
                    do {
                        try LaunchAtLogin.set(newValue)
                        launchAtLogin = LaunchAtLogin.isEnabled
                        model.updateSettings { $0.launchAtLogin = newValue }
                        launchError = LaunchAtLogin.requiresApproval ? "Approve OleDownloadManager in System Settings › General › Login Items." : nil
                    } catch {
                        launchError = "Could not change the login item: \(error.localizedDescription)"
                    }
                }))
                if let launchError { Text(launchError).font(.caption).foregroundStyle(.orange) }
                Toggle("Show notifications when downloads finish or fail", isOn: setting(model, \.showNotifications))
                Toggle("Quit when the last window is closed", isOn: setting(model, \.quitWhenLastWindowCloses))
                Toggle("Show in the menu bar", isOn: setting(model, \.showMenuBarItem))
                Toggle("Start the queue when the app opens", isOn: setting(model, \.startQueueOnLaunch))
                Toggle("Resume interrupted downloads when the app opens", isOn: setting(model, \.resumeInterruptedOnLaunch))
            }
        }
        .formStyle(.grouped)
    }
}

private struct DownloadSettingsTab: View {
    @Environment(AppModel.self) private var model
    @State private var confirmReplace = false

    var body: some View {
        let l = AppSettings.limits
        Form {
            Section("Connections") {
                Stepper(value: setting(model, \.maxConcurrentDownloads), in: l.concurrentDownloads) {
                    LabeledContent("Simultaneous downloads", value: "\(model.settings.maxConcurrentDownloads)")
                }
                .accessibilityIdentifier("settings.maxConcurrent")
                Stepper(value: setting(model, \.maxConnectionsPerDownload), in: l.connections) {
                    LabeledContent("Connections per download", value: "\(model.settings.maxConnectionsPerDownload)")
                }
                Text("Multiple connections are used only when the server reliably supports byte ranges and the file is large enough. They help on some servers and not at all on others.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Reliability") {
                Stepper(value: setting(model, \.maxRetries), in: l.retries) {
                    LabeledContent("Automatic retries", value: "\(model.settings.maxRetries)")
                }
                Toggle("Keep partial data after errors so downloads can resume", isOn: setting(model, \.preserveIncompleteFiles))
                Toggle("Compute SHA-256 after each download", isOn: setting(model, \.computeSHA256))
            }
            Section("Files") {
                Picker("If a file already exists", selection: Binding(get: { model.settings.conflictPolicy }, set: { value in
                    if value == .replace { confirmReplace = true } else { model.updateSettings { $0.conflictPolicy = value } }
                })) {
                    ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Toggle("Organize files into category folders", isOn: setting(model, \.organizeByCategory))
                LabeledContent("Partial data") {
                    HStack {
                        Text(model.settings.customTemporaryDirectoryPath ?? "Hidden folder next to the download (same drive)")
                            .lineLimit(1).truncationMode(.middle).foregroundStyle(.secondary)
                        Button("Choose…") {
                            if let url = model.chooseFolder(startingAt: nil) { model.updateSettings { $0.customTemporaryDirectoryPath = url.path } }
                        }
                        if model.settings.customTemporaryDirectoryPath != nil {
                            Button("Reset") { model.updateSettings { $0.customTemporaryDirectoryPath = nil } }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .confirmationDialog("Replace existing files?", isPresented: $confirmReplace) {
            Button("Replace Existing Files", role: .destructive) { model.updateSettings { $0.conflictPolicy = .replace } }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("When a downloaded file has the same name as an existing file, the existing file will be moved to the Trash.")
        }
    }
}

private struct CategorySettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Section {
                ForEach(model.settings.categories) { category in
                    LabeledContent {
                        if category.id == FileCategory.otherID {
                            Text("Everything else").foregroundStyle(.secondary)
                        } else {
                            TextField("Extensions", text: Binding(
                                get: { category.extensions.joined(separator: ", ") },
                                set: { text in
                                    let exts = text.lowercased().split(whereSeparator: { $0 == "," || $0 == " " })
                                        .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: ". ")) }.filter { !$0.isEmpty }
                                    model.updateSettings { s in
                                        if let i = s.categories.firstIndex(where: { $0.id == category.id }) { s.categories[i].extensions = exts }
                                    }
                                }))
                            .labelsHidden()
                        }
                    } label: {
                        Label(category.name, systemImage: category.symbolName)
                    }
                }
            } footer: {
                Text("Files are classified by extension. With “Organize files into category folders” on, each category gets its own sub-folder.")
            }
            Button("Restore Default Categories") { model.updateSettings { $0.categories = FileCategory.defaults } }
        }
        .formStyle(.grouped)
    }
}

private struct NetworkSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let l = AppSettings.limits
        Form {
            Section("Speed limits") {
                SpeedLimitField(title: "Per download", value: setting(model, \.perDownloadSpeedLimit))
                SpeedLimitField(title: "All downloads", value: setting(model, \.globalSpeedLimit))
            }
            Section("Timeouts") {
                Stepper(value: setting(model, \.connectionTimeout), in: l.connectionTimeout, step: 5) {
                    LabeledContent("Connection timeout", value: "\(Int(model.settings.connectionTimeout)) s")
                }
                Stepper(value: setting(model, \.readTimeout), in: l.readTimeout, step: 5) {
                    LabeledContent("Read timeout (no data received)", value: "\(Int(model.settings.readTimeout)) s")
                }
            }
            Section("Retry backoff") {
                Stepper(value: setting(model, \.retryBaseDelay), in: l.retryBaseDelay, step: 1) {
                    LabeledContent("First retry after", value: "\(Int(model.settings.retryBaseDelay)) s")
                }
                Stepper(value: setting(model, \.retryBackoffMultiplier), in: l.backoffMultiplier, step: 0.5) {
                    LabeledContent("Multiply delay by", value: String(format: "%.1f×", model.settings.retryBackoffMultiplier))
                }
                Stepper(value: setting(model, \.retryMaxDelay), in: l.retryMaxDelay, step: 10) {
                    LabeledContent("Longest delay", value: Format.duration(model.settings.retryMaxDelay))
                }
                Text("A random ±20 % is added so many downloads don't retry at the same moment. A server's Retry-After header takes precedence.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Security") {
                Toggle("Block redirects from websites to local-network addresses", isOn: setting(model, \.blockRedirectsToPrivateNetworks))
                Text("Certificate checks for HTTPS are always on and cannot be disabled.").font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }
}

private struct SpeedLimitField: View {
    let title: String
    @Binding var value: Int64
    private static let presets: [Int64] = [0, 256_000, 512_000, 1_000_000, 2_000_000, 5_000_000, 10_000_000, 25_000_000, 50_000_000]

    var body: some View {
        Picker(title, selection: $value) {
            ForEach(Self.presets + (Self.presets.contains(value) ? [] : [value]), id: \.self) { v in
                Text(v == 0 ? "Unlimited" : Format.speed(Double(v))).tag(v)
            }
        }
    }
}

private struct ScheduleSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let s = model.settings.schedule
        Form {
            Section {
                Toggle("Start the queue automatically", isOn: setting(model, \.schedule.enabled))
                DatePicker("Start at", selection: minuteBinding(\.schedule.startMinute), displayedComponents: .hourAndMinute)
                    .disabled(!s.enabled)
                Toggle("Stop the queue at", isOn: setting(model, \.schedule.stopEnabled)).disabled(!s.enabled)
                DatePicker("Stop at", selection: minuteBinding(\.schedule.stopMinute), displayedComponents: .hourAndMinute)
                    .disabled(!s.enabled || !s.stopEnabled)
                LabeledContent("Days") {
                    HStack(spacing: 4) {
                        ForEach(1...7, id: \.self) { day in
                            Toggle(Calendar.current.veryShortWeekdaySymbols[day - 1], isOn: Binding(
                                get: { s.weekdays.contains(day) },
                                set: { on in model.updateSettings { if on { $0.schedule.weekdays.insert(day) } else { $0.schedule.weekdays.remove(day) } } }))
                            .toggleStyle(.button)
                        }
                    }
                    .disabled(!s.enabled)
                }
                if let next = ScheduleEvaluator.nextStart(schedule: s, after: Date()) {
                    LabeledContent("Next start", value: next.formatted(date: .abbreviated, time: .shortened))
                }
            } footer: {
                Text("The schedule only works while OleDownloadManager is running. If the Mac is asleep at the start time, the queue starts when it wakes, as long as the stop time hasn't passed. The app does not wake the Mac.")
            }
        }
        .formStyle(.grouped)
    }

    private func minuteBinding(_ keyPath: WritableKeyPath<AppSettings, Int>) -> Binding<Date> {
        Binding(get: {
            Calendar.current.date(byAdding: .minute, value: model.settings[keyPath: keyPath], to: Calendar.current.startOfDay(for: Date())) ?? Date()
        }, set: { date in
            let c = Calendar.current.dateComponents([.hour, .minute], from: date)
            model.updateSettings { $0[keyPath: keyPath] = (c.hour ?? 0) * 60 + (c.minute ?? 0) }
        })
    }
}

private struct BrowserSettings: View {
    @Environment(AppModel.self) private var model
    @State private var refresh = 0
    @State private var message: String?
    private let installer = NativeHostInstaller()

    private var hostPath: String? {
        let url = Bundle.main.bundleURL.appendingPathComponent("Contents/Helpers/OleNativeHost")
        return FileManager.default.isExecutableFile(atPath: url.path) ? url.path : nil
    }

    var body: some View {
        Form {
            Section("Status") {
                LabeledContent("App listening for extensions") {
                    Text(model.bridge.isListening ? "Yes" : (model.bridge.lastError ?? "No")).foregroundStyle(model.bridge.isListening ? .green : .orange)
                }
                if model.coordinator.lastBrowserContact.isEmpty {
                    Text("No extension has connected yet.").foregroundStyle(.secondary)
                } else {
                    ForEach(model.coordinator.lastBrowserContact.sorted(by: { $0.key < $1.key }), id: \.key) { name, date in
                        LabeledContent(name.capitalized, value: "Last contact \(date.formatted(.relative(presentation: .named)))")
                    }
                }
            }
            Section("Capture") {
                Toggle("Allow extensions to capture downloads automatically", isOn: setting(model, \.browserCaptureEnabled))
                Picker("Captured downloads", selection: setting(model, \.browserCaptureAction)) {
                    ForEach(AddAction.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text("Links sent with “Download with OleDownloadManager” are always accepted. Browser cookies and sign-ins are never shared with the app, so downloads that need a signed-in session may fail.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Native messaging host") {
                if let hostPath {
                    ForEach(NativeHostInstaller.Browser.allCases) { browser in
                        let status = installer.status(for: browser, hostPath: hostPath)
                        LabeledContent(browser.displayName) {
                            HStack {
                                Text(label(status)).foregroundStyle(status == .installed ? .green : .secondary)
                                if status != .browserNotFound {
                                    Button(status == .installed ? "Remove" : "Install") {
                                        do {
                                            if status == .installed { try installer.uninstall(for: browser) } else { try installer.install(for: browser, hostPath: hostPath) }
                                            message = nil
                                        } catch {
                                            message = error.localizedDescription
                                        }
                                        refresh += 1
                                    }
                                }
                            }
                        }
                    }
                    .id(refresh)
                } else {
                    Text("The native host is missing from the app bundle. Build the app with Xcode or Scripts/build.sh.").foregroundStyle(.orange)
                }
                if let message { Text(message).font(.caption).foregroundStyle(.red) }
                Text("After installing the host, load the extension: in Chrome open chrome://extensions, turn on Developer mode, choose “Load unpacked” and select BrowserExtensions/Chrome. In Firefox open about:debugging › This Firefox › Load Temporary Add-on and choose BrowserExtensions/Firefox/manifest.json. See the README for details.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private func label(_ s: NativeHostInstaller.Status) -> String {
        switch s {
        case .browserNotFound: "Not installed on this Mac"
        case .notInstalled: "Host not installed"
        case .installed: "Host installed"
        case .stale(let why): "Needs reinstall (\(why))"
        }
    }
}

private struct AppearanceSettings: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Form {
            Picker("Appearance", selection: setting(model, \.appearance)) {
                ForEach(AppearancePreference.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.appearance")
            Picker("Download list", selection: setting(model, \.listDensity)) {
                ForEach(ListDensity.allCases, id: \.self) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .accessibilityIdentifier("settings.density")
        }
        .formStyle(.grouped)
    }
}

private struct PrivacySettings: View {
    var body: some View {
        Form {
            Section("What stays on this Mac") {
                Text("Download history, queue, settings and diagnostic notes are stored in a local SQLite database in ~/Library/Application Support/OleDownloadManager. Passwords and Authorization/Cookie headers are never written there; they are kept in memory, or in your login Keychain only if you choose “Remember credentials”.")
            }
            Section("What is sent over the network") {
                Text("Only the requests needed to download the files you add, sent to the servers in those links. OleDownloadManager has no analytics, telemetry, advertising or remote tracking, and it does not contact any other server.")
            }
            Section("Downloaded files") {
                Text("Files are marked as downloaded from the internet (quarantine) so macOS Gatekeeper checks them when opened. OleDownloadManager never opens or runs downloaded files by itself.")
            }
        }
        .formStyle(.grouped)
    }
}
