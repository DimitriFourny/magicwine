import SwiftUI
import MagicWineCore

struct GraphicsSettingsView: View {
    @ObservedObject var model: AppModel
    let bottle: Bottle
    private struct Selection {
        let backend: GraphicsBackend
        let bottle: Bottle
    }

    @State private var pendingSelection: Selection?
    @State private var pendingUpdate: Bottle?

    private var currentBottle: Bottle {
        model.bottles.first { $0.id == bottle.id } ?? bottle
    }

    private var state: BottleActivity { model.activity(for: currentBottle) }
    private var unavailable: Bool {
        model.isLoading || state.blocksPrefixMutation || !currentBottle.isInitialized
    }

    private var synchronizationUnavailable: Bool {
        model.isLoading || state.blocksPrefixMutation
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
            HStack(spacing: 12) {
                Text("Graphics")
                Spacer(minLength: 8)
                Menu {
                    ForEach(GraphicsBackend.allCases, id: \.self) { backend in
                        Button {
                            guard !unavailable else { return }
                            guard backend != currentBottle.graphics.backend else { return }
                            if backend != .standard {
                                pendingSelection = Selection(backend: backend, bottle: currentBottle)
                            } else {
                                model.setGraphics(.standard, in: currentBottle)
                            }
                        } label: {
                            if backend == currentBottle.graphics.backend {
                                Label(backend.displayName, systemImage: "checkmark")
                            } else {
                                Text(backend.displayName)
                            }
                        }
                    }
                } label: {
                    Text(currentBottle.graphics.backend.displayName)
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.visible)
                .font(.system(size: 13, weight: .medium))
                .tint(WineTheme.text)
                .frame(width: 156, height: 36)
                .padding(.horizontal, 12)
                .background(WineTheme.elevated, in: RoundedRectangle(cornerRadius: 8))
                .overlay {
                    RoundedRectangle(cornerRadius: 8).strokeBorder(WineTheme.border)
                }
                .disabled(unavailable)
                .opacity(unavailable ? 0.5 : 1)
                .accessibilityLabel("Graphics")
                .accessibilityValue(currentBottle.graphics.backend.displayName)
            }

            Text(selectedDetails)
                .font(.callout)
                .foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)

