import Foundation

public struct WineDownloadProgress: Sendable {
    public let receivedBytes: Int64
    public let totalBytes: Int64?
    public let bytesPerSecond: Double
    public var fractionCompleted: Double? {
        guard let totalBytes else { return nil }
        return min(1, Double(receivedBytes) / Double(totalBytes))
    }

    public init(receivedBytes: Int64, totalBytes: Int64? = nil, bytesPerSecond: Double = 0) {
        self.receivedBytes = max(0, receivedBytes)
        self.totalBytes = totalBytes.flatMap { $0 > 0 ? $0 : nil }
        self.bytesPerSecond = bytesPerSecond.isFinite ? max(0, bytesPerSecond) : 0
    }
}

public enum WineInstallationProgress: Sendable {
    case fetchingMetadata
    case downloading(WineDownloadProgress)
    case verifying
    case extracting
    case preparing
    case reusing
    case checkingRuntime
}
