import OleDownloadCore
import SwiftUI

struct DownloadRowView: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem
    let density: ListDensity

    var body: some View {
        let r = item.record
        HStack(spacing: 10) {
            Image(nsImage: Format.icon(forFileName: r.fileName))
                .resizable()
                .frame(width: density == .compact ? 20 : 32, height: density == .compact ? 20 : 32)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: density == .compact ? 1 : 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text(r.fileName)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .fontWeight(.medium)
                    if density == .comfortable {
                        Text(item.host)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                    Spacer(minLength: 8)
                    StatusBadge(item: item)
                }
                if density == .comfortable || r.state.isActive {
                    progressBar
                }
                Text(Format.progressLine(item))
                    .font(.caption)
                    .foregroundStyle(r.state == .failed ? .red : .secondary)
                    .monospacedDigit()
                    .lineLimit(1)
                    .truncationMode(.tail)
            }
            RowActions(item: item)
        }
        .padding(.vertical, density == .compact ? 1 : 5)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(accessibilitySummary)
        .accessibilityIdentifier("row.\(r.fileName)")
    }

    @ViewBuilder
    private var progressBar: some View {
        let r = item.record
        if let fraction = r.progressFraction, r.state != .completed {
            ProgressView(value: fraction)
                .progressViewStyle(.linear)
                .tint(r.state == .failed ? .red : (r.state == .paused || r.state == .interrupted ? .orange : .accentColor))
                .controlSize(.small)
                .accessibilityLabel("Progress")
                .accessibilityValue("\(Int(fraction * 100)) percent")
        } else if r.state == .downloading || r.state == .connecting || r.state == .verifying {
            // Unknown size: show activity without inventing a percentage.
            ProgressView().progressViewStyle(.linear).controlSize(.small)
                .accessibilityLabel("In progress, size unknown")
        }
    }

    private var accessibilitySummary: String {
        let r = item.record
        var parts = [r.fileName, r.state.label]
        if let f = r.progressFraction, r.state != .completed { parts.append("\(Int(f * 100)) percent") }
        if r.state == .downloading { parts.append(Format.speed(item.smoothedSpeed)) }
        return parts.joined(separator: ", ")
    }
}

struct StatusBadge: View {
    let item: DownloadItem

    var body: some View {
        let state = item.record.state
        HStack(spacing: 3) {
            Image(systemName: symbol(state)).accessibilityHidden(true)
            Text(item.fileMissing ? "File missing" : (item.isPausing ? "Pausing…" : state.label))
                .accessibilityIdentifier("status.\(item.record.fileName)")
        }
        .font(.caption)
        .foregroundStyle(color(state))
    }

    private func symbol(_ s: DownloadState) -> String {
        switch s {
        case .completed: item.fileMissing ? "questionmark.folder" : "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .paused, .interrupted: "pause.circle"
        case .downloading: "arrow.down.circle"
        case .connecting, .verifying: "circle.dotted"
        case .retrying: "arrow.clockwise.circle"
        case .queued: "clock"
        case .waitingForDestination: "externaldrive.badge.exclamationmark"
        case .canceled: "xmark.circle"
        }
    }

    private func color(_ s: DownloadState) -> Color {
        switch s {
        case .failed: .red
        case .completed: item.fileMissing ? .orange : .green
        case .paused, .interrupted, .waitingForDestination, .retrying: .orange
        case .downloading, .connecting, .verifying: .accentColor
        default: .secondary
        }
    }
}

/// The one or two most relevant actions for a row.
struct RowActions: View {
    @Environment(AppModel.self) private var model
    let item: DownloadItem

    var body: some View {
        let s = item.record.state
        HStack(spacing: 4) {
            if s.canPause {
                button("Pause", "pause.fill") { model.pause([item.id]) }
            } else if s == .paused || s == .interrupted || s == .waitingForDestination {
                button("Resume", "play.fill") { model.startOrResume([item.id]) }
            } else if s == .failed {
                button("Retry", "arrow.clockwise") { model.retry([item.id]) }
            } else if s == .canceled {
                button("Restart", "arrow.counterclockwise") { model.coordinator.restart([item.id]) }
            } else if s == .completed, !item.fileMissing {
                button("Show in Finder", "magnifyingglass") { model.reveal(item) }
            }
            if s == .retrying {
                button("Retry Now", "arrow.clockwise") { model.retry([item.id]) }
            }
            if s.canCancel, s != .failed {
                button("Cancel", "xmark") { model.requestCancel([item.id]) }
            }
        }
        .buttonStyle(.borderless)
        .imageScale(.medium)
    }

    private func button(_ title: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: symbol) }
            .help(title)
            .accessibilityLabel("\(title) \(item.record.fileName)")
            .accessibilityIdentifier("action.\(title).\(item.record.fileName)")
    }
}
