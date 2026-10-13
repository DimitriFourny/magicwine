import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MagicWineCore

@MainActor
struct GamepadView: View {
    let paths: ApplicationPaths
    @ObservedObject private var service = GamepadService.shared
    @State private var configuration = GamepadConfiguration()
    @State private var savedConfiguration: GamepadConfiguration?
    @State private var loaded = false
    @State private var selectedDeviceID: UUID?
    @State private var errorMessage: String?
    @State private var notice: String?
    @State private var calibrationTarget: UUID?
    @State private var showingCalibration = false
    @State private var showingDelete = false
    @State private var showingDiscard = false
    @FocusState private var liveInputFocused: Bool

    private var store: GamepadProfileStore { GamepadProfileStore(paths: paths) }
    private var profile: GamepadProfile { configuration.activeProfile }
    private var dirty: Bool { loaded && configuration != savedConfiguration }
    private var device: GamepadDevice? {
        service.devices.first { $0.id == selectedDeviceID }
    }
    private var rawInput: GamepadInput {
        guard let device else { return GamepadInput() }
        return service.inputs[device.id] ?? GamepadInput()
    }
    private var previewInput: GamepadInput {
        guard device != nil else { return GamepadInput() }
        return profile.applying(to: rawInput)
    }

    var body: some View {
        GeometryReader { geometry in
            let width = max(0, geometry.size.width - 40)
            ScrollViewReader { reader in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        hero
                        feedback
                        if width >= 980 {
                            HStack(alignment: .top, spacing: 16) {
                                overview(reader: reader).frame(width: (width - 16) * 0.51)
                                mappings
                            }
                        } else {
                            overview(reader: reader)
                            mappings
                        }
                        if width >= 1100 {
                            HStack(alignment: .top, spacing: 16) {
                                deviceInformation.frame(width: (width - 32) * 0.25)
                                calibration.frame(width: (width - 32) * 0.34)
                                liveInput
                            }
                        } else if width >= 850 {
                            HStack(alignment: .top, spacing: 16) {
                                deviceInformation.frame(width: (width - 16) * 0.42)
                                calibration
                            }
                            liveInput
                        } else {
                            deviceInformation
                            calibration
                            liveInput
                        }
                        profiles
                    }
                    .frame(width: width, alignment: .leading)
                    .padding(20)
                }
                .background(WineTheme.background)
            }
        }
        .buttonStyle(WineButtonStyle())
        .foregroundStyle(WineTheme.text)
        .tint(WineTheme.accent)
        .navigationTitle("Gamepads")
        .task {
            service.start()
            if !loaded { loadConfiguration() }
            reconcileDevices()
        }
        .onChange(of: service.devices.map(\.id)) { reconcileDevices() }
        .alert("Release both sticks", isPresented: $showingCalibration) {
            Button("Cancel", role: .cancel) { calibrationTarget = nil }
            Button("Capture Center") { captureCalibration() }
        } message: {
            Text("Place the controller on a stable surface and release both sticks. Capture Center measures their current resting position and adds a small dead-zone margin. Save Changes to apply the result to games.")
        }
        .alert("Delete profile?", isPresented: $showingDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) { deleteProfile() }
        } message: {
            Text("Remove \(profile.name) from your draft? This is not written to disk until you save changes.")
        }
        .alert("Discard unsaved changes?", isPresented: $showingDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive) {
                if let savedConfiguration { configuration = savedConfiguration }
                notice = "Restored the last saved configuration."
            }
        } message: {
            Text("All profile edits, imports, and selection changes since your last save will be discarded.")
        }
    }

    private var hero: some View {
        HStack(spacing: 22) {
            Image(systemName: "gamecontroller")
                .font(.system(size: 48, weight: .light))
                .foregroundStyle(Color(red: 0.94, green: 0.40, blue: 0.63))
                .frame(width: 100, height: 104)
                .background(WineTheme.accent.opacity(0.15), in: RoundedRectangle(cornerRadius: 18))
                .overlay {
                    RoundedRectangle(cornerRadius: 18)
                        .strokeBorder(WineTheme.accent.opacity(0.8), lineWidth: 1)
                }
                .shadow(color: WineTheme.accent.opacity(0.22), radius: 12)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 9) {
                Text("Gamepad Configuration")
                    .font(.system(size: 34, weight: .regular, design: .serif))
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityAddTraits(.isHeader)
                Text("Map buttons, calibrate sticks, and manage profiles.")
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                HStack(spacing: 7) {
                    Circle()
                        .fill(service.devices.isEmpty ? WineTheme.muted : WineTheme.success)
                        .frame(width: 8, height: 8)
                    Text("\(service.devices.count) controller\(service.devices.count == 1 ? "" : "s") connected")
                        .font(.system(size: 12, weight: .medium))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(service.devices.isEmpty ? WineTheme.elevated : WineTheme.success.opacity(0.13), in: Capsule())
                .accessibilityElement(children: .combine)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(22)
        .background {
            GeometryReader { geometry in
                ZStack(alignment: .trailing) {
                    WineTheme.panel
                    Image(nsImage: WineArtwork.cellar)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width * 0.58, height: geometry.size.height)
                        .clipped()
                        .mask {
                            LinearGradient(colors: [.clear, .black.opacity(0.5), .black],
                                           startPoint: .leading, endPoint: .trailing)
                        }
                        .opacity(0.6)
                        .accessibilityHidden(true)
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16))
        .overlay { RoundedRectangle(cornerRadius: 16).strokeBorder(WineTheme.border) }
    }

    @ViewBuilder
    private var feedback: some View {
        if let errorMessage {
            WineCard(title: "Unable to Complete Action", icon: "exclamationmark.triangle") {
                Text(errorMessage).font(.callout).textSelection(.enabled)
                HStack {
                    if !loaded {
                        Button("Retry Loading") { loadConfiguration() }
                    } else {
                        Button("Dismiss") { self.errorMessage = nil }
                    }
                }
                .buttonStyle(WineButtonStyle())
            }
        }
        if let error = service.error {
            Label(error, systemImage: "exclamationmark.triangle")
                .font(.callout).foregroundStyle(.orange)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
        }
        if let notice {
            HStack(alignment: .top) {
                Text(notice).font(.callout).foregroundStyle(WineTheme.muted)
                Spacer(minLength: 8)
                Button { self.notice = nil } label: { Image(systemName: "xmark") }
                    .buttonStyle(.plain).accessibilityLabel("Dismiss status message")
            }
        }
    }

    private func overview(reader: ScrollViewProxy) -> some View {
        WineCard(title: "Controller Overview", icon: "gamecontroller") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { overviewActions(reader: reader) }
                VStack(alignment: .leading, spacing: 8) { overviewActions(reader: reader) }
            }
            if !service.devices.isEmpty {
                Picker("Controller", selection: $selectedDeviceID) {
                    ForEach(service.devices) { device in
                        Text(device.name).tag(Optional(device.id))
                    }
                }
                .pickerStyle(.menu)
                .accessibilityLabel("Controller to inspect")
            }
            GamepadDiagram(input: rawInput, connected: device != nil)
                .aspectRatio(1.8, contentMode: .fit)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
            if let device {
                Text("\(device.name) · physical input")
                    .font(.caption).foregroundStyle(WineTheme.muted)
                    .frame(maxWidth: .infinity)
            } else {
                VStack(alignment: .leading, spacing: 7) {
                    Text("Connect a controller to get started")
                        .font(.system(size: 15, weight: .semibold))
                    Text("Pair a supported game controller in macOS Bluetooth settings or connect it with USB. Connected controllers appear automatically. You can edit and save profiles without a controller.")
                        .font(.callout).foregroundStyle(WineTheme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }

    @ViewBuilder
    private func overviewActions(reader: ScrollViewProxy) -> some View {
        Button {
            withAnimation { reader.scrollTo("gamepad-live-input", anchor: .center) }
            liveInputFocused = true
        } label: {
            Label("Test Input", systemImage: "waveform.path.ecg")
        }
        .disabled(device == nil)
        Button {
            guard let device else { return }
            perform {
                try service.identify(device.id, strength: profile.vibrationStrength)
                notice = "Identification pulse sent to \(device.name)."
            }
        } label: {
            Label("Identify", systemImage: "sun.max")
        }
        .disabled(device?.supportsHaptics != true || profile.vibrationStrength == 0 || !loaded)
        .help("Play a short vibration at the draft strength. Requires controller haptics and a nonzero strength.")
        .buttonStyle(WineButtonStyle())
    }

    private var mappings: some View {
        WineCard(title: "Button Mapping", icon: "square.3.layers.3d") {
            HStack {
                Text("Physical input → XInput output")
                    .font(.caption).foregroundStyle(WineTheme.muted)
                Spacer(minLength: 4)
                Button("Reset Mappings") {
                    updateProfile { $0.mappings.removeAll() }
                }
                .buttonStyle(WineButtonStyle())
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 215), spacing: 16)], spacing: 8) {
                ForEach(GamepadControl.inputs) { control in
                    HStack(spacing: 8) {
                        Text(control.displayName)
                            .font(.system(size: 11, weight: .medium))
                            .frame(width: 65, alignment: .leading)
                        Picker(control.displayName, selection: mappingBinding(control)) {
                            ForEach(GamepadControl.allCases) { destination in
                                Text(destination == .none ? "Unmapped" : "XInput \(destination.displayName)")
                                    .tag(destination)
                            }
                        }
                        .labelsHidden()
                        .pickerStyle(.menu)
                        .frame(maxWidth: .infinity)
                        .accessibilityLabel("Map \(control.displayName) to")
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 7)
                    .background(WineTheme.elevated.opacity(0.42), in: RoundedRectangle(cornerRadius: 6))
                }
            }
            Text("Stick movement remains analog. Stick-click buttons and each D-pad direction can be remapped independently. Choose Unmapped to disable an input.")
                .font(.caption).foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!loaded)
    }

    private var deviceInformation: some View {
        WineCard(title: "Device Information", icon: "info.circle") {
            informationRow("Controller", value: device?.name ?? "Not connected")
            Divider().overlay(WineTheme.border)
            informationRow("Connection", value: device.map { $0.isBluetooth ? "Bluetooth" : "Not reported" } ?? "—") {
                if device?.isBluetooth == true {
                    BluetoothSymbol()
                        .stroke(.blue, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, lineJoin: .round))
                        .frame(width: 9, height: 14)
                }
            }
            informationRow("Player", value: device.map {
                $0.playerIndex.map { "\($0 + 1) of 4" } ?? "No XInput slot"
            } ?? "—")
            informationRow("Battery", value: batteryDescription) {
                Image(systemName: batterySymbol)
                    .foregroundStyle(device?.batteryLevel.map { $0 <= 0.2 ? Color.red : WineTheme.success } ?? WineTheme.muted)
            }
            informationRow("Haptics", value: device.map { $0.supportsHaptics ? "Supported" : "Unavailable" } ?? "—")
            informationRow("Output", value: "XInput")
            Divider().overlay(WineTheme.border)
            Text("The saved profile applies to all bridged controllers. Up to four controllers can provide XInput to Windows games. Keep MagicWine running while you play.")
                .font(.caption).foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if device != nil, device?.playerIndex == nil {
                Label("All four XInput slots are in use. This controller can be inspected here but is not currently bridged.", systemImage: "exclamationmark.circle")
                    .font(.caption).foregroundStyle(.orange)
            }
        }
    }

    private var batteryDescription: String {
        guard let device else { return "—" }
        guard let battery = device.batteryLevel else { return "Not reported" }
        return "\(Int((battery * 100).rounded()))%\(device.batteryCharging ? " · Charging" : "")"
    }

    private var batterySymbol: String {
        guard let device, let level = device.batteryLevel else { return "battery.0percent" }
        if device.batteryCharging { return "battery.100percent.bolt" }
        switch level {
        case ..<0.1: return "battery.0percent"
        case ..<0.35: return "battery.25percent"
        case ..<0.65: return "battery.50percent"
        case ..<0.9: return "battery.75percent"
        default: return "battery.100percent"
        }
    }

    private func informationRow(_ title: String, value: String,
                                @ViewBuilder icon: () -> some View = { EmptyView() }) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title).foregroundStyle(WineTheme.muted)
            Spacer(minLength: 4)
            HStack(spacing: 6) {
                icon().accessibilityHidden(true)
                Text(value).multilineTextAlignment(.trailing).textSelection(.enabled)
            }
        }
        .font(.system(size: 12))
        .accessibilityElement(children: .combine)
    }

    private var calibration: some View {
        WineCard(title: "Calibration", icon: "slider.horizontal.3") {
            HStack {
                Text("Tune the active profile")
                    .font(.caption).foregroundStyle(WineTheme.muted)
                Spacer(minLength: 4)
                Button("Calibrate") {
                    calibrationTarget = device?.id
                    showingCalibration = true
                }
                .buttonStyle(WineButtonStyle())
                .disabled(device == nil)
            }
            calibrationSlider("Left Stick Dead Zone", value: profileBinding(\.leftDeadZone), range: 0...0.4)
            calibrationSlider("Right Stick Dead Zone", value: profileBinding(\.rightDeadZone), range: 0...0.4)
            calibrationSlider("Trigger Sensitivity", value: profileBinding(\.triggerSensitivity), range: 0.5...2)
            Picker("Stick Response Curve", selection: profileBinding(\.responseCurve)) {
                ForEach(GamepadResponseCurve.allCases) { curve in
                    Text(curve.displayName).tag(curve)
                }
            }
            .pickerStyle(.menu)
            .font(.system(size: 12))
            calibrationSlider("Vibration Strength", value: profileBinding(\.vibrationStrength), range: 0...1)
            Text("Calibration measures released sticks. Sliders and the live preview update your draft; games use the saved profile. Vibration requires controller haptics.")
                .font(.caption).foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!loaded)
    }

    private func calibrationSlider(_ title: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title)
                Spacer(minLength: 8)
                Text("\(Int((value.wrappedValue * 100).rounded()))%")
                    .monospacedDigit().foregroundStyle(WineTheme.muted)
            }
            .font(.system(size: 12))
            Slider(value: value, in: range)
                .accessibilityLabel(title)
                .accessibilityValue("\(Int((value.wrappedValue * 100).rounded())) percent")
        }
    }

    private var liveInput: some View {
        let input = previewInput
        return WineCard(title: "Live Input Test", icon: "waveform.path.ecg", trailing: device == nil ? "Disconnected" : "Draft preview") {
            if device == nil {
                Text("No live input. Connect a controller to test your draft mappings and calibration.")
                    .font(.callout).foregroundStyle(WineTheme.muted)
            }
            HStack(spacing: 18) {
                GamepadStickPlot(title: "Left Stick", x: input.leftX, y: input.leftY,
                                 deadZone: profile.leftDeadZone, connected: device != nil)
                GamepadStickPlot(title: "Right Stick", x: input.rightX, y: input.rightY,
                                 deadZone: profile.rightDeadZone, connected: device != nil)
            }
            .frame(maxWidth: 380)
            .frame(maxWidth: .infinity)
            triggerMeter("LT", value: input.leftTrigger)
            triggerMeter("RT", value: input.rightTrigger)
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 75), spacing: 8)], spacing: 8) {
                ForEach(GamepadControl.inputs.filter { $0 != .leftTrigger && $0 != .rightTrigger }) { control in
                    let active = device != nil && input.value(for: control) > 0
                    HStack(spacing: 6) {
                        Circle().fill(active ? WineTheme.accent : WineTheme.elevated)
                            .frame(width: 8, height: 8)
                            .overlay { Circle().strokeBorder(WineTheme.muted.opacity(0.4)) }
                        Text(control.displayName).font(.system(size: 10, weight: .medium))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(control.displayName)
                    .accessibilityValue(device == nil ? "Disconnected" : active ? "Pressed" : "Released")
                }
            }
            Text("Mapped output · \(profile.name)\(dirty ? " · Unsaved" : "")")
                .font(.caption).foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .id("gamepad-live-input")
        .focusable()
        .focused($liveInputFocused)
        .overlay {
            RoundedRectangle(cornerRadius: 12)
                .strokeBorder(liveInputFocused ? WineTheme.accent : .clear, lineWidth: 2)
        }
    }

    private func triggerMeter(_ title: String, value: Double) -> some View {
        HStack(spacing: 10) {
            Text(title).font(.system(size: 11, weight: .medium)).frame(width: 22)
            GeometryReader { geometry in
                Capsule().fill(WineTheme.elevated)
                Capsule().fill(WineTheme.accent)
                    .frame(width: geometry.size.width * min(1, max(0, value)))
            }
            .frame(height: 9)
            Text(device == nil ? "—" : "\(Int((value * 100).rounded()))%")
                .font(.system(size: 11)).monospacedDigit()
                .frame(width: 36, alignment: .trailing)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title) trigger")
        .accessibilityValue(device == nil ? "Disconnected" : "\(Int((value * 100).rounded())) percent")
    }

    private var profiles: some View {
        WineCard(title: "Profiles", icon: "square.3.layers.3d", trailing: dirty ? "Unsaved changes" : loaded ? "Saved" : "Not loaded") {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) {
                    transferActions
                    Spacer(minLength: 8)
                    saveActions
                }
                VStack(alignment: .leading, spacing: 10) {
                    HStack(spacing: 8) { transferActions }
                    HStack(spacing: 8) { saveActions }
                }
            }
            LazyVGrid(columns: [GridItem(.adaptive(minimum: 190), spacing: 10)], spacing: 10) {
                ForEach(configuration.profiles) { item in
                    profileCard(item)
                }
            }
            HStack(spacing: 10) {
                Text("Profile Name").font(.callout)
                TextField("Profile name", text: profileBinding(\.name))
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Active profile name")
                Button(role: .destructive) { showingDelete = true } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(WineButtonStyle())
                .disabled(configuration.profiles.count <= 1)
                .accessibilityLabel("Delete active profile")
            }
            Text("Select a profile to edit it. Switching profiles keeps your other draft edits. Save Changes applies the selected profile to all controllers and persists your library.")
                .font(.caption).foregroundStyle(WineTheme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
        .disabled(!loaded)
    }

    @ViewBuilder
    private var transferActions: some View {
        Button { importProfile() } label: { Label("Import", systemImage: "square.and.arrow.down") }
        Button { exportProfile() } label: { Label("Export", systemImage: "square.and.arrow.up") }
        Button { duplicateProfile() } label: { Label("Duplicate", systemImage: "doc.on.doc") }
    }

    @ViewBuilder
    private var saveActions: some View {
        Button("Discard Changes") { showingDiscard = true }
            .buttonStyle(WineButtonStyle())
            .disabled(!dirty)
        Button { saveConfiguration() } label: { Label("Save Changes", systemImage: "square.and.arrow.down") }
            .buttonStyle(WineButtonStyle(prominent: true))
            .disabled(!dirty)
    }

    private func profileCard(_ item: GamepadProfile) -> some View {
        let selected = item.id == configuration.activeProfileID
        return Button {
            configuration.activeProfileID = item.id
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? WineTheme.accent : WineTheme.muted)
                VStack(alignment: .leading, spacing: 5) {
                    Text(item.name).font(.system(size: 13, weight: .semibold))
                        .lineLimit(2)
                    Text("\(item.responseCurve.displayName) · \(item.mappings.filter { $0.key != $0.value }.count) remaps")
                        .font(.caption).foregroundStyle(WineTheme.muted)
                }
                Spacer(minLength: 0)
            }
            .padding(13)
            .frame(maxWidth: .infinity, minHeight: 65, alignment: .leading)
            .background(selected ? WineTheme.accent.opacity(0.20) : WineTheme.elevated.opacity(0.6),
                        in: RoundedRectangle(cornerRadius: 9))
            .overlay {
                RoundedRectangle(cornerRadius: 9)
                    .strokeBorder(selected ? WineTheme.accent : WineTheme.border, lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 9))
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(item.name) profile")
        .accessibilityValue(selected ? "Selected" : "Not selected")
    }

    private func profileBinding<Value>(_ keyPath: WritableKeyPath<GamepadProfile, Value>) -> Binding<Value> {
        Binding(get: { profile[keyPath: keyPath] }, set: { value in
            updateProfile { $0[keyPath: keyPath] = value }
        })
    }

    private func mappingBinding(_ control: GamepadControl) -> Binding<GamepadControl> {
        Binding(get: { profile.mappedControl(for: control) }, set: { destination in
            updateProfile {
                if destination == control { $0.mappings.removeValue(forKey: control) }
                else { $0.mappings[control] = destination }
            }
        })
    }

    private func updateProfile(_ update: (inout GamepadProfile) -> Void) {
        guard loaded, let index = configuration.profiles.firstIndex(where: { $0.id == configuration.activeProfileID }) else { return }
        update(&configuration.profiles[index])
    }

    private func loadConfiguration() {
        perform {
            let saved = try store.load()
            configuration = saved
            savedConfiguration = saved
            loaded = true
        }
    }

    private func saveConfiguration() {
        guard loaded else { return }
        perform {
            try configuration.validate()
            try store.save(configuration)
            savedConfiguration = configuration
            notice = "Saved \(profile.name). The selected profile is now active for games."
        }
    }

    private func duplicateProfile() {
        var copy = profile
        copy.id = UUID()
        copy.name = "\(profile.name) Copy"
        configuration.profiles.append(copy)
        configuration.activeProfileID = copy.id
        notice = "Profile duplicated. Rename it below, then save your changes."
    }

    private func deleteProfile() {
        guard configuration.profiles.count > 1 else { return }
        configuration.profiles.removeAll { $0.id == configuration.activeProfileID }
        if let first = configuration.profiles.first { configuration.activeProfileID = first.id }
    }

    private func importProfile() {
        let panel = NSOpenPanel()
        panel.title = "Import Gamepad Profile"
        panel.message = "Choose a MagicWine gamepad profile JSON file. Import adds a draft profile; save changes to apply it."
        panel.allowedContentTypes = [.json]
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                perform {
                    let imported = try store.importProfile(from: url)
                    configuration.profiles.append(imported)
                    configuration.activeProfileID = imported.id
                    notice = "Imported \(imported.name). Review the profile and save changes to apply it."
                }
            }
        }
    }

    private func exportProfile() {
        let exported = profile
        let panel = NSSavePanel()
        panel.title = "Export Gamepad Profile"
        panel.message = "Export the selected draft profile, including any unsaved edits."
        panel.allowedContentTypes = [.json]
        let filename = exported.name.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        panel.nameFieldStringValue = "\(filename)-profile.json"
        panel.canCreateDirectories = true
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            Task { @MainActor in
                perform {
                    try store.exportProfile(exported, to: url)
                    notice = "Exported \(exported.name) to \(url.lastPathComponent)."
                }
            }
        }
    }

    private func captureCalibration() {
        guard let id = calibrationTarget, service.devices.contains(where: { $0.id == id }) else {
            errorMessage = "The controller disconnected before calibration. Reconnect it and try again."
            calibrationTarget = nil
            return
        }
        let zones = service.calibratedDeadZones(for: id)
        updateProfile {
            $0.leftDeadZone = zones.left
            $0.rightDeadZone = zones.right
        }
        calibrationTarget = nil
        notice = "Captured resting stick positions. Test the draft, then save changes to apply calibration."
    }

    private func reconcileDevices() {
        if let selectedDeviceID, !service.devices.contains(where: { $0.id == selectedDeviceID }) {
            notice = "The selected controller disconnected. Its live input has been cleared."
            self.selectedDeviceID = nil
        }
        if selectedDeviceID == nil { selectedDeviceID = service.devices.first?.id }
    }

    private func perform(_ action: () throws -> Void) {
        notice = nil
        do {
            try action()
            errorMessage = nil
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
