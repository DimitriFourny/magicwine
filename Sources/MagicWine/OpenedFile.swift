import Foundation

/// What MagicWine can do with a Windows file the user opens in it or drops on it.
enum OpenedFileAction: Hashable {
    /// Run an EXE or MSI installer in a bottle, then look for the shortcuts it created.
    case install
    /// Register an EXE, shortcut (LNK), or Internet Shortcut (URL) as a program, in place.
    case addProgram
}

/// A file opened from Finder or the Dock, waiting for the user to choose a bottle.
struct OpenedFile: Identifiable {
    /// Extensions `OpenedFileAction.install` accepts.
    static let installerExtensions: Set<String> = ["exe", "msi"]
    /// Extensions `OpenedFileAction.addProgram` accepts; the same as the bottle store's.
    static let programExtensions: Set<String> = ["exe", "lnk", "url"]

    let id = UUID()
    let url: URL
    /// The actions that apply to this kind of file, preferred first; never empty.
    let actions: [OpenedFileAction]

    /// `nil` for anything that is not an EXE, MSI, LNK, or URL file on disk. An EXE is an
    /// installer unless `preferringProgram`; MSI always installs; LNK and URL always register.
    init?(url: URL, preferringProgram: Bool = false) {
        guard url.isFileURL else { return nil }
        switch url.pathExtension.lowercased() {
        case "exe": actions = preferringProgram ? [.addProgram, .install] : [.install, .addProgram]
        case "msi": actions = [.install]
        case "lnk", "url": actions = [.addProgram]
        default: return nil
        }
        self.url = url
    }
}

/// A file that waits for a new bottle's setup to finish.
struct PendingOpen {
    let file: OpenedFile
    let action: OpenedFileAction
}
