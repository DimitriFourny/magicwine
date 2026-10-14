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
                    Text(backend.displayName + (backend == .standard ? "" : " — Experimental")).tag(backend)
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
                Toggle("Show Graphics HUD", isOn: Binding(
                    get: { currentBottle.graphics.showHUD },
                    set: { showHUD in
                        guard !unavailable, currentBottle.graphics.usesCurrentComponent else { return }
                        model.setGraphics(currentBottle.graphics.backend, in: currentBottle, showHUD: showHUD)
                    }
                ))
                .disabled(unavailable || !currentBottle.graphics.usesCurrentComponent)
                Text("Selected: \(currentBottle.graphics.componentID ?? "unspecified component")")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Choose Standard to restore this bottle’s original graphics files.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("DXVK supports Direct3D 9/10/11, DXMT supports 10/11, and imported D3DMetal supports 64-bit 11/12. Metal backends require Apple Silicon and compatible Wine; DXMT needs macOS 15+, D3DMetal needs macOS 14+ or its library’s higher minimum.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Toggle("Retina / HiDPI", isOn: Binding(
                get: { currentBottle.display.retinaEnabled },
                set: { enabled in
                    guard !unavailable else { return }
                    model.setRetinaEnabled(enabled, in: currentBottle)
                }
            ))
            .disabled(unavailable)
            Text("Enabled by default for sharper desktop apps. Turning Retina on sets 200% scaling; turning it off sets 100%. This bottle-wide setting affects games too and requires stopping Windows programs.")
                .font(.caption).foregroundStyle(.secondary)

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
        .alert("Enable \(pendingSelection?.backend.displayName ?? "") — Experimental?",
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
