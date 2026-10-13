import Foundation

/// Some BLE gamepads expose battery charge to Bluetooth but not GameController.
/// Use macOS's report rather than private Bluetooth APIs; call off the input/UI queue.
enum GamepadBluetoothBattery {
    static func read() -> [String: Double] {
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
            return levels(from: data)
        } catch {
            return [:]
        }
    }

    static func levels(from data: Data) -> [String: Double] {
        guard let report = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let adapters = report["SPBluetoothDataType"] as? [[String: Any]] else { return [:] }
        var levels: [String: Double] = [:]
        var seen = Set<String>()
        for adapter in adapters {
            guard let connected = adapter["device_connected"] as? [[String: [String: Any]]] else { continue }
            for devices in connected {
                for (name, device) in devices {
                    // GCController provides a name, not a public Bluetooth address.
                    // Duplicate names cannot safely identify an individual battery.
                    guard seen.insert(name).inserted else {
                        levels.removeValue(forKey: name)
                        continue
                    }
                    guard device["device_minorType"] as? String == "Gamepad",
                          let text = device["device_batteryLevelMain"] as? String,
                          text.hasSuffix("%"), let percent = Double(text.dropLast()),
                          percent.isFinite, (0...100).contains(percent) else { continue }
                    levels[name] = percent / 100
                }
            }
        }
        return levels
    }
}
