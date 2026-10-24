import CoreHaptics
import Foundation
@preconcurrency import GameController
import Observation

/// Only `devices`, `inputs`, and `error` are observable: views that read `inputs` re-render
/// at up to 60 Hz, views that only read `devices` change on connection and metadata updates.
@Observable
@MainActor
public final class GamepadService {
    public static let shared = GamepadService()
    public private(set) var devices: [GamepadDevice] = []
    public private(set) var inputs: [UUID: GamepadInput] = [:]
    public private(set) var error: String?

    @MainActor
    private final class Controller {
        let id = UUID()
        let device: GCController
        var slot: Int?
        var input = GamepadInput()
        var haptics: GamepadHapticOutput?
        init(_ device: GCController) { self.device = device }
    }

    private struct Vibration {
        var left = 0.0
        var right = 0.0
        var deadline = 0.0
    }

    @MainActor
    private final class Session {
        let bridge: GamepadBridgeSession
        let store: GamepadProfileStore
        var profile: GamepadProfile
        var modificationDate: Date?
        var fileSize: Int?
        var reloadPending = false
        var reloadAgain = false
        var failure: String?
        var processed: [GamepadInput?] = Array(repeating: nil, count: 4)
        var vibrations = Array(repeating: Vibration(), count: 4)

        init(bridge: GamepadBridgeSession, store: GamepadProfileStore, profile: GamepadProfile) {
            self.bridge = bridge
            self.store = store
            self.profile = profile
        }
    }

    @ObservationIgnored private var controllers: [Controller] = []
    @ObservationIgnored private var sessions: [URL: Session] = [:]
    @ObservationIgnored private var observers: [NSObjectProtocol] = []
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var activity: NSObjectProtocol?
    @ObservationIgnored private var slotDevices: [GamepadDevice?] = Array(repeating: nil, count: 4)
    @ObservationIgnored private var nextMetadataUpdate = 0.0
    @ObservationIgnored private var bluetoothReadings: [UUID: GamepadBluetoothBattery.Reading] = [:]
    @ObservationIgnored private var bluetoothBatterySchedule = GamepadBluetoothBattery.RefreshSchedule()
    @ObservationIgnored private var bluetoothBatteryUpdatePending = false
    @ObservationIgnored private var nextUIPublish = 0.0
    @ObservationIgnored private var inputsChanged = false

    private init() {}

