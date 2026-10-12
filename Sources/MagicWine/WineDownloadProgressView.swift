import Foundation
import SwiftUI
import MagicWineCore

struct WineDownloadProgressView: View {
    let progress: WineDownloadProgress

    private var percentage: String? {
        progress.fractionCompleted?.formatted(.percent.precision(.fractionLength(0)))
    }

    private var receivedSize: String {
        ByteCountFormatter.string(fromByteCount: progress.receivedBytes, countStyle: .file)
    }

    private var transferSummary: String {
        if let totalBytes = progress.totalBytes {
            let totalSize = ByteCountFormatter.string(fromByteCount: totalBytes, countStyle: .file)
            return "\(receivedSize) of \(totalSize)"
        }
        return "\(receivedSize) received"
    }

    private var speed: String {
        let bytes = progress.bytesPerSecond >= Double(Int64.max)
            ? Int64.max
            : Int64(progress.bytesPerSecond.rounded())
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private var accessibilitySummary: String {
        let transfer = "\(transferSummary), \(speed) per second"
        if let percentage { return "\(percentage), \(transfer)" }
        return transfer
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Downloading Wine…")
                Spacer()
                if let percentage { Text(percentage).monospacedDigit() }
            }
            .font(.callout)
            .accessibilityHidden(true)

            ProgressView(value: progress.fractionCompleted, total: 1)
                .progressViewStyle(.linear)
                .accessibilityLabel("Wine download")
                .accessibilityValue(accessibilitySummary)

            HStack {
                Text(transferSummary)
                Spacer()
                Text("\(speed)/s")
            }
            .font(.caption)
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
        }
    }
}
