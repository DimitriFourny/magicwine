import Foundation
import Testing
@testable import MagicWineCore

struct GamepadTests {
    @Test func bluetoothBatteryRetriesDiscoveryUntilChargeArrives() {
        var schedule = GamepadBluetoothBattery.RefreshSchedule()
        schedule.reset(at: 100)
        #expect(schedule.nextUpdate == 100)
        schedule.complete(at: 100.2, missingBattery: true)
        #expect(schedule.nextUpdate == 101.2)
        schedule.complete(at: 101.4, missingBattery: true)
        #expect(schedule.nextUpdate == 102.4)
        schedule.complete(at: 102.6, missingBattery: false)
        #expect(schedule.nextUpdate == 132.6)
    }

    @Test func bluetoothBatteryDiscoveryIsBoundedAndRestartsOnConnection() {
        var schedule = GamepadBluetoothBattery.RefreshSchedule()
        schedule.reset(at: 100)
        schedule.complete(at: 109, missingBattery: true)
        #expect(schedule.nextUpdate == 110)
        schedule.complete(at: 110, missingBattery: true)
        #expect(schedule.nextUpdate == 140)
        schedule.complete(at: 140, missingBattery: true)
        #expect(schedule.nextUpdate == 170)
        schedule.reset(at: 141)
        #expect(schedule.nextUpdate == 141)
        schedule.complete(at: 142, missingBattery: true)
        #expect(schedule.nextUpdate == 143)
        schedule.complete(at: 151, missingBattery: true)
        #expect(schedule.nextUpdate == 181)
    }

    @Test func bluetoothBatteryUsesOnlyConnectedUnambiguousGamepads() throws {
        let report: [String: Any] = ["SPBluetoothDataType": [[
            "device_connected": [
                ["8BitDo Ultimate 2 Wireless": ["device_minorType": "Gamepad", "device_batteryLevelMain": "100%"]],
                ["Empty": ["device_minorType": "Gamepad", "device_batteryLevelMain": "0%"]],
                ["Partial": ["device_minorType": "Gamepad", "device_batteryLevelMain": "42%"]],
                ["No battery": ["device_minorType": "Gamepad"]],
                ["Duplicate": ["device_minorType": "Gamepad", "device_batteryLevelMain": "80%"]],
                ["Duplicate": ["device_minorType": "Gamepad"]],
                ["Mouse": ["device_minorType": "Mouse", "device_batteryLevelMain": "90%"]]
            ],
            "device_not_connected": [
                ["Disconnected": ["device_minorType": "Gamepad", "device_batteryLevelMain": "60%"]]
            ]
        ]]]
        let levels = GamepadBluetoothBattery.readings(from: try JSONSerialization.data(withJSONObject: report))
        #expect(levels.compactMapValues(\.batteryLevel) == ["8BitDo Ultimate 2 Wireless": 1, "Empty": 0, "Partial": 0.42])
        #expect(Set(levels.keys) == ["8BitDo Ultimate 2 Wireless", "Empty", "Partial", "No battery"])
        #expect(levels["No battery"]?.batteryLevel == nil)
    }

    @Test func bluetoothBatteryRejectsInvalidReadings() throws {
        let readings = ["-1%", "101%", "nan%", "inf%", "unknown", "50"]
        let connected = readings.map { [$0: ["device_minorType": "Gamepad", "device_batteryLevelMain": $0]] }
        let report = ["SPBluetoothDataType": [["device_connected": connected]]]
        let parsed = GamepadBluetoothBattery.readings(from: try JSONSerialization.data(withJSONObject: report))
        #expect(parsed.compactMapValues(\.batteryLevel).isEmpty)
        #expect(Set(parsed.keys) == Set(readings))
        #expect(GamepadBluetoothBattery.readings(from: Data("not JSON".utf8)).isEmpty)
    }

