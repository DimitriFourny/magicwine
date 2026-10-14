import SwiftUI
import MagicWineCore

struct GraphicsSettingsView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    let busy: Bool
    private struct Selection {
        let backend: GraphicsBackend
        let bottle: Bottle
    }

    @State private var pendingSelection: Selection?

    private var currentBottle: Bottle {
        model.bottles.first { $0.id == bottle.id } ?? bottle
    }

    private var state: BottleActivity { model.activity(for: currentBottle) }
    private var unavailable: Bool {
        busy || model.isLoading || state.title != nil || state.hasRunningPrograms || state.isStopping || !currentBottle.isInitialized
    }

    private var synchronizationUnavailable: Bool {
        busy || model.isLoading || state.title != nil || state.hasRunningPrograms || state.isStopping
    }

    private func backendNotice(_ backend: GraphicsBackend) -> String {
        switch backend {
        case .standard: ""
        case .dxvk: WineRuntime.dxvkNotice
        case .dxmt: WineRuntime.dxmtNotice
        case .d3dmetal: WineRuntime.d3dMetalNotice
        }
    }

    private var selectedDetails: String {
        switch currentBottle.graphics.backend {
        case .standard: "Standard uses Wine’s built-in graphics."
        case .dxvk: "Direct3D 9/10/11 → Vulkan/MoltenVK · No Direct3D 12"
        case .dxmt: "Direct3D 10/11 → Metal · No Direct3D 9/12 · Compatible Wine required"
        case .d3dmetal: "64-bit Direct3D 11/12 → Metal · Apple libraries and compatible Wine required"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Graphics", selection: Binding(
                get: { currentBottle.graphics.backend },
                set: { backend in
                    guard !unavailable else { return }
                    guard backend != currentBottle.graphics.backend else { return }
                    if backend != .standard {
                        pendingSelection = Selection(backend: backend, bottle: currentBottle)
                    } else {
                        model.setGraphics(.standard, in: currentBottle)
                    }
                }
            )) {
                ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                    Text(backend.displayName).tag(backend)
                }
            }
            .pickerStyle(.menu)
            .disabled(unavailable)

            Text(selectedDetails)
                .font(.caption).foregroundStyle(.secondary)

            if currentBottle.graphics.backend != .standard {
                if !currentBottle.graphics.usesCurrentComponent {
                    Text("This bottle uses an unsupported component. Choose Standard to restore its original graphics files before enabling a current component.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                HStack(spacing: 6) {
                    Toggle("Show Graphics HUD", isOn: Binding(
                        get: { currentBottle.graphics.showHUD },
                        set: { showHUD in
                            guard !unavailable, currentBottle.graphics.usesCurrentComponent else { return }
                            model.setGraphics(currentBottle.graphics.backend, in: currentBottle, showHUD: showHUD)
                        }
                    ))
                    .disabled(unavailable || !currentBottle.graphics.usesCurrentComponent)
                    SettingsInfoButton(title: "Show Graphics HUD",
                                       message: "Show the selected graphics backend’s performance overlay.\n\nSelected: \(currentBottle.graphics.componentID ?? "unspecified component")\n\nChoose Standard to restore this bottle’s original graphics files.")
                }
            } else {
                Text("DXVK supports Direct3D 9/10/11, DXMT supports 10/11, and imported D3DMetal supports 64-bit 11/12. Metal backends require Apple Silicon and compatible Wine; DXMT needs macOS 15+, D3DMetal needs macOS 14+ or its library’s higher minimum.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            HStack(spacing: 6) {
                Toggle("Retina / HiDPI", isOn: Binding(
                    get: { currentBottle.display.retinaEnabled },
                    set: { enabled in
                        guard !unavailable else { return }
                        model.setRetinaEnabled(enabled, in: currentBottle)
                    }
                ))
                .disabled(unavailable)
                SettingsInfoButton(title: "Retina / HiDPI",
                                   message: "Enabled by default for sharper desktop apps. Turning Retina on sets 200% scaling; turning it off sets 100%. This bottle-wide setting affects games too and requires stopping Windows programs.")
            }

            HStack(spacing: 6) {
                Toggle("MSync", isOn: Binding(
                    get: { model.supportsMSync(currentBottle) && currentBottle.msyncEnabled },
                    set: { enabled in
                        guard !synchronizationUnavailable, model.supportsMSync(currentBottle) else { return }
                        model.setMSyncEnabled(enabled, in: currentBottle)
                    }
                ))
                .disabled(synchronizationUnavailable || !model.supportsMSync(currentBottle))
                SettingsInfoButton(title: "MSync",
                                   message: "MSync uses macOS synchronization to reduce Wine server overhead. It works with every graphics backend. Turn it off to use Wine server synchronization. Close Windows programs or use Stop before changing it.")
            }
            if !model.supportsMSync(currentBottle) {
                if model.canUpgradeRuntime(currentBottle) {
                    Text("Update this bottle’s Wine to enable MSync. Downloads Wine if needed, then switches only this bottle; its files and settings are kept. Close Windows programs or use Stop first.")
                        .font(.caption).foregroundStyle(.secondary)
                    WineInstallationView(model: model, bottle: currentBottle)
                } else {
                    Text("MSync is unavailable for this custom Wine runtime. Its synchronization settings are unchanged. To use MSync, choose Install / Update Wine in Downloads and create a bottle with it.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }

            if !currentBottle.isInitialized {
                Text("Finish bottle setup before changing graphics.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.graphicsProgress == nil && (busy || state.isStopping) {
                Text("Wait for this bottle’s operation to finish before changing graphics.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if state.graphicsProgress != nil, let title = state.title {
                ProgressView(title)
                    .controlSize(.small)
            }
        }
        .alert("Enable \(pendingSelection?.backend.displayName ?? "")?",
               isPresented: Binding(
                   get: { pendingSelection != nil },
                   set: { if !$0 { pendingSelection = nil } }
               ), presenting: pendingSelection) { selection in
            Button("Enable \(selection.backend.displayName)") {
                if selection.backend == .d3dmetal {
                    model.importD3DMetal(in: selection.bottle)
                } else {
                    model.setGraphics(selection.backend, in: selection.bottle,
                                      showHUD: selection.bottle.graphics.showHUD)
                }
            }
            .disabled(unavailable)
            Button("Cancel", role: .cancel) { }
        } message: { selection in
            Text(backendNotice(selection.backend) + "\n\nChanging graphics stops this bottle’s Windows processes. Choose Standard to restore its original graphics files. In-place component updates are not supported.")
        }
    }
}

private struct SettingsInfoButton: View {
    let title: String
    let message: String
    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            Image(systemName: "info.circle")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .help("About \(title)")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 320, alignment: .leading)
        }
    }
}
