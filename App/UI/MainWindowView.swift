import OleDownloadCore
import SwiftUI

struct MainWindowView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        @Bindable var model = model
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 190, ideal: 220, max: 300)
        } detail: {
            DownloadListView()
                .inspector(isPresented: $model.showInspector) {
                    DownloadDetailsView()
                        .inspectorColumnWidth(min: 260, ideal: 320, max: 460)
                }
        }
        .navigationTitle(model.sidebar.title)
        .navigationSubtitle(subtitle)
        .searchable(text: $model.searchText, placement: .toolbar, prompt: "Search name or host")
        .toolbar { toolbarContent }
        .sheet(item: $model.addDraft) { draft in
            AddDownloadView(draft: draft)
        }
        .confirmationDialog(confirmationTitle, isPresented: confirmationBinding, titleVisibility: .visible, presenting: model.confirmation) { pending in
            confirmationButtons(pending)
        } message: { pending in
            Text(confirmationMessage(pending))
        }
        .alert("OleDownloadManager", isPresented: alertBinding) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
        }
        .frame(minWidth: 820, minHeight: 460)
    }

    private var subtitle: String {
        let active = model.coordinator.activeCount
        guard active > 0 else { return model.coordinator.queueRunning ? "Queue running" : "" }
        return "\(active) active — \(Format.speed(model.coordinator.totalSpeed))"
    }

    // MARK: Toolbar

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItemGroup(placement: .navigation) {
            Button { model.presentAdd() } label: { Label("Add Download", systemImage: "plus") }
                .help("Add a download (⌘N)")
                .accessibilityIdentifier("toolbar.add")
            Button { model.pasteURLs() } label: { Label("Paste URL", systemImage: "doc.on.clipboard") }
                .help("Add the URL on the clipboard")
                .accessibilityIdentifier("toolbar.paste")
        }
        ToolbarItemGroup(placement: .primaryAction) {
            Button { model.coordinator.startQueue() } label: { Label("Start Queue", systemImage: "play.fill") }
                .help("Start downloading queued items")
                .disabled(model.coordinator.queueRunning)
                .accessibilityIdentifier("toolbar.startQueue")
            Button { model.coordinator.pauseQueue() } label: { Label("Pause Queue", systemImage: "pause.fill") }
                .help("Stop the queue; queue downloads in progress return to Waiting")
                .disabled(!model.coordinator.queueRunning)
                .accessibilityIdentifier("toolbar.pauseQueue")
            Button { model.coordinator.resumeAll() } label: { Label("Resume Queue", systemImage: "arrow.clockwise") }
                .help("Resume all paused and interrupted downloads through the queue")
                .accessibilityIdentifier("toolbar.resumeQueue")
            Button { model.requestRemove(Array(model.selection)) } label: { Label("Remove Selected", systemImage: "trash") }
                .help(model.sidebar == .trash ? "Delete permanently" : "Move selected downloads to Trash")
                .disabled(model.selection.isEmpty)
                .accessibilityIdentifier("toolbar.remove")
            Menu {
                Picker("Sort By", selection: Bindable(model).sort) {
                    ForEach(SortOption.allCases) { Text($0.title).tag($0) }
                }
                Toggle("Ascending", isOn: Bindable(model).sortAscending)
                    .disabled(model.sort == .queueOrder)
            } label: { Label("Sort", systemImage: "arrow.up.arrow.down") }
                .help("Sort downloads")
            Button { openSettings() } label: { Label("Settings", systemImage: "gearshape") }
                .help("Settings (⌘,)")
            Button { model.showInspector.toggle() } label: { Label("Details", systemImage: "sidebar.trailing") }
                .help("Show or hide details (⌥⌘I)")
        }
    }

    // MARK: Confirmations

    private var confirmationBinding: Binding<Bool> {
        Binding(get: { model.confirmation != nil }, set: { if !$0 { model.confirmation = nil } })
    }

    private var alertBinding: Binding<Bool> {
        Binding(get: { model.alertMessage != nil }, set: { if !$0 { model.alertMessage = nil } })
    }

    private var confirmationTitle: String {
        switch model.confirmation {
        case .cancel?: "Cancel download?"
        case .removeActive?: "Remove active downloads?"
        case .deletePermanently?: "Delete permanently?"
        case .emptyTrash?: "Empty Trash?"
        case nil: ""
        }
    }

    private func confirmationMessage(_ pending: PendingConfirmation) -> String {
        switch pending {
        case .cancel: "The partially downloaded data can be kept so the download can be restarted later without losing progress."
        case .removeActive: "Running downloads will be stopped and moved to Trash. Their progress is kept until you empty the Trash."
        case .deletePermanently, .emptyTrash: "These entries will be removed from the history and any partial data deleted. Completed files stay on disk unless you choose to move them to the Trash too."
        }
    }

    @ViewBuilder
    private func confirmationButtons(_ pending: PendingConfirmation) -> some View {
        switch pending {
        case .cancel(let ids):
            Button("Cancel and Delete Data", role: .destructive) { model.coordinator.cancel(ids, deletePartialData: true) }
            Button("Cancel and Keep Data") { model.coordinator.cancel(ids, deletePartialData: false) }
            Button("Don't Cancel", role: .cancel) {}
        case .removeActive(let ids):
            Button("Stop and Remove", role: .destructive) {
                model.coordinator.moveToTrash(ids)
                model.selection.subtract(ids)
            }
            Button("Keep", role: .cancel) {}
        case .deletePermanently(let ids):
            Button("Delete Entries", role: .destructive) {
                model.coordinator.deletePermanently(ids, moveCompletedFilesToTrash: false)
                model.selection.subtract(ids)
            }
            Button("Delete Entries and Move Files to Trash", role: .destructive) {
                model.coordinator.deletePermanently(ids, moveCompletedFilesToTrash: true)
                model.selection.subtract(ids)
            }
            Button("Cancel", role: .cancel) {}
        case .emptyTrash:
            Button("Empty Trash", role: .destructive) { model.coordinator.emptyTrash() }
            Button("Cancel", role: .cancel) {}
        }
    }
}

