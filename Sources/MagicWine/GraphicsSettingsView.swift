import SwiftUI
import MagicWineCore

struct GraphicsSettingsView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    let busy: Bool
    @State private var confirmsDXVK = false

    private var currentBottle: Bottle {
        model.bottles.first { $0.id == bottle.id } ?? bottle
    }

    private var state: BottleActivity { model.activity(for: currentBottle) }
    private var unavailable: Bool {
        busy || model.isLoading || state.title != nil || state.isStopping || !currentBottle.isInitialized
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Picker("Graphics", selection: Binding(
                get: { currentBottle.graphics.backend },
                set: { backend in
                    guard !unavailable, backend != currentBottle.graphics.backend else { return }
                    if backend == .dxvk {
                        confirmsDXVK = true
                    } else {
                        model.setGraphics(.standard, in: currentBottle)
                    }
                }
            )) {
                Text("Standard").tag(GraphicsBackend.standard)
                Text("DXVK — Experimental").tag(GraphicsBackend.dxvk)
            }
            .pickerStyle(.menu)
            .disabled(unavailable)

            if currentBottle.graphics.backend == .dxvk {
                Toggle("Show Graphics HUD", isOn: Binding(
                    get: { currentBottle.graphics.showHUD },
                    set: { showHUD in
                        guard !unavailable else { return }
                        model.setGraphics(.dxvk, in: currentBottle, showHUD: showHUD)
                    }
                ))
                .disabled(unavailable)
                Text("Selected: DXVK 1.10.3-based macOS fork · Direct3D 10/11 only")
                    .font(.caption).foregroundStyle(.secondary)
                Text("Choose Standard to restore this bottle’s original graphics files.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                Text("Standard uses Wine’s built-in graphics. DXVK is an optional experimental Direct3D 10/11 backend; it does not add Direct3D 9/12 support.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if !currentBottle.isInitialized {
                Text("Finish bottle setup before changing graphics.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if state.graphicsProgress == nil && (busy || state.isStopping) {
                Text("Wait for this bottle’s operation to finish before changing graphics.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if case let .downloading(progress) = state.graphicsProgress {
                WineDownloadProgressView(progress: progress, title: "Downloading DXVK…")
            } else if state.graphicsProgress != nil, let title = state.title {
                ProgressView(title)
                    .controlSize(.small)
            }
        }
        .alert("Enable DXVK — Experimental?", isPresented: $confirmsDXVK) {
            Button("Enable DXVK") { model.setGraphics(.dxvk, in: currentBottle) }
                .disabled(unavailable)
            Button("Cancel", role: .cancel) { }
        } message: {
            Text(WineRuntime.dxvkNotice + "\n\nThe package is downloaded from Gcenx/DXVK-macOS and installed only in this bottle. Changing graphics stops this bottle’s Windows processes. Choose Standard to restore its original graphics files without another download.")
        }
    }
}
