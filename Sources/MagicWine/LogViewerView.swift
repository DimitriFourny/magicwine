import AppKit
import SwiftUI
import MagicWineCore

/// Follows one process log: the last few MiB while its operation runs, with level
/// filters, a text filter, the system find bar (⌘F), copy, and Reveal in Finder.
struct LogViewerView: View {
    static let windowID = "log"

    let url: URL
    @StateObject private var log: LogViewerModel
    @State private var filter = ""
    @State private var levels = Set(ProcessLogLine.Level.allCases)
    @State private var follow = true

    init(url: URL) {
        self.url = url
        _log = StateObject(wrappedValue: LogViewerModel(url: url))
    }

    private var selection: LogSelection { LogSelection(filter: filter, levels: levels) }

    var body: some View {
        VStack(spacing: 0) {
            toolbar
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
            Rectangle().fill(WineTheme.border).frame(height: 1)
            if let error = log.error {
                Text(error)
                    .font(.callout)
                    .foregroundStyle(WineTheme.muted)
                    .textSelection(.enabled)
                    .padding(16)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            } else {
                LogTextView(log: log, selection: selection, follow: follow)
            }
            Rectangle().fill(WineTheme.border).frame(height: 1)
            status
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
        }
        .frame(minWidth: 640, minHeight: 360)
        .background(WineTheme.background)
        .foregroundStyle(WineTheme.text)
        .tint(WineTheme.accent)
        .navigationTitle(url.deletingPathExtension().lastPathComponent)
        .task { await log.run() }
    }

    private var toolbar: some View {
        HStack(spacing: 10) {
            TextField("Filter lines", text: $filter)
                .textFieldStyle(.roundedBorder)
                .frame(minWidth: 160, maxWidth: 280)
            ForEach(ProcessLogLine.Level.allCases, id: \.self) { level in
                Toggle(isOn: Binding(
                    get: { levels.contains(level) },
                    set: { if $0 { levels.insert(level) } else { levels.remove(level) } }
                )) {
                    Text("\(level.title) \(log.counts[level, default: 0])").font(WineTheme.Font.callout)
                }
                .toggleStyle(.button)
                .help(level.help)
            }
            Spacer(minLength: 8)
            Toggle("Follow", isOn: $follow)
                .toggleStyle(.checkbox)
                .help("Keep the newest output in view")
            Button("Copy") { copyVisibleLines() }
                .help("Copy the lines shown with the current filters")
            Button("Reveal in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .buttonStyle(WineButtonStyle())
    }

    private var status: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(log.isActive ? WineTheme.success : WineTheme.muted)
                .frame(width: 7, height: 7)
                .accessibilityHidden(true)
            Text(log.isActive ? localized("Running: following new output") : localized("Ended"))
            if log.omittedEarlier {
                Text("· Showing the last \(ByteCountFormatter.string(fromByteCount: Int64(LogViewerModel.displayLimit), countStyle: .binary)); earlier output is in the file")
            }
            Spacer(minLength: 0)
            Text(url.path)
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
        }
        .font(WineTheme.Font.small)
        .foregroundStyle(WineTheme.muted)
    }

