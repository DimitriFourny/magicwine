import SwiftUI
import MagicWineCore

struct WindowsProgramIconView: View {
    let executablePath: String
    let prefix: URL
    /// The bottle's `LibraryModel.iconRevision`; other bottles' changes do not reload this icon.
    let revision: Int
    @State private var image: CGImage?

    private static let loader = WindowsProgramIconLoader()

    private struct Request: Equatable {
        let executablePath: String
        let prefix: URL
        let revision: Int
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 48, height: 48)
            } else {
                Image(systemName: ["lnk", "url"].contains((executablePath as NSString).pathExtension.lowercased()) ? "link" : "app")
                    .font(WineTheme.Font.iconLarge)
                    .foregroundStyle(WineTheme.muted)
            }
        }
        .frame(width: 56, height: 56)
        .background(WineTheme.elevated, in: RoundedRectangle(cornerRadius: 12))
        .accessibilityHidden(true)
        .task(id: Request(executablePath: executablePath, prefix: prefix, revision: revision)) {
            // The loader's cache is keyed by each icon source's size and modification date, so
            // an unchanged file returns at once. Keep the shown image until the result arrives.
            let loaded = await Self.loader.image(for: URL(fileURLWithPath: executablePath), prefix: prefix)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
