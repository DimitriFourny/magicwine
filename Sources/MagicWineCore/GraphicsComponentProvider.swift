import Foundation

/// One DLL a backend places in the prefix: `source` is relative to the component root,
/// `destination` to the Wine prefix.
internal struct GraphicsPrefixMapping: Hashable, Sendable {
    let source: String
    let destination: String
}

/// A Wine library module a private runtime view takes from the component instead of the
/// runtime. `name` is relative to the runtime's `lib/wine` (or `lib64/wine`) root and
/// `source` to the component root. `copies` keeps a real copy where dyld resolves
/// `@loader_path`/`@rpath` from the image's own path; other entries are links.
internal struct GraphicsViewSubstitution: Hashable, Sendable {
    let name: String
    let source: String
    var copies = false
}

/// Everything MagicWine wires per non-Standard graphics backend. `WineRuntime`,
/// `GraphicsPrefix`, `GraphicsRuntimeView`, and `StorageCleanup` look a backend's provider
/// up instead of switching over `GraphicsBackend`; adding a backend means adding a case
/// and one provider (see docs/architecture.md).
///
/// Prefix mappings are persisted in bottle manifests and transaction journals, so they
/// must stay stable for a backend once published.
internal protocol GraphicsComponentProvider: Sendable {
    var backend: GraphicsBackend { get }
    /// Prefix of every directory name this backend publishes under `Components/`.
    var componentPrefix: String { get }
    /// The component a new selection installs; `nil` when components are user imports.
    var currentComponentID: String? { get }
    /// Older bundled components this build still validates against their own pins.
    /// Bottles pinned to them keep launching and can be updated in place to the current one.
    var retainedComponentIDs: [String] { get }
    /// User-supplied components: discarding one means the user must import it again.
    var isImported: Bool { get }
    /// Whether this build can validate and launch `componentID`.
    func supports(componentID: String) -> Bool
    /// Installs (or verifies an existing copy of) the current component. Only imported
    /// backends use `source`.
    func install(paths: ApplicationPaths, source: URL?,
                 progress: (@Sendable (GraphicsSetupProgress) -> Void)?) async throws -> URL
    /// Validates an installed component against its own pins and returns its root.
    func validate(componentID: String, paths: ApplicationPaths) throws -> URL
    /// Checks the host and the bottle's Wine can run this backend.
    func validateRuntime(_ executable: URL) throws
    var prefixMappings: [GraphicsPrefixMapping] { get }
    /// Modules a private runtime view overlays; empty when launch uses the bottle's own loader.
    var viewSubstitutions: [GraphicsViewSubstitution] { get }
    /// Bottle-relative cache folder; `nil` when the backend has no managed cache/log folders.
    var cacheFolder: String? { get }
    /// The planner's graphics layer for a validated component. `loader` is the private
    /// view's executable (only for backends with view substitutions); `server` stays the
    /// bottle's pinned wineserver.
    func launchFacts(component: URL, showHUD: Bool, folders: GraphicsFolders?,
                     loader: URL?, server: URL) throws -> GraphicsLaunchFacts
}

extension GraphicsComponentProvider {
    var retainedComponentIDs: [String] { [] }
    var isImported: Bool { false }
    var viewSubstitutions: [GraphicsViewSubstitution] { [] }
    func supports(componentID: String) -> Bool {
        componentID == currentComponentID || retainedComponentIDs.contains(componentID)
    }

    func missingLaunchInput(_ input: String) -> MagicWineError {
        .setup("\(backend.displayName) launch requires \(input).")
    }
}

/// The providers one `WineRuntime` uses, keyed by backend. Standard has none.
internal struct GraphicsComponentProviders: Sendable {
    static let bundled = GraphicsComponentProviders([
        DXVKComponentProvider(), DXMTComponentProvider(), D3DMetalComponentProvider()
    ])

    let all: [any GraphicsComponentProvider]

    init(_ providers: [any GraphicsComponentProvider]) {
        all = providers
    }

    subscript(backend: GraphicsBackend) -> (any GraphicsComponentProvider)? {
        all.first { $0.backend == backend }
    }

    /// Whether this build can launch the selection (Standard has no component).
    func supports(_ configuration: GraphicsConfiguration) -> Bool {
        guard let provider = self[configuration.backend] else { return configuration.componentID == nil }
        return configuration.componentID.map(provider.supports(componentID:)) ?? false
    }

    /// A supported but non-current component of a backend that bundles its current one.
    func hasUpdate(_ configuration: GraphicsConfiguration) -> Bool {
        guard let current = self[configuration.backend]?.currentComponentID else { return false }
        return supports(configuration) && configuration.componentID != current
    }
}

extension GraphicsBackend {
    /// The bundled provider; `nil` for Standard.
    internal var componentProvider: (any GraphicsComponentProvider)? {
        GraphicsComponentProviders.bundled[self]
    }
}

internal struct DXVKComponentProvider: GraphicsComponentProvider {
    // The first six prefix paths are the historical DXVK ABI. Never reorder them.
    private static let sources = [
        "x64/d3d10core.dll", "x64/d3d11.dll", "x32/d3d10core.dll", "x32/d3d11.dll",
        "x64/d3d9.dll", "x32/d3d9.dll"
    ]

    var backend: GraphicsBackend { .dxvk }
    var componentPrefix: String { "dxvk-" }
    var currentComponentID: String? { DXVKInstallation.componentID }
    var retainedComponentIDs: [String] { DXVKInstallation.retainedComponentIDs }
    var prefixMappings: [GraphicsPrefixMapping] {
        zip(Self.sources, GraphicsPrefix.dllPaths).map { GraphicsPrefixMapping(source: $0.0, destination: $0.1) }
    }
    var cacheFolder: String? { "graphics/cache" }