    private func copyVisibleLines() {
        let text = log.lines.filter(selection.includes).map(\.text).joined(separator: "\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

extension ProcessLogLine.Level {
    var title: String {
        switch self {
        case .error: localized("Errors")
        case .warning: localized("Warnings")
        case .fixme: localized("Fixme")
        case .other: localized("Other")
        }
    }

    var help: String {
        switch self {
        case .error: localized("Wine err: lines")
        case .warning: localized("Wine warn: lines")
        case .fixme: localized("Wine fixme: notes about unimplemented functions")
        case .other: localized("Program output and all other lines")
        }
    }

    var color: NSColor {
        switch self {
        case .error: WinePalette.danger
        case .warning: WinePalette.warning
        case .fixme: WinePalette.logFixme
        case .other: WinePalette.text
        }
    }
}

struct LogSelection: Equatable {
    var filter: String
    var levels: Set<ProcessLogLine.Level>

    func includes(_ line: ProcessLogLine) -> Bool {
        levels.contains(line.level) && (filter.isEmpty || line.text.range(of: filter, options: .caseInsensitive) != nil)
    }
}

/// Polls the log off the main thread and keeps at most about `displayLimit` of text.
@MainActor
final class LogViewerModel: ObservableObject {
    static let displayLimit = ProcessLogTail.defaultWindow

    @Published private(set) var lines: [ProcessLogLine] = []
    /// Changes whenever earlier lines were dropped or replaced, so views rebuild.
    @Published private(set) var generation = 0
    @Published private(set) var counts: [ProcessLogLine.Level: Int] = [:]
    @Published private(set) var isActive = false
    @Published private(set) var omittedEarlier = false
    @Published private(set) var error: String?

    private var tail: ProcessLogTail
    private var bytes = 0

    init(url: URL) {
        tail = ProcessLogTail(url: url, window: Self.displayLimit)
    }

    func run() async {
        while !Task.isCancelled {
            await poll()
            try? await Task.sleep(for: isActive ? .milliseconds(500) : .seconds(2))
        }
    }

    private func poll() async {
        let current = tail
        let (next, result) = await Task.detached(priority: .utility) { () -> (ProcessLogTail, Result<ProcessLogTail.Update, any Error>) in
            var copy = current
            let result = Result { try copy.read() }
            return (copy, result)
        }.value
        tail = next
        switch result {
        case .failure(let failure):
            error = failure.localizedDescription
            isActive = false
        case .success(let update):
            error = nil
            isActive = update.isActive
            apply(update)
        }
    }

    private func apply(_ update: ProcessLogTail.Update) {
        if update.reset {
            lines.removeAll()
            bytes = 0
            counts.removeAll()
            generation += 1
        }
        if update.omittedEarlier { omittedEarlier = true }
        guard !update.lines.isEmpty else { return }
        lines.append(contentsOf: update.lines)
        for line in update.lines {
            bytes += line.text.utf8.count + 1
            counts[line.level, default: 0] += 1
        }
        // Trim in large steps so a chatty program does not force a rebuild every poll.
        if bytes > Self.displayLimit * 3 / 2 {
            var dropped = 0
            while bytes > Self.displayLimit, dropped < lines.count {
                bytes -= lines[dropped].text.utf8.count + 1
                dropped += 1
            }
            lines.removeFirst(dropped)
            counts = Dictionary(grouping: lines, by: \.level).mapValues(\.count)
            omittedEarlier = true
            generation += 1
        }
    }
}

/// A read-only `NSTextView`: appends new matching lines while following, rebuilds when
/// filters change or earlier lines were dropped, and keeps the standard find bar.
private struct LogTextView: NSViewRepresentable {
    @ObservedObject var log: LogViewerModel
    let selection: LogSelection
    let follow: Bool

    final class Coordinator {
        var generation = -1
        var rendered = 0
        var selection: LogSelection?
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let scrollView = NSTextView.scrollableTextView()
        guard let textView = scrollView.documentView as? NSTextView else { return scrollView }
        textView.isEditable = false
        textView.isSelectable = true
        textView.isRichText = false
        textView.usesFindBar = true
        textView.isIncrementalSearchingEnabled = true
        textView.drawsBackground = true
        textView.backgroundColor = WinePalette.background
        textView.textContainerInset = NSSize(width: 8, height: 8)
        scrollView.drawsBackground = true
        scrollView.backgroundColor = WinePalette.background
        return scrollView
    }

    func updateNSView(_ scrollView: NSScrollView, context: Context) {
        guard let textView = scrollView.documentView as? NSTextView, let storage = textView.textStorage else { return }
        let coordinator = context.coordinator
        let lines = log.lines
        if coordinator.generation != log.generation || coordinator.selection != selection || coordinator.rendered > lines.count {
            storage.setAttributedString(text(for: lines[...]))
            coordinator.generation = log.generation
            coordinator.selection = selection
        } else if coordinator.rendered < lines.count {
            storage.append(text(for: lines[coordinator.rendered...]))
        } else {
            return
        }
        coordinator.rendered = lines.count
        if follow { textView.scrollToEndOfDocument(nil) }
    }

    private func text(for lines: ArraySlice<ProcessLogLine>) -> NSAttributedString {
        let font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        let result = NSMutableAttributedString()
        for line in lines where selection.includes(line) {
            result.append(NSAttributedString(string: line.text + "\n",
                                             attributes: [.font: font, .foregroundColor: line.level.color]))
        }
        return result
    }
}
