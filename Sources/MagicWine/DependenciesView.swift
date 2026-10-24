import AppKit
import MagicWineCore
import SwiftUI

/// Curated Windows runtimes for one bottle, with status from their post-install checks.
struct DependenciesView: View {
    let model: AppModel
    let bottle: Bottle
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openWindow) private var openWindow
    @State private var confirmation: DependencyItem?

    private var currentBottle: Bottle { model.library.current(bottle) }
    private var activity: BottleActivity { model.activity.activity(for: currentBottle) }
    private var installUnavailable: Bool { activity.blocksPrefixMutation || !currentBottle.isInitialized }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Windows Dependencies").font(.title2)
            Text("Runtimes many games and launchers expect. MagicWine downloads pinned files (from Microsoft; the fonts from a pinned mirror of Microsoft’s original packages), verifies their SHA-256 checksums, and installs them into this bottle only. Each item has its own license.")
                .font(.callout).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            feedback
            if let statuses = model.dependencies.statuses[bottle.id] {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(statuses) { status in
                            if status.id != statuses.first?.id { Divider() }
                            row(status)
                        }
                    }
                }
                .frame(maxHeight: 420)
            } else {
                ProgressView().frame(maxWidth: .infinity)
            }
            HStack {
                Text(".NET Framework is not offered: see the runtime guide.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(24).frame(width: 660)
        .onAppear { model.dependencies.refresh(in: currentBottle) }
        .alert("Install \(confirmation?.name ?? "")?", isPresented: Binding(
            get: { confirmation != nil },
            set: { if !$0 { confirmation = nil } }
        ), presenting: confirmation) { item in
            Button("Accept License and Install") { model.dependencies.install([item.id], in: currentBottle) }
                .disabled(installUnavailable)
            Button("View License") { NSWorkspace.shared.open(item.license.url) }
            Button("Cancel", role: .cancel) { }
        } message: { item in
            Text("MagicWine downloads \(Self.size(item.downloadSize)) from \(Set(item.downloads.compactMap { $0.url.host }).sorted().joined(separator: ", ")) and installs \(item.name) \(item.version) into “\(currentBottle.name)”. Installing means you accept the \(item.license.name):\n\(item.license.url.absoluteString)")
        }
    }

    @ViewBuilder
    private var feedback: some View {
        if case .downloading(_, let progress)? = model.dependencies.progress[bottle.id] {
            WineDownloadProgressView(progress: progress, title: activity.title ?? "Downloading…")
        } else if model.dependencies.progress[bottle.id] != nil, let title = activity.title {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text(title).font(.callout)
                Spacer()
                if let log = activity.logURL {
                    Button("Show Log") { openWindow(id: LogViewerView.windowID, value: log) }
                }
            }
        }
        if let error = model.dependencies.errors[bottle.id] {
            VStack(alignment: .leading, spacing: 8) {
                Label("Installation failed", systemImage: "exclamationmark.triangle").font(.headline)
                Text(error).font(.callout).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                if let log = activity.logURL {
                    Button("Show Log") { openWindow(id: LogViewerView.windowID, value: log) }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 8).fill(WineTheme.danger.opacity(0.12)))
        }
    }

    private func row(_ status: DependencyStatus) -> some View {
        let item = status.item
        let architecture = item.architectures.isEmpty ? "All programs" : item.architectures.map(\.rawValue).joined(separator: " + ")
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(item.name).font(.system(.callout, weight: .semibold))
                Text("\(item.version) · \(architecture) · \(Self.size(item.downloadSize))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(item.summary).font(.caption).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Link(item.license.name, destination: item.license.url).font(.caption)
                if status.isPartial {
                    Text("Incomplete: \(status.missing.prefix(3).joined(separator: ", "))\(status.missing.count > 3 ? ", …" : "")")
                        .font(.caption).foregroundStyle(WineTheme.warning)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if status.isInstalled {
                Label("Installed", systemImage: "checkmark.circle.fill")
                    .font(.callout).foregroundStyle(WineTheme.success)
                    .help(status.record.map { "Installed by MagicWine on \($0.installedAt.formatted(date: .abbreviated, time: .shortened))" }
                          ?? "Already present in this bottle")
            } else {
                Button(status.isPartial ? "Repair…" : "Install…") { confirmation = item }
                    .disabled(installUnavailable)
                    .help(installUnavailable ? "Wait for this bottle’s operation to finish and close its programs first" : "Shows the license before installing")
            }
        }
        .padding(.vertical, 10)
    }

    private static func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
