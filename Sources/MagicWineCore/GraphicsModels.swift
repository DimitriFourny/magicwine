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
}

public enum GraphicsSetupProgress: Sendable {
    case stopping
    case downloading(WineDownloadProgress)
    case verifying
    case installing
    case restoring
}
