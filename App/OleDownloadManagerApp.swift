import OleDownloadCore
import SwiftUI

@main
struct OleDownloadManagerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @State private var model: AppModel

    init() {
        let model = AppModel()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        Window("OleDownloadManager", id: "main") {
            MainWindowView()
                .environment(model)
                .onAppear {
                    appDelegate.model = model
                    model.start()
                }
        }
        .defaultSize(width: 1100, height: 640)
        .commands { AppCommands(model: model) }

        Settings {
            SettingsView()
                .environment(model)
        }

        MenuBarExtra(isInserted: Binding(get: { model.settings.showMenuBarItem }, set: { v in model.updateSettings { $0.showMenuBarItem = v } })) {
            MenuBarView().environment(model)
        } label: {
            Label("OleDownloadManager", systemImage: model.coordinator.activeCount > 0 ? "arrow.down.circle.fill" : "arrow.down.circle")
        }
    }
}

struct AppCommands: Commands {
    let model: AppModel
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(replacing: .newItem) {
            Button("Add Download…") {
                openWindow(id: "main")
                model.presentAdd()
            }
            .keyboardShortcut("n")
            Button("Add Download from Clipboard") {
                openWindow(id: "main")
                model.pasteURLs()
            }
            .keyboardShortcut("v", modifiers: [.command, .shift])
        }
        CommandMenu("Downloads") {
            let ids = Array(model.selection)
            let items = model.selectedItems
            Button("Start / Resume") { model.startOrResume(ids) }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(!items.contains { [.queued, .paused, .interrupted, .waitingForDestination].contains($0.state) })
            Button("Pause") { model.pause(ids) }
                .disabled(!items.contains { $0.state.canPause })
            Button("Retry") { model.retry(ids) }
                .keyboardShortcut("r")
                .disabled(!items.contains { $0.state == .failed || $0.state == .retrying })
            Button("Cancel…") { model.requestCancel(ids) }
                .disabled(!items.contains { $0.state.canCancel })
            Divider()
            Button("Open") { items.filter { $0.state == .completed }.forEach(model.open) }
                .keyboardShortcut("o")
                .disabled(!items.contains { $0.state == .completed && !$0.fileMissing })
            Button("Show in Finder") { items.first.map(model.reveal) }
                .keyboardShortcut("r", modifiers: [.command, .option])
                .disabled(!items.contains { $0.state == .completed && !$0.fileMissing })
            Divider()
            Button("Move Up in Queue") { ids.forEach { model.coordinator.move($0, by: -1) } }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!items.contains { $0.state == .queued })
            Button("Move Down in Queue") { ids.reversed().forEach { model.coordinator.move($0, by: 1) } }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!items.contains { $0.state == .queued })
            Divider()
            Button("Start Queue") { model.coordinator.startQueue() }
                .disabled(model.coordinator.queueRunning)
            Button("Pause Queue") { model.coordinator.pauseQueue() }
                .disabled(!model.coordinator.queueRunning)
            Button("Resume All Paused") { model.coordinator.resumeAll() }
        }
        CommandGroup(after: .sidebar) {
            Button(model.showInspector ? "Hide Details" : "Show Details") { model.showInspector.toggle() }
                .keyboardShortcut("i", modifiers: [.command, .option])
        }
    }
}

struct MenuBarView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let c = model.coordinator
        let active = c.items.filter { $0.state.isActive }
        Text(active.isEmpty ? "No active downloads" : "\(active.count) active — \(Format.speed(c.totalSpeed))")
        ForEach(active.prefix(5)) { item in
            let pct = item.record.progressFraction.map { " \(Int($0 * 100)) %" } ?? ""
            Text("\(item.record.fileName)\(pct)")
        }
        Divider()
        Button("Show OleDownloadManager") {
            openWindow(id: "main")
            NSApp.activate()
        }
        Button("Add Download from Clipboard") {
            openWindow(id: "main")
            NSApp.activate()
            model.pasteURLs()
        }
        Button(c.queueRunning ? "Pause Queue" : "Start Queue") {
            if c.queueRunning { c.pauseQueue() } else { c.startQueue() }
        }
        Divider()
        Button("Quit OleDownloadManager") { NSApp.terminate(nil) }
    }
}
