import SwiftUI

extension View {
    /// Accepts files dropped from Finder. `targeted` is true while a drag is over the view and
    /// `isEnabled`, so views show a highlight only where the drop can start something; a drop
    /// while disabled still reaches `perform`, whose model call explains why it was refused.
    func fileDrop(isEnabled: Bool = true, targeted: Binding<Bool>,
                  perform: @escaping ([URL]) -> Void) -> some View {
        dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            perform(files)
            return true
        } isTargeted: { isOver in
            targeted.wrappedValue = isEnabled && isOver
        }
    }

    /// An accent outline and tint over the view while `active`, with an optional caption.
    func dropHighlight(_ active: Bool, cornerRadius: CGFloat = 12, caption: String? = nil) -> some View {
        overlay {
            if active {
                RoundedRectangle(cornerRadius: cornerRadius)
                    .fill(WineTheme.accent.opacity(0.14))
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius)
                            .strokeBorder(WineTheme.accent, style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                    }
                    .overlay {
                        if let caption {
                            Text(caption)
                                .font(.callout.weight(.semibold))
                                .padding(.horizontal, 12).padding(.vertical, 6)
                                .background(.regularMaterial, in: Capsule())
                        }
                    }
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}