    /// The singleton intentionally retains its observers and mapped sessions for the
    /// lifetime of the hosting process, including when its UI is not frontmost. The input
    /// timer runs only while a controller is connected; see `updateTimer`.
    public func start() {
        guard observers.isEmpty else { return }
        GCController.shouldMonitorBackgroundEvents = true
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.synchronizeControllers() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: GamepadProfileStore.didSave, object: nil, queue: .main) { [weak self] notification in
            guard let url = notification.object as? URL else { return }
            MainActor.assumeIsolated {
                guard let self else { return }
                for session in self.sessions.values where session.store.configurationURL == url {
                    self.reload(session, force: true)
                }
            }
        })
        synchronizeControllers()
        GCController.startWirelessControllerDiscovery(completionHandler: nil)
    }

    /// Polls at 8 ms while a controller is connected. Without one there is no input to read,
    /// rumble to apply, or battery to refresh: every session has just been published with all
    /// slots disconnected, and Windows readers treat the then-expiring heartbeat the same way.
    /// A connection resumes polling; its first tick picks up profiles saved meanwhile.
    private func updateTimer() {
        if controllers.isEmpty {
            timer?.cancel()
            timer = nil
            return
        }
        guard timer == nil else { return }
        nextMetadataUpdate = 0
        nextUIPublish = 0
        let source = DispatchSource.makeTimerSource(queue: .main)
        source.schedule(deadline: .now(), repeating: .milliseconds(8), leeway: .milliseconds(1))
        source.setEventHandler { [weak self] in
            MainActor.assumeIsolated { self?.tick() }
        }
        timer = source
        source.resume()
    }

    public func prepare(paths: ApplicationPaths) throws -> [String: String] {
        start()
        let key = paths.root.standardizedFileURL
        let store = GamepadProfileStore(paths: paths)
        do {
            let profile = try store.load().activeProfile
            let session: Session
            if let existing = sessions[key] {
                session = existing
                session.profile = profile
                session.failure = nil
                if session.reloadPending { session.reloadAgain = true }
            } else {
                session = Session(bridge: try GamepadBridgeSession(paths: paths), store: store, profile: profile)
                sessions[key] = session
            }
            if activity == nil {
                activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                                reason: "Forwarding game controller input to Windows games")
            }
            updateProcessed(session)
            session.bridge.publish(inputs: session.processed, devices: slotDevices)
            return ["MAGICWINE_GAMEPAD_STATE": session.bridge.windowsPath]
        } catch {
            report(error.localizedDescription)
            throw error
        }
    }

    public func identify(_ id: UUID, strength: Double) throws {
        guard let controller = controllers.first(where: { $0.id == id }) else {
            throw GamepadError.unavailableController
        }
        guard strength.isFinite, (0...1).contains(strength) else {
            throw GamepadError.invalidConfiguration("Vibration strength must be between 0 and 1.")
        }
        try hapticOutput(for: controller).identify(strength: strength)
    }

    public func calibratedDeadZones(for id: UUID) -> (left: Double, right: Double) {
        guard let input = controllers.first(where: { $0.id == id })?.input else { return (0.08, 0.08) }
        return (min(0.4, hypot(input.leftX, input.leftY) + 0.02),
                min(0.4, hypot(input.rightX, input.rightY) + 0.02))
    }

    private func synchronizeControllers() {
        let connected = GCController.controllers().filter { !$0.isSnapshot && $0.extendedGamepad != nil }
        let live = Set(connected.map(ObjectIdentifier.init))
        for controller in controllers where !live.contains(ObjectIdentifier(controller.device)) {
            controller.haptics?.stop()
            if let slot = controller.slot {
                for session in sessions.values { session.vibrations[slot] = Vibration() }
            }
        }
        controllers.removeAll { !live.contains(ObjectIdentifier($0.device)) }
        for device in connected where !controllers.contains(where: { $0.device === device }) {
            device.handlerQueue = .main
            controllers.append(Controller(device))
        }
        var occupied = Set(controllers.compactMap(\.slot))
        for controller in controllers where controller.slot == nil {
            guard let slot = (0..<4).first(where: { !occupied.contains($0) }) else { break }
            controller.slot = slot
            controller.device.playerIndex = GCControllerPlayerIndex(rawValue: slot) ?? .indexUnset
            occupied.insert(slot)
        }
        bluetoothReadings.removeAll()
        bluetoothBatterySchedule.reset(at: ProcessInfo.processInfo.systemUptime)
        refreshMetadata()
        inputsChanged = true
        for session in sessions.values {
            updateProcessed(session)
            session.bridge.publish(inputs: session.processed, devices: slotDevices)
        }
        publishInputs()
        updateTimer()
    }

    private func refreshMetadata() {
        let updated = controllers.map { controller in
            let battery = controller.device.battery
            let level = battery.flatMap { $0.batteryState == .unknown ? nil : Double($0.batteryLevel) }
            return GamepadDevice(id: controller.id,
                                 name: controller.device.vendorName ?? controller.device.productCategory,
                                 playerIndex: controller.slot,
                                 batteryLevel: level.flatMap { $0.isFinite && (0...1).contains($0) ? $0 : nil }
                                     ?? bluetoothReadings[controller.id]?.batteryLevel,
                                 batteryCharging: battery?.batteryState == .charging,
                                 supportsHaptics: controller.device.haptics != nil,
                                 isBluetooth: bluetoothReadings[controller.id] != nil)
        }
        if devices != updated { devices = updated }
        for slot in 0..<4 { slotDevices[slot] = updated.first(where: { $0.playerIndex == slot }) }
        refreshBluetoothBattery()
    }

    private func refreshBluetoothBattery() {
        let now = ProcessInfo.processInfo.systemUptime
        guard !bluetoothBatteryUpdatePending, now >= bluetoothBatterySchedule.nextUpdate,
              !controllers.isEmpty else { return }
        bluetoothBatteryUpdatePending = true
        let identities = controllers.map { (id: $0.id, name: $0.device.vendorName) }
        Task { [weak self] in
            let levels = await Task.detached(priority: .utility) { GamepadBluetoothBattery.read() }.value
            guard let self else { return }
            let sameConnection = self.controllers.map(\.id) == identities.map(\.id)
            // Discard results collected for a previous connection/assignment.
            if sameConnection {
                var matched: [UUID: GamepadBluetoothBattery.Reading] = [:]
                for identity in identities {
                    guard let name = identity.name,
                          !identities.contains(where: { $0.id != identity.id && $0.name == name }) else { continue }
                    matched[identity.id] = levels[name]
                }
                self.bluetoothReadings = matched
            }
            self.refreshMetadata()
            if sameConnection {
                self.bluetoothBatterySchedule.complete(
                    at: ProcessInfo.processInfo.systemUptime,
                    missingBattery: self.devices.contains(where: { $0.batteryLevel == nil }))
            }
            self.bluetoothBatteryUpdatePending = false
            self.refreshBluetoothBattery()
        }
    }

    private func tick() {
        let now = ProcessInfo.processInfo.systemUptime
        var changed = false
        for controller in controllers {
            guard let gamepad = controller.device.extendedGamepad else { continue }
            let input = Self.read(gamepad, previous: controller.input)
            if controller.input != input {
                controller.input = input
                changed = true
            }
        }
        if changed {
            inputsChanged = true
            for session in sessions.values { updateProcessed(session) }
        }
        if now >= nextUIPublish {
            if inputsChanged { publishInputs() }
            nextUIPublish = now + 1.0 / 60
        }
        if now >= nextMetadataUpdate {
            refreshMetadata()
            for session in sessions.values { reload(session, force: false) }
            nextMetadataUpdate = now + 1
        }
        var vibrationChanged = false
        for session in sessions.values {
            session.bridge.publish(inputs: session.processed, devices: slotDevices)
            for slot in 0..<4 {
                if let vibration = session.bridge.takeVibration(slot: slot) {
                    session.vibrations[slot] = Vibration(left: vibration.left, right: vibration.right, deadline: now + 2)
                    vibrationChanged = true
                } else if session.vibrations[slot].deadline > 0, now >= session.vibrations[slot].deadline {
                    session.vibrations[slot] = Vibration()
                    vibrationChanged = true
                }
            }
        }
        if vibrationChanged { applyVibration() }
    }

    private func publishInputs() {
        let updated = Dictionary(uniqueKeysWithValues: controllers.map { ($0.id, $0.input) })
        if inputs != updated { inputs = updated }
        inputsChanged = false
    }

    private func updateProcessed(_ session: Session) {
        for slot in 0..<4 {
            session.processed[slot] = controllers.first(where: { $0.slot == slot }).map { session.profile.applying(to: $0.input) }
        }
    }

    private func reload(_ session: Session, force: Bool) {
        guard !session.reloadPending else {
            session.reloadAgain = session.reloadAgain || force
            return
        }
        session.reloadPending = true
        let store = session.store
        let previousDate = session.modificationDate
        let previousSize = session.fileSize
        Task { [weak self, weak session] in
            let result = await Task.detached(priority: .utility) { () -> Result<(GamepadConfiguration, Date?, Int?)?, any Error> in
                do {
                    let attributes: URLResourceValues?
                    do {
                        attributes = try store.configurationURL.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
                    } catch let error as CocoaError where error.code == .fileNoSuchFile || error.code == .fileReadNoSuchFile {
                        attributes = nil
                    }
                    let date = attributes?.contentModificationDate
                    let size = attributes?.fileSize
                    guard force || date != previousDate || size != previousSize else { return .success(nil) }
                    return .success((try store.load(), date, size))
                } catch { return .failure(error) }
            }.value
            guard let self, let session else { return }
            session.reloadPending = false
            if session.reloadAgain {
                session.reloadAgain = false
                self.reload(session, force: true)
                return
            }
            switch result {
            case .success(let update):
                if let (configuration, date, size) = update {
                    session.profile = configuration.activeProfile
                    session.modificationDate = date
                    session.fileSize = size
                    let oldFailure = session.failure
                    session.failure = nil
                    if self.error == oldFailure { self.error = self.sessions.values.compactMap(\.failure).first }
                    self.updateProcessed(session)
                    self.applyVibration()
                }
            case .failure(let failure):
                session.failure = "Gamepad profiles could not be reloaded; the last saved valid profile remains in use. \(failure.localizedDescription)"
                self.report(session.failure!)
            }
        }
    }

    private func hapticOutput(for controller: Controller) throws -> GamepadHapticOutput {
        if let output = controller.haptics { return output }
        guard let haptics = controller.device.haptics else { throw GamepadError.unsupportedHaptics }
        let output = try GamepadHapticOutput(haptics: haptics) { [weak self] message in
            Task { @MainActor [weak self] in self?.report(message) }
        }
        controller.haptics = output
        return output
    }

    private func applyVibration() {
        for controller in controllers {
            guard let slot = controller.slot else { continue }
            var left = 0.0
            var right = 0.0
            for session in sessions.values {
                let strength = session.profile.vibrationStrength
                left = max(left, session.vibrations[slot].left * strength)
                right = max(right, session.vibrations[slot].right * strength)
            }
            guard left > 0 || right > 0 || controller.haptics != nil else { continue }
            guard controller.device.haptics != nil else { continue }
            do { try hapticOutput(for: controller).setRumble(left: left, right: right) }
            catch { report(error.localizedDescription) }
        }
    }

    private func report(_ message: String) {
        if error != message { error = message }
    }

    private static func read(_ gamepad: GCExtendedGamepad, previous: GamepadInput) -> GamepadInput {
        var input = previous
        input.leftX = Double(gamepad.leftThumbstick.xAxis.value)
        input.leftY = Double(gamepad.leftThumbstick.yAxis.value)
        input.rightX = Double(gamepad.rightThumbstick.xAxis.value)
        input.rightY = Double(gamepad.rightThumbstick.yAxis.value)
        input.leftTrigger = Double(gamepad.leftTrigger.value)
        input.rightTrigger = Double(gamepad.rightTrigger.value)
        input.setPressed(.a, gamepad.buttonA.isPressed)
        input.setPressed(.b, gamepad.buttonB.isPressed)
        input.setPressed(.x, gamepad.buttonX.isPressed)
        input.setPressed(.y, gamepad.buttonY.isPressed)
        input.setPressed(.leftShoulder, gamepad.leftShoulder.isPressed)
        input.setPressed(.rightShoulder, gamepad.rightShoulder.isPressed)
        input.setPressed(.leftTrigger, gamepad.leftTrigger.isPressed)
        input.setPressed(.rightTrigger, gamepad.rightTrigger.isPressed)
        input.setPressed(.start, gamepad.buttonMenu.isPressed)
        input.setPressed(.back, gamepad.buttonOptions?.isPressed == true)
        input.setPressed(.guide, gamepad.buttonHome?.isPressed == true)
        input.setPressed(.leftThumb, gamepad.leftThumbstickButton?.isPressed == true)
        input.setPressed(.rightThumb, gamepad.rightThumbstickButton?.isPressed == true)
        input.setPressed(.dpadUp, gamepad.dpad.up.isPressed)
        input.setPressed(.dpadDown, gamepad.dpad.down.isPressed)
        input.setPressed(.dpadLeft, gamepad.dpad.left.isPressed)
        input.setPressed(.dpadRight, gamepad.dpad.right.isPressed)
        return input
    }
}

