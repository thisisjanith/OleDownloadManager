import OleDownloadCore
import SwiftUI

struct DownloadDetailsView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let selected = model.selectedItems
        if selected.count == 1, let item = selected.first {
            DetailsContent(item: item)
                .id(item.id)
        } else {
            ContentUnavailableView(selected.isEmpty ? "No Selection" : "\(selected.count) Downloads Selected",
                                   systemImage: "info.circle",
                                   description: Text(selected.isEmpty ? "Select a download to see its details." : "Select a single download to see its details."))
        }
    }
}

private struct DetailsContent: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    @State private var events: [DiagnosticEvent] = []

    var body: some View {
        let r = item.record
        Form {
            Section {
                HStack(spacing: 12) {
                    Image(nsImage: Format.icon(forFileName: r.fileName)).resizable().frame(width: 40, height: 40)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(r.fileName).font(.headline).textSelection(.enabled).lineLimit(3)
                        StatusBadge(item: item)
                    }
                }
                if let f = r.progressFraction, r.state != .completed {
                    ProgressView(value: f) { EmptyView() } currentValueLabel: { Text("\(Int(f * 100)) %").monospacedDigit() }
                }
                if r.state == .completed, !item.fileMissing {
                    HStack {
                        Button("Open") { model.open(item) }.accessibilityIdentifier("details.open")
                        Button("Show in Finder") { model.reveal(item) }
                    }
                }
            }
            Section("Source") {
                row("URL", r.sourceURL.absoluteString, selectable: true)
                if let final = r.finalURL, final != r.sourceURL { row("Final URL", final.absoluteString, selectable: true) }
                row("Host", item.host)
                if let page = r.pageURL { row("Page", page, selectable: true) }
                row("Added", "\(Format.date(r.createdAt)) (\(r.origin.label))")
            }
            Section("Destination") {
                row("Folder", (r.finalFileURL?.deletingLastPathComponent() ?? r.destinationDirectory).path(percentEncoded: false), selectable: true)
                if let path = r.finalFileURL?.path(percentEncoded: false) { row("File", path, selectable: true) }
                if let partial = r.partialFileURL?.path(percentEncoded: false), r.state != .completed { row("Partial data", partial, selectable: true) }
            }
            Section("Transfer") {
                row("Downloaded", Format.bytes(r.bytesReceived))
                row("Total size", r.expectedLength.map(Format.bytes) ?? "Unknown")
                if r.state == .downloading {
                    row("Current speed", Format.speed(item.currentSpeed))
                    if let eta = item.eta { row("Time remaining", Format.duration(eta)) }
                }
                row("Average speed", r.averageSpeed.map(Format.speed) ?? "—")
                row("Started", Format.date(r.startedAt))
                row("Completed", Format.date(r.completedAt))
                row("HTTP status", r.httpStatus.map(String.init) ?? "—")
                row("Range requests", r.supportsRanges.map { $0 ? "Supported (resumable)" : "Not supported" } ?? "Unknown")
                row("Connections", item.activeConnections > 0 ? "\(item.activeConnections) active" : "—")
                let segments = model.coordinator.liveSegments[item.id] ?? r.segments
                if !segments.isEmpty, let total = r.expectedLength {
                    LabeledContent("Segments") {
                        VStack(alignment: .trailing, spacing: 4) {
                            Text("\(segments.count) (\(segments.filter(\.isComplete).count) complete)")
                            SegmentMap(segments: segments, total: total).frame(height: 8)
                        }
                    }
                }
                row("Retries", "\(r.retryCount)")
                if let etag = r.validators.etag { row("ETag", etag, selectable: true) }
                if let lm = r.validators.lastModified { row("Last-Modified", lm) }
            }
            Section("Integrity") {
                row("SHA-256", r.sha256 ?? (r.state == .completed ? "Not computed" : "Computed after download"), selectable: true, monospaced: true)
                if let expected = r.expectedSHA256 {
                    row("Expected", expected, selectable: true, monospaced: true)
                    row("Checksum", r.checksumVerified.map { $0 ? "Matches" : "Does NOT match" } ?? "Not checked yet")
                }
                Text("A locally computed hash only proves authenticity when compared with a checksum from a source you trust.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let error = r.lastError {
                Section("Last Error") {
                    Text(error.message).textSelection(.enabled)
                    if let detail = error.detail { Text(detail).font(.caption).foregroundStyle(.secondary).textSelection(.enabled) }
                    if r.state == .failed || r.state == .retrying {
                        HStack {
                            Button(r.state == .retrying ? "Retry Now" : "Retry") { model.retry([item.id]) }
                            Button("Cancel") { model.requestCancel([item.id]) }
                        }
                    }
                }
            }
            if !events.isEmpty {
                Section("Activity") {
                    ForEach(events) { e in
                        VStack(alignment: .leading, spacing: 1) {
                            Text(e.message).font(.caption).textSelection(.enabled)
                            Text(e.at.formatted(date: .omitted, time: .standard)).font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .task(id: item.record.state) { events = model.coordinator.events(for: item.id) }
    }

    private func row(_ label: String, _ value: String, selectable: Bool = false, monospaced: Bool = false) -> some View {
        LabeledContent(label) {
            Text(value)
                .font(monospaced ? .system(.caption, design: .monospaced) : nil)
                .multilineTextAlignment(.trailing)
                .lineLimit(selectable ? 4 : 1)
                .truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Horizontal bar showing how much of each segment has arrived.
struct SegmentMap: View {
    let segments: [DownloadSegment]
    let total: Int64

    var body: some View {
        Canvas { context, size in
            guard total > 0 else { return }
            let scale = size.width / CGFloat(total)
            context.fill(Path(roundedRect: CGRect(origin: .zero, size: size), cornerRadius: 2), with: .color(.secondary.opacity(0.2)))
            for s in segments where s.completed > 0 {
                let rect = CGRect(x: CGFloat(s.start) * scale, y: 0, width: max(1, CGFloat(s.completed) * scale), height: size.height)
                context.fill(Path(rect), with: .color(.accentColor))
            }
        }
        .frame(minWidth: 120)
        .accessibilityLabel("Segment progress")
    }
}
