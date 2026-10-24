import Foundation

/// Boot work Wine still owes a prefix. When a prefix update (`wineboot -u`) finds a DLL
/// that a running Wine process has mapped, it stages the new file and records the move in
/// `PendingFileRenameOperations`. The first process of the next wineserver session runs
/// `wineboot --init`, which applies those moves over whatever the prefix then holds, so
/// they must finish before launch preparation replaces any prefix DLL.
internal enum PrefixBoot {
    private static let fs = SecureFS(prefix: "Cannot inspect Wine's pending prefix work: ")
    private static let registryMaximum = 512 * 1_048_576
    private static let sessionManager = Array(#"[system\\controlset001\\control\\session manager]"#.utf8)
    private static let pendingRenames = Array(#""pendingfilerenameoperations"="#.utf8)

    static func hasPendingRenames(prefix: URL) throws -> Bool {
        let url = prefix.appendingPathComponent("system.reg")
        guard try fs.exists(url) else { return false }
        let data = try fs.read(url, maximum: registryMaximum, allowsHardLinks: true)
        var inSessionManager = false
        for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true) {
            if line.first == UInt8(ascii: "[") {
                inSessionManager = hasPrefix(line, sessionManager)
            } else if inSessionManager, hasPrefix(line, pendingRenames) {
                return true
            }
        }
        return false
    }

    /// ASCII case-insensitive, like Wine's registry key and value names.
    private static func hasPrefix(_ line: Data, _ prefix: [UInt8]) -> Bool {
        guard line.count >= prefix.count else { return false }
        return zip(line, prefix).allSatisfy { byte, expected in
            (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains(byte) ? byte | 0x20 == expected : byte == expected
        }
    }
}