private extension GamepadInput {
    mutating func setPressed(_ control: GamepadControl, _ isPressed: Bool) {
        guard pressed.contains(control) != isPressed else { return }
        if isPressed { pressed.insert(control) }
        else { pressed.remove(control) }
    }
}

/// All engine/player state is confined to queue. Only immutable engine references
/// cross from controller discovery on the main actor to this worker.
private final class GamepadHapticOutput: @unchecked Sendable {
    private let queue = DispatchQueue(label: "MagicWine.gamepad-haptics", qos: .userInteractive)
    private let engines: [CHHapticEngine]
    private let report: @Sendable (String) -> Void
    private var players: [(any CHHapticAdvancedPatternPlayer)?]
    private var intensities: [Float]
    private var left = 0.0
    private var right = 0.0
    private var identifyStrength = 0.0
    private var rumbleGeneration: UInt64 = 0
    private var identifyGeneration: UInt64 = 0
    private var stopped = false

    @MainActor
    init(haptics: GCDeviceHaptics, report: @escaping @Sendable (String) -> Void) throws {
        if haptics.supportedLocalities.contains(.leftHandle), haptics.supportedLocalities.contains(.rightHandle),
           let left = haptics.createEngine(withLocality: .leftHandle),
           let right = haptics.createEngine(withLocality: .rightHandle) {
            engines = [left, right]
        } else if let engine = haptics.createEngine(withLocality: .default) {
            engines = [engine]
        } else { throw GamepadError.unsupportedHaptics }
        self.report = report
        players = Array(repeating: nil, count: engines.count)
        intensities = Array(repeating: 0, count: engines.count)
        for (index, engine) in engines.enumerated() {
            engine.resetHandler = { [weak self] in self?.invalidate(index) }
            engine.stoppedHandler = { [weak self] _ in self?.invalidate(index) }
        }
    }