    func install(paths: ApplicationPaths, source: URL?,
                 progress: (@Sendable (GraphicsSetupProgress) -> Void)?) async throws -> URL {
        try await DXVKInstallation.install(paths: paths, progress: progress)
    }

    func validate(componentID: String, paths: ApplicationPaths) throws -> URL {
        try DXVKInstallation.validate(componentID: componentID, paths: paths)
    }

    func validateRuntime(_ executable: URL) throws {
        try DXVKInstallation.validateRuntime(executable)
    }

    func launchFacts(component: URL, showHUD: Bool, folders: GraphicsFolders?,
                     loader: URL?, server: URL) throws -> GraphicsLaunchFacts {
        guard let folders else { throw missingLaunchInput("its cache and log folders") }
        return .dxvk(component: component, folders: folders, showHUD: showHUD)
    }
}

internal struct DXMTComponentProvider: GraphicsComponentProvider {
    private static let modules = ["d3d10core", "d3d11", "dxgi", "winemetal"]

    var backend: GraphicsBackend { .dxmt }
    var componentPrefix: String { "dxmt-" }
    var currentComponentID: String? { DXMTInstallation.componentID }
    var retainedComponentIDs: [String] { DXMTInstallation.retainedComponentIDs }
    var prefixMappings: [GraphicsPrefixMapping] {
        [("x86_64-windows", "system32"), ("i386-windows", "syswow64")].flatMap { source, destination in
            // Only PE DLLs enter the prefix; native helpers remain in the runtime overlay.
            Self.modules.map {
                GraphicsPrefixMapping(source: "\(source)/\($0).dll", destination: "drive_c/windows/\(destination)/\($0).dll")
            }
        }
    }
    var viewSubstitutions: [GraphicsViewSubstitution] {
        ["x86_64-windows", "i386-windows"].flatMap { architecture in
            Self.modules.map { GraphicsViewSubstitution(name: "\(architecture)/\($0).dll", source: "\(architecture)/\($0).dll") }
        } + [
            // dyld resolves @loader_path from the real image path. A provider symlink
            // cannot find this runtime's @rpath/winemac.so dependency.
            GraphicsViewSubstitution(name: "x86_64-unix/winemetal.so", source: "x86_64-unix/winemetal.so", copies: true)
        ]
    }
    var cacheFolder: String? { "graphics/dxmt-cache" }

    func install(paths: ApplicationPaths, source: URL?,
                 progress: (@Sendable (GraphicsSetupProgress) -> Void)?) async throws -> URL {
        try await DXMTInstallation.install(paths: paths, progress: progress)
    }

    func validate(componentID: String, paths: ApplicationPaths) throws -> URL {
        try DXMTInstallation.validate(componentID: componentID, paths: paths)
    }

    func validateRuntime(_ executable: URL) throws {
        try DXMTInstallation.validateRuntime(executable)
    }

    func launchFacts(component: URL, showHUD: Bool, folders: GraphicsFolders?,
                     loader: URL?, server: URL) throws -> GraphicsLaunchFacts {
        let settings = try DXMTInstallation.environment(component: component, showHUD: showHUD)
        guard let loader else { throw missingLaunchInput("its private runtime view") }
        return try .metal(componentSettings: settings, loader: loader, server: server, folders: folders)
    }
}

internal struct D3DMetalComponentProvider: GraphicsComponentProvider {
    private static let bridges = ["d3d11", "d3d12", "dxgi"]

    var backend: GraphicsBackend { .d3dmetal }
    var componentPrefix: String { "d3dmetal-" }
    var currentComponentID: String? { nil }
    var isImported: Bool { true }
    func supports(componentID: String) -> Bool { D3DMetalInstallation.supports(componentID: componentID) }
    var prefixMappings: [GraphicsPrefixMapping] {
        Self.bridges.map {
            GraphicsPrefixMapping(source: "wine/x86_64-windows/\($0).dll", destination: "drive_c/windows/system32/\($0).dll")
        }
    }
    var viewSubstitutions: [GraphicsViewSubstitution] {
        Self.bridges.flatMap {
            [GraphicsViewSubstitution(name: "x86_64-windows/\($0).dll", source: "wine/x86_64-windows/\($0).dll"),
             // Apple's Unix modules are aliases of one shared dispatch image. Loading
             // expanded archive copies separately breaks global state and @loader_path
             // framework lookup. The importer verifies their identical bytes.
             GraphicsViewSubstitution(name: "x86_64-unix/\($0).so", source: "external/libd3dshared.dylib")]
        }
    }
    var cacheFolder: String? { nil }

    func install(paths: ApplicationPaths, source: URL?,
                 progress: (@Sendable (GraphicsSetupProgress) -> Void)?) async throws -> URL {
        guard let source else { throw MagicWineError.invalidInput("Select a D3DMetal library folder.") }
        return try await D3DMetalInstallation.install(paths: paths, source: source, progress: progress)
    }

    func validate(componentID: String, paths: ApplicationPaths) throws -> URL {
        try D3DMetalInstallation.validate(componentID: componentID, paths: paths)
    }

    func validateRuntime(_ executable: URL) throws {
        try D3DMetalInstallation.validateRuntime(executable)
    }

    func launchFacts(component: URL, showHUD: Bool, folders: GraphicsFolders?,
                     loader: URL?, server: URL) throws -> GraphicsLaunchFacts {
        let settings = try D3DMetalInstallation.environment(component: component, showHUD: showHUD)
        guard let loader else { throw missingLaunchInput("its private runtime view") }
        return try .metal(componentSettings: settings, loader: loader, server: server, folders: folders)
    }
}
