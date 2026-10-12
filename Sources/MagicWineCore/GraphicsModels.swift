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

    /// Whether this build understands the selected component; launch still verifies its files.
    public var usesCurrentComponent: Bool {
        switch backend {
        case .standard: componentID == nil
        case .dxvk: componentID == DXVKInstallation.componentID
        case .dxmt: componentID == DXMTInstallation.componentID
        case .d3dmetal: componentID.map(D3DMetalInstallation.supports(componentID:)) ?? false
        }
    }
}

public enum GraphicsSetupProgress: Sendable {
    case stopping
    case verifying
    case installing
    case restoring
}