            if currentBottle.graphics.backend != .standard {
                if !currentBottle.graphics.usesSupportedComponent {
                    Text("This bottle uses an unsupported component. Choose Standard to restore its original graphics files before enabling a current component.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                } else if currentBottle.graphics.hasComponentUpdate {
                    let backend = currentBottle.graphics.backend.displayName
                    Text("This bottle uses an older \(backend) component (\(currentBottle.graphics.componentID ?? "unspecified")). It still launches. Updating installs the \(backend) version bundled with this MagicWine and switches this bottle’s graphics files in one step; its original Windows files stay backed up for Standard. The old component is kept until Storage cleanup removes it.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    Button("Update \(backend) component") {
                        guard !unavailable else { return }
                        pendingUpdate = currentBottle
                    }
                    .disabled(unavailable)
                }
                // HUD is launch-time only, so it stays available while programs run.
                let hudUnavailable = model.isLoading || state.blocksLibraryEdit || state.isChangingHUD ||
                    !currentBottle.isInitialized || !currentBottle.graphics.usesSupportedComponent
                HStack(spacing: 6) {
                    Text("Show Graphics HUD")
                    SettingsInfoButton(title: "Show Graphics HUD",
                                       message: "Show the selected graphics backend’s performance overlay in programs launched after you change this. Programs that are already running keep their current overlay; nothing is stopped.\n\nSelected: \(currentBottle.graphics.componentID ?? "unspecified component")\n\nChoose Standard to restore this bottle’s original graphics files.")
                    Spacer(minLength: 12)
                    Toggle("Show Graphics HUD", isOn: Binding(
                        get: { currentBottle.graphics.showHUD },
                        set: { showHUD in
                            guard !hudUnavailable else { return }
                            model.setGraphicsHUD(showHUD, in: currentBottle)
                        }
                    ))
                    .labelsHidden()
                    .disabled(hudUnavailable)
                    .help("Applies to programs launched afterwards; running programs are not stopped.")
                }
                .padding(.vertical, 4)
            }

            HStack(spacing: 6) {
                Text("Retina / HiDPI")
                SettingsInfoButton(title: "Retina / HiDPI",
                                   message: "Enabled by default for sharper desktop apps. Turning Retina on sets 200% scaling; turning it off sets 100%. This bottle-wide setting affects games too and requires stopping Windows programs.")
                Spacer(minLength: 12)
                Toggle("Retina / HiDPI", isOn: Binding(
                    get: { currentBottle.display.retinaEnabled },
                    set: { enabled in
                        guard !unavailable else { return }
                        model.setRetinaEnabled(enabled, in: currentBottle)
                    }
                ))
                .labelsHidden()
                .disabled(unavailable)
            }
            .padding(.vertical, 4)

            HStack(spacing: 6) {
                Text("MSync")
                SettingsInfoButton(title: "MSync",
                                   message: "MSync uses macOS synchronization to reduce Wine server overhead. It works with every graphics backend. Turn it off to use Wine server synchronization. Close Windows programs or use Stop before changing it.")
                Spacer(minLength: 12)
                Toggle("MSync", isOn: Binding(
                    get: { model.supportsMSync(currentBottle) && currentBottle.msyncEnabled },
                    set: { enabled in
                        guard !synchronizationUnavailable, model.supportsMSync(currentBottle) else { return }
                        model.setMSyncEnabled(enabled, in: currentBottle)
                    }
                ))
                .labelsHidden()
                .disabled(synchronizationUnavailable || !model.supportsMSync(currentBottle))
            }
            .padding(.vertical, 4)
            if !model.supportsMSync(currentBottle) {
                if model.canUpgradeRuntime(currentBottle) {
                    Text("Update this bottle’s Wine to enable MSync. Downloads Wine if needed, then switches only this bottle; its files and settings are kept. Close Windows programs or use Stop first.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                    WineInstallationView(model: model, bottle: currentBottle)
                } else {
                    Text("MSync is unavailable for this custom Wine runtime. Its synchronization settings are unchanged. To use MSync, choose Install / Update Wine in Downloads and create a bottle with it.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if !currentBottle.isInitialized {
                Text("Finish bottle setup before changing graphics.")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.hasRunningPrograms && state.title == nil && !state.isStopping {
                Text("Quit Windows programs, including Steam in the tray, or use Stop before changing graphics.")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            } else if state.graphicsProgress == nil && state.blocksPrefixMutation {
                Text("Wait for this bottle’s operation to finish before changing graphics.")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if state.graphicsProgress != nil, let title = state.title {
                ProgressView(title)
                    .controlSize(.small)
            }

            DisclosureGroup("Advanced compatibility") {
                VStack(alignment: .leading, spacing: 10) {
                    Text("DXVK supports Direct3D 9/10/11, DXMT supports 10/11, and imported D3DMetal supports 64-bit 11/12. Metal backends require Apple Silicon and compatible Wine; DXMT needs macOS 15+, D3DMetal needs macOS 14+ or its library’s higher minimum.")
                        .font(.callout)
                        .foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    compatibilitySwitches
                }
                .padding(.top, 4)
            }
        }
        .font(.callout)
        .toggleStyle(.switch)
        .controlSize(.small)
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
            Text(backendNotice(selection.backend) + "\n\nChanging graphics stops this bottle’s Windows processes. Choose Standard to restore its original graphics files.")
        }
        .alert("Update \(pendingUpdate?.graphics.backend.displayName ?? "") component?",
               isPresented: Binding(
                   get: { pendingUpdate != nil },
                   set: { if !$0 { pendingUpdate = nil } }
               ), presenting: pendingUpdate) { bottle in
            Button("Update") {
                model.updateGraphicsComponent(in: bottle)
            }
            .disabled(unavailable)
            Button("Cancel", role: .cancel) { }
        } message: { bottle in
            Text(backendNotice(bottle.graphics.backend) + "\n\nUpdating stops this bottle’s Windows processes, then replaces its \(bottle.graphics.backend.displayName) files in one recoverable step. Choose Standard at any time to restore its original graphics files.")
        }
    }

    /// Launch switches only: available while programs run, applied to later launches.
    @ViewBuilder
    private var compatibilitySwitches: some View {
        let options = currentBottle.compatibility
        let switchesUnavailable = model.isLoading || state.blocksLibraryEdit ||
            model.changingCompatibility.contains(currentBottle.id)
        let avx = model.rosettaAVXAvailability(currentBottle)
        HStack(spacing: 6) {
            Text("Advertise AVX to Rosetta")
            SettingsInfoButton(title: "Advertise AVX to Rosetta",
                               message: "Sets ROSETTA_ADVERTISE_AVX=1, which Apple’s Game Porting Toolkit documents for Rosetta 2 on macOS 15 and later, so x86_64 games that require AVX/AVX2 can start. It only affects x86_64 Wine running under Rosetta. Individual programs can override it in Edit…. Applies to programs launched afterwards.")
            Spacer(minLength: 12)
            Toggle("Advertise AVX to Rosetta", isOn: Binding(
                get: { options.advertiseAVX },
                set: { enabled in
                    var updated = options
                    updated.advertiseAVX = enabled
                    model.setCompatibility(updated, in: currentBottle)
                }
            ))
            .labelsHidden()
            // Turning an unusable setting off stays possible.
            .disabled(switchesUnavailable || (avx != .available && !options.advertiseAVX))
        }
        if case .unavailable(let reason) = avx {
            Text(reason)
                .font(.callout)
                .foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        HStack(spacing: 6) {
            Text("Wine debug output")
            SettingsInfoButton(title: "Wine debug output",
                               message: "Quiet sets WINEDEBUG=fixme-all: Wine’s many “fixme” notes about unimplemented functions are left out of logs, while errors stay. Wine default restores them. For a one-off detailed log, use Launch with Diagnostics… on a program.")
            Spacer(minLength: 12)
            Picker("Wine debug output", selection: Binding(
                get: { options.wineDebug },
                set: { level in
                    var updated = options
                    updated.wineDebug = level
                    model.setCompatibility(updated, in: currentBottle)
                }
            )) {
                ForEach(CompatibilityOptions.WineDebug.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(switchesUnavailable)
        }
        HStack(spacing: 6) {
            Text("DXVK HUD")
            SettingsInfoButton(title: "DXVK HUD",
                               message: "What DXVK’s overlay shows when Show Graphics HUD is on with DXVK: the frame rate only, or the detailed overlay with version, API, device, frame rate, and frame times.")
            Spacer(minLength: 12)
            Picker("DXVK HUD", selection: Binding(
                get: { options.dxvkHUD },
                set: { preset in
                    var updated = options
                    updated.dxvkHUD = preset
                    model.setCompatibility(updated, in: currentBottle)
                }
            )) {
                ForEach(CompatibilityOptions.DXVKHUD.allCases, id: \.self) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .fixedSize()
            .disabled(switchesUnavailable)
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
                .font(.callout)
                .foregroundStyle(WineTheme.muted)
        }
        .buttonStyle(.plain)
        .accessibilityLabel("About \(title)")
        .help("About \(title)")
        .popover(isPresented: $isPresented) {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                Text(message)
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding()
            .frame(width: 320, alignment: .leading)
        }
    }
}