    @Test func radialDeadZoneSuppressesDriftAndPreservesFullTravel() {
        var profile = GamepadProfile()
        profile.leftDeadZone = 0.1
        profile.rightDeadZone = 0.2
        var input = GamepadInput()
        input.leftX = 0.06
        input.leftY = 0.06
        input.rightX = -1
        input.rightY = 1
        let output = profile.applying(to: input)
        #expect(output.leftX == 0 && output.leftY == 0)
        #expect(abs(hypot(output.rightX, output.rightY) - 1) < 0.0001)
        #expect(output.rightX < 0 && output.rightY > 0)
        input.leftX = 1
        input.leftY = 0
        #expect(profile.applying(to: input).leftX == 1)
    }

    @Test func remappingUsesOriginalInputsAndCombinesDestinations() {
        var profile = GamepadProfile()
        profile.mappings = [.a: .b, .b: .a, .x: .b, .guide: .none]
        var input = GamepadInput()
        input.pressed = [.a, .x, .guide]
        let output = profile.applying(to: input)
        #expect(output.pressed.contains(.b))
        #expect(!output.pressed.contains(.a))
        #expect(!output.pressed.contains(.x))
        #expect(!output.pressed.contains(.guide))
        input.pressed = [.b]
        #expect(profile.applying(to: input).pressed == [.a])
    }

    @Test func triggerRemappingRetainsAnalogValuesAndHonorsDisable() {
        var profile = GamepadProfile()
        profile.mappings = [.leftTrigger: .rightTrigger, .rightTrigger: .none]
        profile.triggerSensitivity = 1.5
        var input = GamepadInput()
        input.leftTrigger = 0.4
        input.rightTrigger = 1
        let output = profile.applying(to: input)
        #expect(output.leftTrigger == 0)
        #expect(abs(output.rightTrigger - 0.6) < 0.0001)
        input.leftTrigger = 1
        #expect(profile.applying(to: input).rightTrigger == 1)
    }

    @Test func profileValidationRejectsNonfiniteAndOutOfRangeCalibration() throws {
        var profile = GamepadProfile()
        profile.leftDeadZone = .nan
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.leftDeadZone = 1
        #expect(throws: (any Error).self) { try profile.validate() }
        profile.leftDeadZone = 0.08
        profile.vibrationStrength = -0.1
        #expect(throws: (any Error).self) { try profile.validate() }
    }

    @Test func profilesPersistSelectionAndRejectDanglingIdentity() throws {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = GamepadProfileStore(paths: paths)
        var config = try store.load()
        config.profiles[1].name = "Driving"
        config.profiles[1].mappings[.a] = .leftShoulder
        config.activeProfileID = config.profiles[1].id
        try store.save(config)
        let reopened = try GamepadProfileStore(paths: paths).load()
        #expect(reopened == config)
        #expect(reopened.activeProfile.name == "Driving")
        #expect(reopened.activeProfile.mappedControl(for: .a) == .leftShoulder)
        config.activeProfileID = UUID()
        #expect(throws: (any Error).self) { try store.save(config) }
        #expect(try store.load() == reopened)
    }

    @Test func importGetsIndependentIdentityAndCorruptionDoesNotResetSavedProfiles() throws {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let store = GamepadProfileStore(paths: paths)
        let config = GamepadConfiguration()
        try store.save(config)
        let exported = paths.root.appendingPathComponent("controller.json")
        try store.exportProfile(config.activeProfile, to: exported)
        let imported = try store.importProfile(from: exported)
        #expect(imported.id != config.activeProfileID)
        #expect(imported.name == config.activeProfile.name)
        #expect(imported.leftDeadZone == config.activeProfile.leftDeadZone)
        let file = paths.root.appendingPathComponent("Gamepads/profiles.json")
        let corrupt = Data("{not JSON".utf8)
        try corrupt.write(to: file)
        #expect(throws: (any Error).self) { try store.load() }
        #expect(try Data(contentsOf: file) == corrupt)
    }
}
