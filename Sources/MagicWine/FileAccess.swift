import AppKit
import SwiftUI
import UniformTypeIdentifiers
import MagicWineCore

/// A file or folder a view asks the user for. Models only receive the chosen URL.
enum FileImportRequest {
    case installer(Bottle)
    case program(Bottle)
    case d3dMetalFolder(Bottle)
    case wineExecutable

    fileprivate var contentTypes: [UTType] {
        switch self {
        case .installer: ["exe", "msi"].compactMap { UTType(filenameExtension: $0) }
        case .program: ["exe", "lnk", "url"].compactMap { UTType(filenameExtension: $0) }
        case .d3dMetalFolder: [.folder]
        case .wineExecutable: [.unixExecutable, .data]
        }
    }

    fileprivate var message: String {
        switch self {
        case .installer:
            "Choose an EXE or MSI installer. Its Windows installer will open in this bottle."
        case .program:
            "Choose an EXE, LNK shortcut, or URL Internet Shortcut. Removing it from MagicWine does not delete the file."
        case .d3dMetalFolder:
            "No D3DMetal libraries were found beside this bottle’s Wine or in an installed CrossOver. Choose your legally obtained library folder. MagicWine does not download these libraries or accept their terms for you."
        case .wineExecutable:
            "Select the native wine or wineloader executable inside a Wine installation, not its application bundle or a wrapper that changes WINEPREFIX. Metal backends require a compatible Metal driver."
        }
    }

    fileprivate var confirmationLabel: String {
        if case .d3dMetalFolder = self { return "Import" }
        return "Choose"
    }
}

/// Asks the window's file dialog for a file; see `View.fileImportHost(_:)`.
struct FileImportAction {
    fileprivate let request: @MainActor (FileImportRequest) -> Void

    @MainActor
    func callAsFunction(_ request: FileImportRequest) {
        self.request(request)
    }
}

private struct FileImportActionKey: EnvironmentKey {
    static let defaultValue: FileImportAction? = nil
}

extension EnvironmentValues {
    /// Set by `fileImportHost` for every view in its window.
    var fileImport: FileImportAction? {
        get { self[FileImportActionKey.self] }
        set { self[FileImportActionKey.self] = newValue }
    }
}

extension View {
    /// Presents the window's single file dialog and hands the chosen URL to the model.
    /// One host per window: SwiftUI shows only one `fileImporter` per view hierarchy.
    func fileImportHost(_ model: AppModel) -> some View {
        modifier(FileImportHost(model: model))
    }
}

private struct FileImportHost: ViewModifier {
    let model: AppModel
    @State private var pending: FileImportRequest?
    @State private var isPresented = false

    func body(content: Content) -> some View {
        content
            .environment(\.fileImport, FileImportAction { request in
                pending = request
                isPresented = true
            })
            .fileImporter(isPresented: $isPresented, allowedContentTypes: pending?.contentTypes ?? [.item]) { result in
                guard let request = pending, case .success(let url) = result else { return }
                pending = nil
                choose(url, for: request)
            }
            .fileDialogMessage(Text(pending?.message ?? ""))
            .fileDialogConfirmationLabel(Text(pending?.confirmationLabel ?? "Choose"))
            .fileDialogBrowserOptions(.enumeratePackages)
    }

    private func choose(_ url: URL, for request: FileImportRequest) {
        switch request {
        case .installer(let bottle):
            model.activity.install(url, in: bottle)
        case .program(let bottle):
            model.activity.addProgram(url, to: bottle)
        case .d3dMetalFolder(let bottle):
            model.bottleSettings.setGraphics(.d3dmetal, in: bottle, showHUD: bottle.graphics.showHUD, componentSource: url)
        case .wineExecutable:
            model.runtimes.inspectCustomWine(url)
        }
    }
}

/// Finder reveals for library folders and files.
@MainActor
enum Finder {
    static func reveal(_ url: URL) {
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    /// Wine and component installation logs; a bottle's logs have their own list.
    static func revealLibraryLogs(paths: ApplicationPaths) {
        let library = ProcessLogs.libraryDirectory(paths: paths)
        reveal(FileManager.default.fileExists(atPath: library.path) ? library : paths.logsDirectory)
    }

    static func revealLogs(forBottle id: UUID, paths: ApplicationPaths) {
        let folder = ProcessLogs.bottleDirectory(id, paths: paths)
        reveal(FileManager.default.fileExists(atPath: folder.path) ? folder : paths.logsDirectory)
    }
}