    func setRumble(left: Double, right: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            self.left = GamepadInput.clamp(left, to: 0...1)
            self.right = GamepadInput.clamp(right, to: 0...1)
            rumbleGeneration &+= 1
            let generation = rumbleGeneration
            update()
            // A queue-side watchdog also stops motors if the main actor stalls.
            queue.asyncAfter(deadline: .now() + 2) { [weak self] in
                guard let self, self.rumbleGeneration == generation else { return }
                self.left = 0
                self.right = 0
                self.update()
            }
        }
    }

    func identify(strength: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            identifyStrength = strength
            identifyGeneration &+= 1
            let generation = identifyGeneration
            update()
            queue.asyncAfter(deadline: .now() + 0.35) { [weak self] in
                guard let self, self.identifyGeneration == generation else { return }
                self.identifyStrength = 0
                self.update()
            }
        }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            left = 0
            right = 0
            identifyStrength = 0
            update()
            for engine in engines { engine.stop(completionHandler: nil) }
        }
    }

    private func invalidate(_ index: Int) {
        queue.async { [weak self] in
            guard let self else { return }
            self.players[index] = nil
            self.intensities[index] = 0
            if !self.stopped { self.update() }
        }
    }

    private func update() {
        do {
            for index in engines.indices {
                let motor = engines.count == 1 ? max(left, right) : (index == 0 ? left : right)
                let intensity = Float(max(motor, identifyStrength))
                if intensity == 0 {
                    if let player = players[index] { try player.stop(atTime: CHHapticTimeImmediate) }
                    players[index] = nil
                    intensities[index] = 0
                    continue
                }
                if players[index] == nil {
                    let engine = engines[index]
                    try engine.start()
                    let event = CHHapticEvent(eventType: .hapticContinuous, parameters: [
                        CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
                        CHHapticEventParameter(parameterID: .hapticSharpness, value: index == 0 ? 0.2 : 0.8)
                    ], relativeTime: 0, duration: 1)
                    let pattern = try CHHapticPattern(events: [event], parameters: [])
                    let player = try engine.makeAdvancedPlayer(with: pattern)
                    player.loopEnabled = true
                    try player.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                          value: intensity, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                    try player.start(atTime: CHHapticTimeImmediate)
                    players[index] = player
                } else if intensities[index] != intensity {
                    try players[index]?.sendParameters([CHHapticDynamicParameter(parameterID: .hapticIntensityControl,
                                                                                 value: intensity, relativeTime: 0)], atTime: CHHapticTimeImmediate)
                }
                intensities[index] = intensity
            }
        } catch {
            for index in players.indices {
                try? players[index]?.stop(atTime: CHHapticTimeImmediate)
                players[index] = nil
                intensities[index] = 0
            }
            report("Controller haptics failed: \(error.localizedDescription)")
        }
    }
}
