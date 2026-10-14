import SwiftUI
import MagicWineCore

struct WindowsProgramIconView: View {
    let executablePath: String
    let prefix: URL
    let revision: UUID
    @State private var image: CGImage?

    private static let loader = WindowsProgramIconLoader()

    private struct Request: Equatable {
        let executablePath: String
        let prefix: URL
        let revision: UUID
    }

    var body: some View {
        Group {
            if let image {
                Image(decorative: image, scale: 2)
                    .resizable()
                    .scaledToFit()
                    .frame(width: 32, height: 32)
            } else {
                Image(systemName: ["lnk", "url"].contains((executablePath as NSString).pathExtension.lowercased()) ? "link" : "app")
                    .font(.system(size: 20))
                    .foregroundStyle(WineTheme.muted)
            }
        }
        .frame(width: 38, height: 38)
        .background(WineTheme.elevated, in: RoundedRectangle(cornerRadius: 9))
        .accessibilityHidden(true)
        .task(id: Request(executablePath: executablePath, prefix: prefix, revision: revision)) {
            image = nil
            let loaded = await Self.loader.image(for: URL(fileURLWithPath: executablePath), prefix: prefix)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}
