import OleDownloadCore
import SwiftUI
import UniformTypeIdentifiers

struct DownloadListView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        content
            .onDeleteCommand { model.requestRemove(Array(model.selection)) }
            .onPasteCommand(of: [.url, .plainText]) { (_: [NSItemProvider]) in model.pasteURLs() }
            .onKeyPress(.space) { handleSpace() }
            .dropDestination(for: URL.self) { urls, _ in handleDrop(urls) }
    }

    @ViewBuilder
    private var content: some View {
        let items = model.visibleItems
        if items.isEmpty {
            emptyState
        } else {
            list(items)
        }
    }

    private func list(_ items: [DownloadItem]) -> some View {
        @Bindable var model = model
        return List(selection: $model.selection) {
            ForEach(items) { item in
                DownloadRowView(item: item, density: model.settings.listDensity)
                    .tag(item.id)
            }
            .onMove(perform: moveAction)
        }
        .listStyle(.inset)
        .alternatingRowBackgrounds()
        .contextMenu(forSelectionType: UUID.self) { ids in
            DownloadContextMenu(ids: Array(ids))
        } primaryAction: { ids in
            primaryAction(ids)
        }
        .accessibilityIdentifier("downloadList")
    }

    /// Drag-to-reorder is offered in the Queued list when it is sorted by queue order.
    private var moveAction: ((IndexSet, Int) -> Void)? {
        guard model.sort == .queueOrder, model.sidebar == .queued else { return nil }
        return { source, destination in move(from: source, to: destination) }
    }

    /// Double-click / Return: open completed files, otherwise start or resume.
    private func primaryAction(_ ids: Set<UUID>) {
        let selected = ids.compactMap { model.coordinator.item($0) }
        if let done = selected.first(where: { $0.state == .completed }) {
            model.open(done)
        } else {
            model.startOrResume(Array(ids))
        }
    }

    private func handleSpace() -> KeyPress.Result {
        guard !model.selection.isEmpty else { return .ignored }
        model.togglePause(Array(model.selection))
        return .handled
    }

    private func handleDrop(_ urls: [URL]) -> Bool {
        let web = urls.filter { URLValidator.isSupported($0) }
        guard !web.isEmpty else { return false }
        model.handleDropped(urls: web, origin: .dragAndDrop)
        return true
    }

    private func move(from source: IndexSet, to destination: Int) {
        var ids = model.visibleItems.map(\.id)
        ids.move(fromOffsets: source, toOffset: destination)
        model.coordinator.reorderQueue(ids)
    }

    @ViewBuilder
    private var emptyState: some View {
        if !model.searchText.isEmpty {
            ContentUnavailableView.search(text: model.searchText)
        } else {
            ContentUnavailableView {
                Label(model.sidebar == .trash ? "Trash Is Empty" : "No Downloads", systemImage: model.sidebar.symbol)
            } description: {
                Text(model.sidebar == .trash ? "Removed downloads appear here until you empty the Trash."
                                              : "Paste a link, drag one here, or press ⌘N to add a download.")
            } actions: {
                if model.sidebar != .trash {
                    Button("Add Download…") { model.presentAdd() }
                        .accessibilityIdentifier("empty.add")
                }
            }
        }
    }
}

/// Context menu actions. Each is enabled only when it applies to at least one selected item.
struct DownloadContextMenu: View {
    @Environment(AppModel.self) private var model
    let ids: [UUID]

    var body: some View {
        let items = ids.compactMap { model.coordinator.item($0) }
        let completed = items.filter { $0.state == .completed && !$0.fileMissing }
        let trashed = items.contains { $0.record.isTrashed }
        if trashed {
            Button("Put Back") { model.coordinator.restoreFromTrash(ids) }
            Button("Delete Permanently…") { model.confirmation = .deletePermanently(ids) }
        } else {
            Button("Start / Resume") { model.startOrResume(ids) }
                .disabled(!items.contains { [.queued, .paused, .interrupted, .waitingForDestination].contains($0.state) })
            Button("Pause") { model.pause(ids) }
                .disabled(!items.contains { $0.state.canPause })
            Button("Retry") { model.retry(ids) }
                .disabled(!items.contains { $0.state == .failed || $0.state == .retrying })
            Button("Restart") { model.coordinator.restart(ids) }
                .disabled(!items.contains { $0.state.canRestart })
            Button("Cancel…") { model.requestCancel(ids) }
                .disabled(!items.contains { $0.state.canCancel })
            Divider()
            Button("Open") { completed.forEach(model.open) }
                .disabled(completed.isEmpty)
            Button("Show in Finder") { items.first.map(model.reveal) }
                .disabled(completed.isEmpty)
            Button("Open Containing Folder") { items.first.map(model.openFolder) }
                .disabled(items.isEmpty)
            Divider()
            Button("Copy Source URL") { model.copySourceURL(items) }
            Button("Copy File Path") { model.copyFilePath(items) }
            if items.contains(where: { $0.state == .queued }) {
                Divider()
                Button("Move Up in Queue") { ids.forEach { model.coordinator.move($0, by: -1) } }
                Button("Move Down in Queue") { ids.reversed().forEach { model.coordinator.move($0, by: 1) } }
            }
            Divider()
            Button("Remove from List") { model.requestRemove(ids) }
        }
    }
}
