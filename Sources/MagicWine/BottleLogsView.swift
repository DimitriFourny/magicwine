import AppKit
import SwiftUI
import MagicWineCore

/// A bottle's logs, newest first; double-click or Show opens the viewer.
struct BottleLogsView: View {
    static let windowID = "bottle-logs"

    let model: AppModel
    let bottleID: UUID
    @Environment(\.openWindow) private var openWindow
    @State private var entries: [ProcessLogEntry] = []
    @State private var selected: URL?

    private var bottleName: String {
        model.library.bottles.first { $0.id == bottleID }?.name ?? localized("Deleted bottle")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                Text(localized("\(entries.count) logs, newest first"))
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                Spacer(minLength: 8)
                Button("Refresh") { reload() }
                Button("Show Log") { if let selected { openWindow(id: LogViewerView.windowID, value: selected) } }
                    .disabled(selected == nil)
                Button("Reveal Folder") { Finder.revealLogs(forBottle: bottleID, paths: model.paths) }
            }
            .buttonStyle(WineButtonStyle())
            .padding(12)
            Table(entries, selection: $selected) {
                TableColumn("Date") { entry in
                    Text(entry.date.formatted(date: .abbreviated, time: .standard))
                }
                .width(min: 150, ideal: 170)
                TableColumn("Operation") { entry in
                    HStack(spacing: 6) {
                        Text(entry.operation)
                        if entry.isActive {
                            Text("running")
                                .font(.caption)
                                .foregroundStyle(WineTheme.success)
                        }
                    }
                }
                .width(min: 90, ideal: 120)
                TableColumn("Program") { entry in
                    Text(entry.detail ?? "—").help(entry.detail ?? "")
                }
                TableColumn("Size") { entry in
                    Text(ByteCountFormatter.string(fromByteCount: entry.size, countStyle: .file))
                        .monospacedDigit()
                }
                .width(min: 70, ideal: 80)
            }
            .contextMenu(forSelectionType: URL.self) { urls in
                if let url = urls.first {
                    Button("Show Log") { openWindow(id: LogViewerView.windowID, value: url) }
                    Button("Reveal in Finder") { Finder.reveal(url) }
                }
            } primaryAction: { urls in
                if let url = urls.first { openWindow(id: LogViewerView.windowID, value: url) }
            }
        }
        .frame(minWidth: 620, minHeight: 320)
        .background(WineTheme.background)
        .foregroundStyle(WineTheme.text)
        .tint(WineTheme.accent)
        .navigationTitle("Logs — \(bottleName)")
        .task {
            // Running operations add and close logs; keep the list current while open.
            while !Task.isCancelled {
                reload()
                try? await Task.sleep(for: .seconds(3))
            }
        }
    }

    private func reload() {
        entries = ProcessLogs.list(bottle: bottleID, paths: model.paths)
        if let selected, !entries.contains(where: { $0.url == selected }) { self.selected = nil }
    }
}
