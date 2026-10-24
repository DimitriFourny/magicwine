import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case standard
    case dxvk
    case dxmt
    case d3dmetal

    public var displayName: String {
        switch self {
        case .standard: "Standard"
        case .dxvk: "DXVK"
        case .dxmt: "DXMT"
        case .d3dmetal: "D3DMetal"
        }
    }
}

public struct GraphicsConfiguration: Codable, Hashable, Sendable {
    public var backend: GraphicsBackend
    public var componentID: String?
    public var showHUD: Bool

    public init(backend: GraphicsBackend = .standard, componentID: String? = nil, showHUD: Bool = false) {
        self.backend = backend
        self.componentID = componentID
        self.showHUD = showHUD
    }

    /// Whether this build can launch the selected component (current or a retained older
    /// one); launch still verifies its files.
    public var usesSupportedComponent: Bool { GraphicsComponentProviders.bundled.supports(self) }

    /// The component is supported but older than the bundled current one, so
    /// `WineRuntime.updateGraphicsComponent(in:acceptExperimental:)` can switch to it in place.
    public var hasComponentUpdate: Bool { GraphicsComponentProviders.bundled.hasUpdate(self) }
}

/// A saved program's own graphics backend (`WindowsProgram.graphics`; `nil` follows the
/// bottle). It changes only that program's launches and never the prefix: Standard forces
/// Wine's builtin Direct3D DLLs over the bottle backend's prefix files, and D3DMetal runs
/// through its private runtime view. DXVK and DXMT add DLLs to the prefix, so a program can
/// only use them when its bottle selects them. See docs/graphics.md#per-program-graphics.
public struct ProgramGraphics: Codable, Hashable, Sendable {
    public var backend: GraphicsBackend
    /// The D3DMetal import this program uses while its bottle selects another backend;
    /// `nil` for the other backends. With the bottle's own backend, the bottle's selection
    /// (component and prefix files) is used instead.
    public var componentID: String?

    public init(backend: GraphicsBackend, componentID: String? = nil) {
        self.backend = backend
        self.componentID = componentID
    }

    public static let standard = ProgramGraphics(backend: .standard)

    /// Whether a launch of `bottle` with this choice uses the bottle's own selection.
    public func followsBottle(_ bottle: GraphicsConfiguration) -> Bool { backend == bottle.backend }
}

/// One entry of a program's graphics picker (`WineRuntime.programGraphicsChoices`).
public struct ProgramGraphicsChoice: Identifiable, Hashable, Sendable {
    /// `nil` is "Bottle default".
    public let backend: GraphicsBackend?
    /// The value saved for this choice; `nil` for Bottle default and unavailable choices.
    public let graphics: ProgramGraphics?
    /// What the choice does in this bottle.
    public let detail: String
    /// Why it cannot be chosen right now; `nil` when it can.
    public let problem: String?

    public var id: String { backend?.rawValue ?? "default" }
    public var isAvailable: Bool { problem == nil }
}

/// The graphics one launch of a saved program uses.
internal struct LaunchGraphics: Equatable, Sendable {
    /// The backend selection; the bottle's own unless the program chose another backend.
    var configuration: GraphicsConfiguration
    /// `configuration` is the bottle's selection, so its prefix files are validated and used.
    var isBottleSelection: Bool
    /// The bottle backend's prefix DLLs, forced to builtin because the program uses
    /// another backend (empty otherwise).
    var builtinDLLs: [String]

    static func bottle(_ configuration: GraphicsConfiguration) -> LaunchGraphics {
        LaunchGraphics(configuration: configuration, isBottleSelection: true, builtinDLLs: [])
    }
}

extension WindowsProgram {
    /// This program's graphics in a bottle with `bottle` selected, without touching any file.
    /// Throws `programGraphicsUnavailable` when its choice cannot be applied per launch.
    internal func launchGraphics(in bottle: GraphicsConfiguration,
                                 providers: GraphicsComponentProviders = .bundled) throws -> LaunchGraphics {
        guard let graphics, !graphics.followsBottle(bottle) else { return .bottle(bottle) }
        // Every module name of the bottle backend's prefix footprint, in mapping order.
        var builtin: [String] = []
        for mapping in providers[bottle.backend]?.prefixMappings ?? [] {
            let name = URL(fileURLWithPath: mapping.destination).deletingPathExtension().lastPathComponent
            if !builtin.contains(name) { builtin.append(name) }
        }
        guard graphics.backend != .standard else {
            return LaunchGraphics(configuration: GraphicsConfiguration(), isBottleSelection: false, builtinDLLs: builtin)
        }
        guard let provider = providers[graphics.backend], provider.launchesWithoutPrefixFiles else {
            throw MagicWineError.programGraphicsUnavailable(
                "\(graphics.backend.displayName) works only from DLLs installed in the bottle, and this bottle uses \(bottle.backend.displayName), so \(name) cannot use it on its own. Switch the bottle to \(graphics.backend.displayName) or choose another backend for this program.",
                programID: id)
        }
        guard let componentID = graphics.componentID, provider.supports(componentID: componentID) else {
            throw MagicWineError.programGraphicsUnavailable(
                "\(name) uses \(graphics.backend.displayName) with a component this version of MagicWine does not support. Choose its graphics again.",
                programID: id)
        }
        return LaunchGraphics(configuration: GraphicsConfiguration(backend: graphics.backend, componentID: componentID,
                                                                   showHUD: bottle.showHUD),
                              isBottleSelection: false, builtinDLLs: builtin)
    }
}

extension Bottle {
    /// Every graphics selection a launch of this bottle can use right now: the bottle's
    /// own and its programs' other backends (storage cleanup keeps their components/views).
    internal var graphicsInUse: [GraphicsConfiguration] {
        var selections = [graphics]
        for program in programs {
            guard let selection = try? program.launchGraphics(in: graphics).configuration,
                  !selections.contains(where: { $0.backend == selection.backend && $0.componentID == selection.componentID })
            else { continue }
            selections.append(selection)
        }
        return selections
    }
}

public enum GraphicsSetupProgress: Sendable {
    case stopping
    case verifying
    case installing
    case restoring
}
