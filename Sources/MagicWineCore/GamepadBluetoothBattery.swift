import Foundation

/// Some BLE gamepads expose battery charge to Bluetooth but not GameController.
/// Use macOS's report rather than private Bluetooth APIs; call off the input/UI queue.
enum GamepadBluetoothBattery {
    struct Reading: Equatable, Sendable {
        var batteryLevel: Double?
    }

    struct RefreshSchedule {
        private(set) var nextUpdate = 0.0
        private var discoveryDeadline = 0.0

        mutating func reset(at now: TimeInterval) {
            nextUpdate = now
            discoveryDeadline = now + 10
        }

        mutating func complete(at now: TimeInterval, missingBattery: Bool) {
            // Bluetooth battery discovery can lag the GameController connection.
            // Retry briefly, without polling unsupported controllers indefinitely.
            nextUpdate = now + (missingBattery && now < discoveryDeadline ? 1 : 30)
        }
    }

    static func read() -> [String: Reading] {
        let process = Process()
        let output = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        process.arguments = ["SPBluetoothDataType", "-json", "-timeout", "5"]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [:] }
            return readings(from: data)
        } catch {
            return [:]
        }
    }

    static func readings(from data: Data) -> [String: Reading] {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let adapters = report["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var readings: [String: Reading] = [:]
        var seen = Set<String>()
        for adapter in adapters {
            guard let connected = adapter["device_connected"] as? [[String: [String: Any]]] else { continue }
            for devices in connected {
                for (name, device) in devices {
                    // GCController provides a name, not a public Bluetooth address.
                    // Duplicate names cannot safely identify an individual battery.
                    guard seen.insert(name).inserted else {
                        readings.removeValue(forKey: name)
                        continue
                    }
                    guard device["device_minorType"] as? String == "Gamepad" else { continue }
                    var reading = Reading()
                    if let text = device["device_batteryLevelMain"] as? String,
                       text.hasSuffix("%"), let percent = Double(text.dropLast()),
                       percent.isFinite, (0...100).contains(percent) {
                        reading.batteryLevel = percent / 100
                    }
                    readings[name] = reading
                }
            }
        }
        return readings
    }
}
