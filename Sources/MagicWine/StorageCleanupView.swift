import SwiftUI
import MagicWineCore

/// Unused runtimes, components, private runtime views and leftovers, grouped by category.
struct StorageCleanupView: View {
    @ObservedObject var model: AppModel
    @State private var confirmation: [StorageCleanupItem]?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Wine runtimes, graphics components and private graphics views that no bottle uses anymore. Bottles and their Windows files are never removed here.")
                .font(.callout).foregroundStyle(.secondary)
            if let plan = model.storagePlan {
                if plan.items.isEmpty {
                    Text("Nothing to remove.").foregroundStyle(WineTheme.muted)
                }
                ForEach(StorageCleanupItem.Category.allCases, id: \.self) { category in
                    let items = plan.items.filter { $0.category == category }
                    if !items.isEmpty {
                        DisclosureGroup {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(items) { item in row(item) }
                            }
                            .padding(.top, 6)
                        } label: {
                            HStack {
                                Text(category.title).font(.headline)
                                Spacer()
                                Text("\(items.count) · \(Self.size(items))").foregroundStyle(WineTheme.muted)
                            }
                        }
                    }
                }
                if !plan.keptCurrent.isEmpty {
                    Text("Kept: \(plan.keptCurrent.map(\.url.lastPathComponent).joined(separator: ", ")) (\(Self.size(plan.keptCurrent))). The current Wine and bundled components are unused but expensive to download or reinstall.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Toggle("Include current Wine and bundled components", isOn: Binding(
                get: { model.storageIncludesCurrent },
                set: { model.refreshStoragePlan(includeCurrent: $0) }
            ))
            .disabled(model.storageActivity != nil)
            if let activity = model.storageActivity {
                ProgressView(activity).controlSize(.small)
            }
            if let error = model.storageError {
                Text(error).foregroundStyle(.red).textSelection(.enabled)
            }
            HStack {
                Button(model.storagePlan == nil ? "Check Storage" : "Check Again") { model.refreshStoragePlan() }
                    .disabled(model.storageActivity != nil || model.isLoading)
                Button("Remove…") { confirmation = model.storagePlan?.items }
                    .disabled(model.blocksStorageCleanup || model.storagePlan?.items.isEmpty != false)
            }
            if model.blocksStorageCleanup, model.storageActivity == nil, model.storagePlan?.items.isEmpty == false {
                Text("Finish bottle and Wine operations and stop running programs before removing files.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .onAppear {
            if model.storagePlan == nil, model.storageActivity == nil, !model.isLoading { model.refreshStoragePlan() }
        }
        .sheet(isPresented: Binding(get: { confirmation != nil }, set: { if !$0 { confirmation = nil } })) {
            if let items = confirmation { confirm(items) }
        }
    }

    private func row(_ item: StorageCleanupItem) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .firstTextBaseline) {
                Text(item.url.lastPathComponent).font(.callout.monospaced()).lineLimit(1).truncationMode(.middle)
                Spacer()
                Text(Self.size([item])).font(.callout).foregroundStyle(WineTheme.muted)
            }
            Text(item.reason).font(.caption).foregroundStyle(.secondary)
            if item.requiresReimport {
                Label("Re-import required to use D3DMetal again", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
        .textSelection(.enabled)
    }

    private func confirm(_ items: [StorageCleanupItem]) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Remove \(items.count) Unused Items?").font(.title2)
            Text("These are deleted permanently, not moved to Trash. MagicWine checks again that nothing uses them and refuses while any bottle is running or being set up. Bottles and their Windows files are not affected.")
                .font(.callout).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(items) { item in
                        HStack(alignment: .firstTextBaseline) {
                            Text(item.url.path).font(.caption.monospaced()).textSelection(.enabled)
                            Spacer()
                            Text(Self.size([item])).font(.caption)
                            if item.requiresReimport { Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange) }
                        }
                    }
                }
            }
            .frame(maxHeight: 280)
            if items.contains(where: \.requiresReimport) {
                Text("Imported D3DMetal libraries cannot be restored by MagicWine; import them again before selecting D3DMetal.")
                    .font(.caption).foregroundStyle(.orange)
            }
            HStack {
                Button("Cancel") { confirmation = nil }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Remove \(Self.size(items))", role: .destructive) {
                    confirmation = nil
                    model.removeStorage(items)
                }
                .disabled(model.blocksStorageCleanup)
            }
        }
        .padding(24).frame(width: 620)
    }

    private static func size(_ items: [StorageCleanupItem]) -> String {
        ByteCountFormatter.string(fromByteCount: items.reduce(0) { $0 + $1.size }, countStyle: .file)
    }
}
