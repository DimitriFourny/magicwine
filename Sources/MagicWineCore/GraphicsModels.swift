import Foundation

public enum GraphicsBackend: String, Codable, CaseIterable, Sendable {
    case standard
    case dxvk
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

    /// Whether this selection uses the component shipped by this MagicWine build.
    public var usesCurrentDXVK: Bool {
        backend == .dxvk && componentID == DXVKInstallation.componentID
    }
}

public enum GraphicsSetupProgress: Sendable {
    case stopping
    case verifying
    case installing
    case restoring
}
