import AppKit

@MainActor
final class ApplicationDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Plain `swift run` has no app-bundle metadata. Packaged launches do.
        guard let iconName = Bundle.main.object(forInfoDictionaryKey: "CFBundleIconFile") as? String else { return }
        guard let iconURL = Bundle.main.url(forResource: iconName, withExtension: "icns"),
              let icon = NSImage(contentsOf: iconURL) else {
            preconditionFailure("Missing bundled application icon: \(iconName)")
        }
        NSApplication.shared.applicationIconImage = icon
    }
}
