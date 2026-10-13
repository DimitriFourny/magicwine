import Foundation

public enum GamepadControl: String, CaseIterable, Codable, Identifiable, Sendable {
    case a, b, x, y, leftShoulder, rightShoulder, leftTrigger, rightTrigger
    case back, start, guide, leftThumb, rightThumb, dpadUp, dpadDown, dpadLeft, dpadRight, none

    public var id: String { rawValue }
    public static let inputs = allCases.filter { $0 != .none }
    public var displayName: String {
        switch self {
        case .a: "A"
        case .b: "B"
        case .x: "X"
        case .y: "Y"
        case .leftShoulder: "LB"
        case .rightShoulder: "RB"
        case .leftTrigger: "LT"
        case .rightTrigger: "RT"
        case .back: "Select"
        case .start: "Start"
        case .guide: "Home"
        case .leftThumb: "Left Stick Click"
        case .rightThumb: "Right Stick Click"
        case .dpadUp: "D-Pad Up"
        case .dpadDown: "D-Pad Down"
        case .dpadLeft: "D-Pad Left"
        case .dpadRight: "D-Pad Right"
        case .none: "Unassigned"
        }
    }
}

public enum GamepadResponseCurve: String, CaseIterable, Codable, Identifiable, Sendable {
    case linear, precision, quick
    public var id: String { rawValue }
    public var displayName: String { rawValue.capitalized }

    fileprivate func apply(_ value: Double) -> Double {
        switch self {
        case .linear: value
        case .precision: value * value
        case .quick: sqrt(value)
        }
    }
}

public struct GamepadInput: Equatable, Sendable {
    public var leftX = 0.0
    public var leftY = 0.0
    public var rightX = 0.0
    public var rightY = 0.0
    public var leftTrigger = 0.0
    public var rightTrigger = 0.0
    public var pressed: Set<GamepadControl> = []

    public init() {}

    public func value(for control: GamepadControl) -> Double {
        switch control {
        case .none: 0
        case .leftTrigger: Self.clamp(leftTrigger, to: 0...1)
        case .rightTrigger: Self.clamp(rightTrigger, to: 0...1)
        default: pressed.contains(control) ? 1 : 0
        }
    }

    static func clamp(_ value: Double, to range: ClosedRange<Double>) -> Double {
        value.isFinite ? min(range.upperBound, max(range.lowerBound, value)) : 0
    }
}

public struct GamepadDevice: Identifiable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    /// Zero-based XInput slot, or nil when all four slots are occupied.
    public var playerIndex: Int?
    public var batteryLevel: Double?
    public var batteryCharging: Bool
    public var supportsHaptics: Bool
    /// True only when matched to a connected device in macOS's Bluetooth report.
    public var isBluetooth: Bool

    public init(id: UUID, name: String, playerIndex: Int?, batteryLevel: Double? = nil,
                batteryCharging: Bool = false, supportsHaptics: Bool = false, isBluetooth: Bool = false) {
        self.id = id
        self.name = name
        self.playerIndex = playerIndex
        self.batteryLevel = batteryLevel
        self.batteryCharging = batteryCharging
        self.supportsHaptics = supportsHaptics
        self.isBluetooth = isBluetooth
    }
}

public enum GamepadError: LocalizedError {
    case invalidConfiguration(String)
    case unavailableController
    case unsupportedHaptics

    public var errorDescription: String? {
        switch self {
        case .invalidConfiguration(let reason): "Invalid gamepad configuration: \(reason)"
        case .unavailableController: "This controller is no longer connected."
        case .unsupportedHaptics: "This controller does not provide supported haptic feedback."
        }
    }
}

extension GamepadProfile {
    public func applying(to input: GamepadInput) -> GamepadInput {
        var output = GamepadInput()
        (output.leftX, output.leftY) = stick(input.leftX, input.leftY, deadZone: leftDeadZone)
        (output.rightX, output.rightY) = stick(input.rightX, input.rightY, deadZone: rightDeadZone)
        let sensitivity = GamepadInput.clamp(triggerSensitivity, to: 0.5...2)
        for source in GamepadControl.inputs {
            let destination = mappedControl(for: source)
            guard destination != .none else { continue }
            var value = input.value(for: source)
            if source == .leftTrigger || source == .rightTrigger {
                value = min(1, value * sensitivity)
            }
            switch destination {
            case .leftTrigger: output.leftTrigger = max(output.leftTrigger, value)
            case .rightTrigger: output.rightTrigger = max(output.rightTrigger, value)
            default:
                if value > 0.5 { output.pressed.insert(destination) }
            }
        }
        if output.leftTrigger > 0.5 { output.pressed.insert(.leftTrigger) }
        if output.rightTrigger > 0.5 { output.pressed.insert(.rightTrigger) }
        return output
    }

    private func stick(_ rawX: Double, _ rawY: Double, deadZone: Double) -> (Double, Double) {
        let x = GamepadInput.clamp(rawX, to: -1...1)
        let y = GamepadInput.clamp(rawY, to: -1...1)
        let magnitude = hypot(x, y)
        let deadZone = GamepadInput.clamp(deadZone, to: 0...0.4)
        guard magnitude > deadZone else { return (0, 0) }
        let normalized = (min(1, magnitude) - deadZone) / (1 - deadZone)
        let scale = responseCurve.apply(normalized) / magnitude
        return (x * scale, y * scale)
    }
}