struct SidebarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        @Bindable var model = model
        List(selection: Binding(get: { model.sidebar }, set: { if let v = $0 { model.sidebar = v; model.selection = [] } })) {
            Section("Downloads") {
                ForEach(SidebarFilter.statusFilters) { filter in
                    row(filter, symbol: filter.symbol, title: filter.title)
                }
            }
            Section("Categories") {
                ForEach(model.settings.categories) { category in
                    row(.category(category.id), symbol: category.symbolName, title: category.name)
                }
            }
        }
        .listStyle(.sidebar)
        .contextMenu(forSelectionType: SidebarFilter.self) { filters in
            if filters.contains(.trash) {
                Button("Empty Trash…") { model.confirmation = .emptyTrash }
                    .disabled(model.count(for: .trash) == 0)
            }
        }
        .safeAreaInset(edge: .bottom) { StatusBarView() }
    }

    private func row(_ filter: SidebarFilter, symbol: String, title: String) -> some View {
        let count = model.count(for: filter)
        return Label(title, systemImage: symbol)
            .badge(count)
            .tag(filter)
            .accessibilityIdentifier("sidebar.\(filter.id)")
            .accessibilityLabel("\(title), \(count) item\(count == 1 ? "" : "s")")
    }
}

/// Compact statistics at the bottom of the sidebar.
struct StatusBarView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let c = model.coordinator
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 6) {
                Circle()
                    .fill(c.queueRunning ? Color.green : Color.secondary.opacity(0.5))
                    .frame(width: 7, height: 7)
                Text(c.queueRunning ? "Queue running" : "Queue stopped")
                    .accessibilityIdentifier("status.queue")
            }
            Text(c.activeCount > 0 ? "\(c.activeCount) active · \(Format.speed(c.totalSpeed))" : "Idle")
                .monospacedDigit()
            if model.isUITesting {
                // UI-test fixture: exposes what a Finder action would have opened.
                Text(model.lastWorkspaceAction).accessibilityIdentifier("test.lastWorkspaceAction")
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .accessibilityElement(children: .combine)
    }
}
