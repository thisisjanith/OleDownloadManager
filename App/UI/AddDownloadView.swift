import OleDownloadCore
import SwiftUI

struct AddDownloadView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let draft: AddDownloadDraft

    @State private var urlText = ""
    @State private var fileName = ""
    @State private var fileNameEdited = false
    @State private var directory: URL?
    @State private var categoryID = FileCategory.otherID
    @State private var categoryEdited = false
    @State private var headersText = ""
    @State private var user = ""
    @State private var password = ""
    @State private var rememberCredentials = false
    @State private var checksum = ""
    @State private var connections = 0          // 0 = use the default from Settings
    @State private var scheduleEnabled = false
    @State private var scheduleDate = Date().addingTimeInterval(3600)
    @State private var showAdvanced = false
    @State private var metadata: URLMetadata?
    @State private var probeMessage: String?
    @State private var probing = false
    @State private var problem: String?
    @State private var duplicateID: UUID?
    @State private var conflictPolicy: ConflictPolicy?

    private var validated: ValidatedURL? { try? URLValidator.validate(urlText) }

    private var urlError: String? {
        guard !urlText.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        do { _ = try URLValidator.validate(urlText); return nil } catch { return error.description }
    }

    private var targetDirectory: URL { directory ?? DestinationManager().defaultDirectory(settings: model.settings) }

    private var existingFile: Bool {
        guard !fileName.isEmpty else { return false }
        var dir = targetDirectory
        if model.settings.organizeByCategory, let c = model.settings.categories.first(where: { $0.id == categoryID }) {
            dir = dir.appendingPathComponent(c.folderName)
        }
        return FileManager.default.fileExists(atPath: dir.appendingPathComponent(FileNameSanitizer.sanitize(fileName)).path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Form {
                Section {
                    TextField("URL", text: $urlText, prompt: Text("https://example.com/file.zip"))
                        .textContentType(.URL)
                        .accessibilityIdentifier("add.url")
                    if let urlError {
                        Text(urlError).font(.caption).foregroundStyle(.red).accessibilityIdentifier("add.urlError")
                    } else if probing {
                        HStack(spacing: 6) { ProgressView().controlSize(.small); Text("Checking link…").font(.caption).foregroundStyle(.secondary) }
                    } else if let metadata {
                        Text(metadataSummary(metadata)).font(.caption).foregroundStyle(.secondary)
                    } else if let probeMessage {
                        Text(probeMessage).font(.caption).foregroundStyle(.orange)
                    }
                    if validated?.url.scheme == "http" {
                        Label("This link is not encrypted (HTTP). The file could be altered in transit.", systemImage: "lock.open")
                            .font(.caption).foregroundStyle(.orange)
                    }
                }
                Section {
                    TextField("File Name", text: Binding(get: { fileName }, set: { fileName = $0; fileNameEdited = true }))
                        .accessibilityIdentifier("add.fileName")
                    LabeledContent("Save To") {
                        HStack {
                            Text(targetDirectory.path(percentEncoded: false))
                                .lineLimit(1).truncationMode(.middle)
                                .foregroundStyle(.secondary)
                                .help(targetDirectory.path(percentEncoded: false))
                            Button("Choose…") {
                                if let url = model.chooseFolder(startingAt: targetDirectory) { directory = url }
                            }
                            .accessibilityIdentifier("add.chooseFolder")
                        }
                    }
                    Picker("Category", selection: Binding(get: { categoryID }, set: { categoryID = $0; categoryEdited = true })) {
                        ForEach(model.settings.categories) { Text($0.name).tag($0.id) }
                    }
                    if existingFile {
                        Picker("A file with this name exists", selection: Binding(get: { conflictPolicy ?? model.settings.conflictPolicy }, set: { conflictPolicy = $0 })) {
                            ForEach(ConflictPolicy.allCases, id: \.self) { Text($0.label).tag($0) }
                        }
                        .foregroundStyle(.orange)
                    }
                }
                Section {
                    DisclosureGroup("Advanced", isExpanded: $showAdvanced) {
                        advancedFields
                    }
                    .accessibilityIdentifier("add.advanced")
                }
            }
            .formStyle(.grouped)

            if let problem {
                Text(problem).font(.callout).foregroundStyle(.red).padding(.horizontal, 20)
            }
            HStack {
                if let duplicateID {
                    Button("Show Existing") {
                        model.sidebar = .all
                        model.selection = [duplicateID]
                        dismiss()
                    }
                    Button("Add Anyway") { submit(.startNow, allowDuplicate: true) }
                }
                Spacer()
                Button("Cancel", role: .cancel) { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button("Add to Queue") { submit(.addToQueue) }
                    .disabled(validated == nil)
                    .keyboardShortcut(model.settings.defaultAddAction == .addToQueue ? .defaultAction : KeyboardShortcut("q", modifiers: [.command, .shift]))
                    .accessibilityIdentifier("add.queue")
                Button("Start Now") { submit(.startNow) }
                    .disabled(validated == nil)
                    .keyboardShortcut(model.settings.defaultAddAction == .startNow ? .defaultAction : KeyboardShortcut("s", modifiers: [.command, .shift]))
                    .accessibilityIdentifier("add.start")
            }
            .padding(20)
        }
        .frame(width: 560)
        .onAppear {
            urlText = draft.urlText
            if model.settings.askWhereToSave, let url = model.chooseFolder(startingAt: targetDirectory) { directory = url }
        }
        .task(id: urlText) { await probe() }
    }

    @ViewBuilder
    private var advancedFields: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("HTTP headers (one per line, Name: value)").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $headersText)
                .font(.system(.body, design: .monospaced))
                .frame(height: 54)
                .overlay(RoundedRectangle(cornerRadius: 5).stroke(.quaternary))
                .accessibilityLabel("HTTP headers")
            Text("Authorization and Cookie headers are treated like passwords: they are kept in memory, or in the Keychain if you allow it, never in the download history.")
                .font(.caption2).foregroundStyle(.secondary)
            TextField("User Name", text: $user)
                .textContentType(.username)
            SecureField("Password", text: $password)
                .textContentType(.password)
            Text("Used for HTTP Basic or Digest authentication, and only sent to the server that asks for it.")
                .font(.caption2).foregroundStyle(.secondary)
            Toggle("Remember credentials in the Keychain until this download finishes", isOn: $rememberCredentials)
                .disabled(user.isEmpty && password.isEmpty && !headersText.lowercased().contains("authorization") && !headersText.lowercased().contains("cookie"))
            TextField("Expected SHA-256 (optional)", text: $checksum)
                .font(.system(.body, design: .monospaced))
            Picker("Connections", selection: $connections) {
                Text("Default (\(model.settings.maxConnectionsPerDownload))").tag(0)
                ForEach(1...8, id: \.self) { Text("\($0)").tag($0) }
            }
            Toggle("Start at a specific time", isOn: $scheduleEnabled)
            if scheduleEnabled {
                DatePicker("Start", selection: $scheduleDate, in: Date()...)
            }
        }
        .padding(.top, 6)
    }

    private func metadataSummary(_ m: URLMetadata) -> String {
        var parts: [String] = []
        parts.append(m.totalLength.map { Format.bytes($0) } ?? "Size unknown")
        if let type = m.contentType { parts.append(type) }
        parts.append(m.supportsRanges ? "Resumable" : "Not resumable")
        return parts.joined(separator: " · ")
    }

    /// Looks at the link (debounced) to suggest a file name and show size and resumability.
    private func probe() async {
        metadata = nil
        probeMessage = nil
        problem = nil
        duplicateID = nil
        guard let validated else { return }
        if validated.embeddedUser != nil, user.isEmpty {
            user = validated.embeddedUser ?? ""
            password = validated.embeddedPassword ?? ""
        }
        if !fileNameEdited {
            fileName = FileNameSanitizer.suggestedName(contentDisposition: nil, url: validated.url, mimeType: nil)
            if !categoryEdited { categoryID = FileCategory.classify(fileName: fileName, categories: model.settings.categories) }
        }
        try? await Task.sleep(for: .milliseconds(450))
        guard !Task.isCancelled else { return }
        probing = true
        defer { probing = false }
        do {
            let creds = user.isEmpty ? nil : BasicCredentials(user: user, password: password)
            let m = try await MetadataProbe.probe(validated.url, headers: (try? HTTPHeaderValidator.parse(headersText)) ?? [:], credentials: creds)
            guard !Task.isCancelled else { return }
            metadata = m
            if !fileNameEdited {
                fileName = m.suggestedFileName
                if !categoryEdited { categoryID = FileCategory.classify(fileName: fileName, categories: model.settings.categories) }
            }
        } catch is CancellationError {
        } catch {
            let e = DownloadError.from(error)
            probeMessage = e.kind == .authenticationRequired
                ? "This server requires a user name and password (Basic or Digest). Enter them under Advanced."
                : "Could not check the link: \(e.message) You can still add it."
            if e.kind == .authenticationRequired { showAdvanced = true }
        }
    }

    private func submit(_ action: AddAction, allowDuplicate: Bool = false) {
        guard let validated else { return }
        let headers: [String: String]
        do {
            headers = try HTTPHeaderValidator.parse(headersText)
        } catch {
            problem = error.description
            showAdvanced = true
            return
        }
        var request = NewDownloadRequest(url: validated.url)
        request.fileName = fileName.trimmingCharacters(in: .whitespaces).isEmpty ? nil : (fileNameEdited || metadata != nil ? fileName : nil)
        request.directory = directory
        request.categoryID = categoryEdited ? categoryID : nil
        request.headers = headers
        request.secrets = DownloadSecrets(user: user.isEmpty ? nil : user, password: password.isEmpty ? nil : password)
        request.rememberSecrets = rememberCredentials
        request.action = action
        request.origin = draft.origin
        request.expectedSHA256 = checksum
        request.scheduledAt = scheduleEnabled ? scheduleDate : nil
        request.conflictPolicy = existingFile ? conflictPolicy : nil
        request.maxConnections = connections == 0 ? nil : connections
        request.allowDuplicate = allowDuplicate
        switch model.coordinator.add(request) {
        case .success(let item):
            if model.sidebar != .all && !model.sidebar.matches(item) { model.sidebar = .all }
            model.selection = [item.id]
            dismiss()
        case .failure(.duplicate(let id)):
            duplicateID = id
            problem = AddDownloadError.duplicate(id).description
        case .failure(let e):
            problem = e.description
        }
    }
}
