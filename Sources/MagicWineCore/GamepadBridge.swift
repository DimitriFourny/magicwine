// SPDX-License-Identifier: GPL-3.0-or-later
import CryptoKit
import Darwin
import Foundation

/// Owned by GamepadService on the main actor. One unique mapping per app/root;
/// Wine only receives its Windows path, never a shared global controller file.
final class GamepadBridgeSession {
    private static let length = 512
    private let file: URL
    private let descriptor: Int32
    private let memory: UnsafeMutableRawPointer
    private var lastInputs = Array(repeating: EncodedInput(), count: 4)
    private var packets = [UInt32](repeating: 0, count: 4)
    private var vibrationSequences = [UInt32](repeating: 0, count: 4)
    private var vibrationDeadlines = [UInt64](repeating: 0, count: 4)
    var windowsPath: String { "Z:" + file.path.replacingOccurrences(of: "/", with: "\\") }

    private struct EncodedInput: Equatable {
        var connected: UInt32 = 0
        var buttons: UInt16 = 0
        var leftTrigger: UInt8 = 0
        var rightTrigger: UInt8 = 0
        var leftX: Int16 = 0
        var leftY: Int16 = 0
        var rightX: Int16 = 0
        var rightY: Int16 = 0
    }

    init(paths: ApplicationPaths) throws {
        let root = paths.root.standardizedFileURL
        guard root.isFileURL else { throw MagicWineError.setup("Gamepad sessions require a local application directory.") }
        if !FileManager.default.fileExists(atPath: root.path) {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        }
        try GamepadBridge.requireDirectory(root)
        var directory = root
        for name in ["Gamepads", "Sessions"] {
            directory.appendPathComponent(name, isDirectory: true)
            if try !GamepadBridge.exists(directory) {
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                                        attributes: [.posixPermissions: 0o700])
            }
            try GamepadBridge.requireDirectory(directory)
        }
        let file = directory.appendingPathComponent(UUID().uuidString + ".state")
        let fd = open(file.path, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw GamepadBridge.pathError("create the gamepad session", file) }
        guard ftruncate(fd, off_t(Self.length)) == 0 else {
            let error = GamepadBridge.pathError("size the gamepad session", file)
            close(fd)
            unlink(file.path)
            throw error
        }
        guard let address = mmap(nil, Self.length, PROT_READ | PROT_WRITE, MAP_SHARED, fd, 0),
              address != MAP_FAILED else {
            let error = GamepadBridge.pathError("map the gamepad session", file)
            close(fd)
            unlink(file.path)
            throw error
        }
        self.file = file
        descriptor = fd
        memory = address
        address.initializeMemory(as: UInt8.self, repeating: 0, count: Self.length)
        store(UInt32(0x4d574750), at: 0)
        store(UInt32(1), at: 4)
        publish(inputs: [], devices: [])
    }

    deinit {
        // Mark disconnected before unmapping. Existing Windows mappings retain
        // this inode, so they see disconnection immediately, not just on timeout.
        let sequence = memory.advanced(by: 8).assumingMemoryBound(to: Int32.self)
        OSAtomicIncrement32Barrier(sequence)
        for slot in 0..<4 { memory.storeBytes(of: UInt32(0), toByteOffset: 32 + slot * 64, as: UInt32.self) }
        memory.storeBytes(of: UInt64(0), toByteOffset: 16, as: UInt64.self)
        OSAtomicIncrement32Barrier(sequence)
        munmap(memory, Self.length)
        var opened = stat()
        var current = stat()
        if fstat(descriptor, &opened) == 0, lstat(file.path, &current) == 0,
           opened.st_dev == current.st_dev, opened.st_ino == current.st_ino {
            unlink(file.path)
        }
        close(descriptor)
    }

    func publish(inputs: [GamepadInput?], devices: [GamepadDevice?]) {
        // OSAtomic operates directly on the aligned mapped words. Plain Swift
        // assignments/volatile are not an interprocess seqlock on Apple Silicon.
        let sequence = memory.advanced(by: 8).assumingMemoryBound(to: Int32.self)
        OSAtomicIncrement32Barrier(sequence)
        for slot in 0..<4 {
            let input = slot < inputs.count ? inputs[slot] : nil
            let device = slot < devices.count ? devices[slot] : nil
            var encoded = EncodedInput()
            if let input, device != nil {
                encoded.connected = 1
                for (control, flag) in Self.buttonFlags where input.pressed.contains(control) { encoded.buttons |= flag }
                encoded.leftTrigger = Self.trigger(input.leftTrigger)
                encoded.rightTrigger = Self.trigger(input.rightTrigger)
                encoded.leftX = Self.axis(input.leftX)
                encoded.leftY = Self.axis(input.leftY)
                encoded.rightX = Self.axis(input.rightX)
                encoded.rightY = Self.axis(input.rightY)
            }
            if encoded != lastInputs[slot] {
                packets[slot] &+= 1
                lastInputs[slot] = encoded
            }
            let offset = 32 + slot * 64
            store(encoded.connected, at: offset)
            store(packets[slot], at: offset + 4)
            store(encoded.buttons, at: offset + 8)
            store(encoded.leftTrigger, at: offset + 10)
            store(encoded.rightTrigger, at: offset + 11)
            store(encoded.leftX, at: offset + 12)
            store(encoded.leftY, at: offset + 14)
            store(encoded.rightX, at: offset + 16)
            store(encoded.rightY, at: offset + 18)
            let level = device?.batteryLevel
            let knownBattery = encoded.connected != 0 && level?.isFinite == true
            let battery: UInt8 = if knownBattery, let level {
                level <= 0 ? 0 : (level < 0.2 ? 1 : (level < 0.7 ? 2 : 3))
            } else { 255 }
            store(battery, at: offset + 20)
            // GameController reports charge, not battery chemistry or wired transport.
            store(UInt8(255), at: offset + 21)
            store(UInt8(encoded.connected != 0 && device?.supportsHaptics == true ? 1 : 0), at: offset + 22)
        }
        store(Self.nowMilliseconds, at: 16)
        OSAtomicIncrement32Barrier(sequence)
    }

    func takeVibration(slot: Int) -> (left: Double, right: Double)? {
        guard (0..<4).contains(slot) else { return nil }
        let now = Self.nowMilliseconds
        let offset = 288 + slot * 16
        let sequence = memory.advanced(by: offset).assumingMemoryBound(to: Int32.self)
        let current = UInt32(bitPattern: OSAtomicAdd32Barrier(0, sequence))
        if current & 1 == 0, current != vibrationSequences[slot],
           OSAtomicCompareAndSwap32Barrier(Int32(bitPattern: current), Int32(bitPattern: current &+ 1), sequence) {
            let left = memory.load(fromByteOffset: offset + 4, as: UInt16.self)
            let right = memory.load(fromByteOffset: offset + 6, as: UInt16.self)
            let written = memory.load(fromByteOffset: offset + 8, as: UInt64.self)
            // Restore the same completed generation: taking a request is not a
            // new write. Writers cannot enter while the sequence is odd.
            OSMemoryBarrier()
            _ = OSAtomicCompareAndSwap32Barrier(Int32(bitPattern: current &+ 1), Int32(bitPattern: current), sequence)
            vibrationSequences[slot] = current
            guard lastInputs[slot].connected != 0, written > 0, written <= now,
                  now - written <= 2_000 else {
                vibrationDeadlines[slot] = 0
                return (0, 0)
            }
            vibrationDeadlines[slot] = left != 0 || right != 0 ? written + 2_000 : 0
            return (Double(left) / 65_535, Double(right) / 65_535)
        }
        if vibrationDeadlines[slot] != 0,
           now >= vibrationDeadlines[slot] || lastInputs[slot].connected == 0 {
            vibrationDeadlines[slot] = 0
            return (0, 0)
        }
        return nil
    }

    private func store<T>(_ value: T, at offset: Int) { memory.storeBytes(of: value, toByteOffset: offset, as: T.self) }
    private static var nowMilliseconds: UInt64 { UInt64(Date().timeIntervalSince1970 * 1_000) }
    private static func trigger(_ value: Double) -> UInt8 {
        value.isFinite ? UInt8((min(1, max(0, value)) * 255).rounded()) : 0
    }
    private static func axis(_ value: Double) -> Int16 {
        guard value.isFinite else { return 0 }
        let clamped = min(1, max(-1, value))
        return Int16((clamped * (clamped < 0 ? 32_768 : 32_767)).rounded())
    }
    private static let buttonFlags: [(GamepadControl, UInt16)] = [
        (.dpadUp, 0x0001), (.dpadDown, 0x0002), (.dpadLeft, 0x0004), (.dpadRight, 0x0008),
        (.start, 0x0010), (.back, 0x0020), (.leftThumb, 0x0040), (.rightThumb, 0x0080),
        (.leftShoulder, 0x0100), (.rightShoulder, 0x0200), (.guide, 0x0400),
        (.a, 0x1000), (.b, 0x2000), (.x, 0x4000), (.y, 0x8000)
    ]
}

/// The caller holds GraphicsPrefix.withLock. Only bottle-owned system DLLs are
/// changed; game-local controller middleware retains native-first precedence.
enum GamepadBridge {
    static let componentID = "magicwine-xinput-v1"
    static let sourceName = componentID + "-source.tar.gz"
    static let licenseName = "LICENSE-MAGICWINE-GAMEPAD.txt"
    static let dllNames = ["xinput1_1", "xinput1_2", "xinput1_3", "xinput1_4", "xinput9_1_0"]
    static var overrides: String { dllNames.joined(separator: ",") + "=n,b" }

    // Independently pinned outputs of scripts/build-gamepad-bridge.sh (MinGW GCC 16.2.0).
    private static let bundledI686SHA256 = "46876f2461034d5a7124738f3cc75fdcfc3720d529f0cccb6e96159b685f22ef"
    private static let bundledX8664SHA256 = "7c4e6876e9a1b165286a9c09118e12f30cb98d004237161a1cbe1bd38379190d"
    private static let bundledSourceSHA256 = "e1a49ce8166f21203f11d7dcdcf5da4a6590db0885bfc341c60a266c29a5af20"
    private static let bundledLicenseSHA256 = "3972dc9744f6499f0f9b2dbf76696f2ae7ad8af9b23dde66d6af86c9dfb36986"
    // Microsoft DirectX End-User Runtimes (June 2010): https://www.microsoft.com/en-us/download/details.aspx?id=8109
    // Independently extracted from directx_Jun2010_redist.exe, SHA-256:
    // 053f76dcbb28802e23341b6a787e3b0791c0fa5c8d4d011b1044172dbf89c73b.
    // Apr2006/AUG2006/APR2007/Oct2005_xinput_{x64,x86}.cab respectively.
    // Steam's redistributable installer can replace a previously installed bridge.
    // Leave these exact native DLLs in place; they use Microsoft's XInput, not
    // MagicWine's controller profiles. Neither version strings nor receipts confer trust.
    private static let redistributableSHA256 = [
        "system32/xinput1_1.dll": "87c7f921bbf171fa04f7c2adaf8b25d4bf152d12c6b99771da42f3af07f78987",
        "syswow64/xinput1_1.dll": "69cd725c53e0302e75db20e9a3e4b33f58dceaa2e6ea4938b2733df8bc289a71",
        "system32/xinput1_2.dll": "77055b6a144c4017acd0a8b34520cf9a84be6b9c75db40f7a708b9f4e38aa138",
        "syswow64/xinput1_2.dll": "9714d146a785d458f0de8fef387d82c9f8e101c02407a0cbeb06f02a69518eec",
        "system32/xinput1_3.dll": "756cad002e1553cfa1a91ebe8c1b9380ffabe0b4b1916c4a4db802396ddfbef8",
        "syswow64/xinput1_3.dll": "8d540d484ea41e374fd0107d55d253f87ded4ce780d515d8fd59bbe8c98970a7",
        "system32/xinput9_1_0.dll": "81c6dfcd7bcb4f2b2580a98c8e66a3eb624b44f48b80f42a1f8134e448171cc9",
        "syswow64/xinput9_1_0.dll": "9c14c5afd282be3e16117ff35d9896a96bdef497c45da950a730d279bd0e0cf6"
    ]
    private static let dllMaximum = 16 * 1_048_576
    private static let sourceMaximum = 16 * 1_048_576
    private static let licenseMaximum = 1_048_576
    private static var manager: FileManager { .default }

    struct Payload {
        let i686: URL
        let x8664: URL
        let source: URL
        let license: URL
        let i686SHA256: String
        let x8664SHA256: String
        let sourceSHA256: String
        let licenseSHA256: String
        var redistributableSHA256: [String: String] = [:]
    }

    private struct Original: Codable, Equatable {
        let path: String
        let kind: String
        let digest: String?
        let link: String?
    }
    private struct Receipt: Codable {
        let version: Int
        let originals: [Original]
    }
    private struct Destination {
        let path: String
        let machine: UInt16
        let resource: URL
        let digest: String
        let redistributableDigest: String?
    }
    private struct Inspection: Equatable {
        let original: Original?
        let content: URL?
        var preservesNative = false
    }

    static func prepare(prefix: URL, bottleDirectory: URL) throws -> String {
        guard let i686 = Bundle.module.url(forResource: componentID + "-i686", withExtension: "dll"),
              let x8664 = Bundle.module.url(forResource: componentID + "-x86_64", withExtension: "dll"),
              let source = Bundle.module.url(forResource: componentID + "-source", withExtension: "tar.gz"),
              let license = Bundle.module.url(forResource: "LICENSE-MAGICWINE-GAMEPAD", withExtension: "txt") else {
            throw MagicWineError.setup("The bundled XInput bridge is missing. Reinstall this MagicWine build; no controller DLL was replaced.")
        }
        return try install(prefix: prefix, bottleDirectory: bottleDirectory,
                           payload: Payload(i686: i686, x8664: x8664, source: source, license: license,
                                            i686SHA256: bundledI686SHA256, x8664SHA256: bundledX8664SHA256,
                                            sourceSHA256: bundledSourceSHA256, licenseSHA256: bundledLicenseSHA256,
                                            redistributableSHA256: redistributableSHA256))
    }

    /// Explicit payload pins permit isolated filesystem tests without Wine. No
    /// hash read from a bottle receipt is used to trust a bundled/native DLL.
    static func install(prefix: URL, bottleDirectory: URL, payload: Payload) throws -> String {
        let bottle = bottleDirectory.standardizedFileURL
        let prefix = prefix.standardizedFileURL
        guard bottle.isFileURL, prefix.isFileURL,
              prefix == bottle.appendingPathComponent("prefix", isDirectory: true) else {
            throw MagicWineError.setup("The XInput bridge requires the bottle's owned prefix.")
        }
        try validatePrefix(prefix, bottle: bottle)
        for (url, digest, maximum) in [(payload.i686, payload.i686SHA256, dllMaximum),
                                       (payload.x8664, payload.x8664SHA256, dllMaximum),
                                       (payload.source, payload.sourceSHA256, sourceMaximum),
                                       (payload.license, payload.licenseSHA256, licenseMaximum)] {
            try requireDirectory(url.deletingLastPathComponent())
            try verify(url, digest: digest, maximum: maximum)
        }
        try validatePE(try readFile(payload.i686, maximum: dllMaximum), machine: 0x014c, builtin: false)
        try validatePE(try readFile(payload.x8664, maximum: dllMaximum), machine: 0x8664, builtin: false)
        let destinations = ["system32", "syswow64"].flatMap { directory in
            dllNames.map { name in
                Destination(path: directory + "/" + name + ".dll",
                            machine: directory == "system32" ? 0x8664 : 0x014c,
                            resource: directory == "system32" ? payload.x8664 : payload.i686,
                            digest: directory == "system32" ? payload.x8664SHA256 : payload.i686SHA256,
                            redistributableDigest: payload.redistributableSHA256[directory + "/" + name + ".dll"])
            }
        }
        let windows = prefix.appendingPathComponent("drive_c/windows", isDirectory: true)
        let compatibility = bottle.appendingPathComponent("runtime-compatibility", isDirectory: true)
        let backup = compatibility.appendingPathComponent(componentID, isDirectory: true)
        if try exists(compatibility) { try requireDirectory(compatibility) }
        // Preflight ALL names/architectures before creating backups or replacing
        // anything. One custom DLL must leave every other DLL untouched.
        let inspections = try destinations.map { try inspect(windows.appendingPathComponent($0.path), destination: $0) }
        let receipt: Receipt
        if try exists(backup) {
            receipt = try validateBackup(backup, destinations: destinations, payload: payload)
            try matchOriginals(inspections, receipt: receipt)
        } else {
            guard inspections.allSatisfy({ $0.original != nil }) else {
                throw MagicWineError.setup("A managed XInput DLL has no original backup. The bottle was left unchanged.")
            }
            receipt = Receipt(version: 1, originals: inspections.compactMap(\.original))
            if try !exists(compatibility) {
                try manager.createDirectory(at: compatibility, withIntermediateDirectories: false,
                                            attributes: [.posixPermissions: 0o700])
            }
            try requireDirectory(compatibility)
            let stage = compatibility.appendingPathComponent(".gamepad-backup-" + UUID().uuidString, isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false,
                                        attributes: [.posixPermissions: 0o700])
            defer { try? manager.removeItem(at: stage) }
            for directory in ["system32", "syswow64"] {
                try manager.createDirectory(at: stage.appendingPathComponent(directory), withIntermediateDirectories: false)
            }
            for (destination, inspection) in zip(destinations, inspections) {
                guard let original = inspection.original else { continue }
                let saved = stage.appendingPathComponent(destination.path + ".original")
                switch original.kind {
                case "file":
                    try manager.copyItem(at: windows.appendingPathComponent(destination.path), to: saved)
                case "link":
                    guard let link = original.link, let content = inspection.content else {
                        throw MagicWineError.setup("The XInput original link could not be preserved.")
                    }
                    try manager.createSymbolicLink(atPath: saved.path, withDestinationPath: link)
                    // Also retain the resolved bytes: a relative link is kept
                    // verbatim, and a future runtime update cannot lose them.
                    try manager.copyItem(at: content, to: stage.appendingPathComponent(destination.path + ".content"))
                default: break // A DLL absent before installation has no original bytes.
                }
            }
            try manager.copyItem(at: payload.source, to: stage.appendingPathComponent(sourceName))
            try manager.copyItem(at: payload.license, to: stage.appendingPathComponent(licenseName))
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(receipt).write(to: stage.appendingPathComponent("originals.json"), options: .atomic)
            _ = try validateBackup(stage, destinations: destinations, payload: payload)
            try validatePrefix(prefix, bottle: bottle)
            try requireDirectory(compatibility)
            guard renamex_np(stage.path, backup.path, UInt32(RENAME_EXCL)) == 0 else {
                throw pathError("publish the original XInput backup", backup)
            }
        }

        var staged: [(URL, Destination)] = []
        defer { for (file, _) in staged { try? manager.removeItem(at: file) } }
        for (destination, inspection) in zip(destinations, inspections)
            where inspection.original != nil && !inspection.preservesNative {
            let target = windows.appendingPathComponent(destination.path)
            let temporary = target.deletingLastPathComponent().appendingPathComponent(".gamepad-" + UUID().uuidString + ".dll")
            try manager.copyItem(at: destination.resource, to: temporary)
            staged.append((temporary, destination))
            try verify(temporary, digest: destination.digest, maximum: dllMaximum)
        }
        try validatePrefix(prefix, bottle: bottle)
        try requireDirectory(compatibility)
        _ = try validateBackup(backup, destinations: destinations, payload: payload)
        let finalInspections = try destinations.map { try inspect(windows.appendingPathComponent($0.path), destination: $0) }
        try matchOriginals(finalInspections, receipt: receipt)
        guard finalInspections == inspections else {
            throw MagicWineError.setup("An XInput DLL changed during preparation. No replacement was installed.")
        }
        for (temporary, destination) in staged {
            // Never truncate a loaded DLL or follow a destination symlink.
            let target = windows.appendingPathComponent(destination.path)
            guard rename(temporary.path, target.path) == 0 else { throw pathError("install the XInput bridge", target) }
        }
        return overrides
    }

    private static func validatePrefix(_ prefix: URL, bottle: URL) throws {
        let bottles = bottle.deletingLastPathComponent()
        for directory in [bottles.deletingLastPathComponent(), bottles, bottle, prefix] { try requireDirectory(directory) }
        for path in ["drive_c", "drive_c/windows", "drive_c/windows/system32", "drive_c/windows/syswow64"] {
            try requireDirectory(prefix.appendingPathComponent(path, isDirectory: true))
        }
    }

    private static func inspect(_ url: URL, destination: Destination) throws -> Inspection {
        var status = stat()
        if lstat(url.path, &status) != 0 {
            guard errno == ENOENT else { throw pathError("inspect the XInput DLL", url) }
            return Inspection(original: Original(path: destination.path, kind: "absent", digest: nil, link: nil), content: nil)
        }
        let kind = status.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFLNK) else {
            throw MagicWineError.setup("The XInput path is neither a file nor a Wine link: \(url.path).")
        }
        let link = kind == mode_t(S_IFLNK) ? try manager.destinationOfSymbolicLink(atPath: url.path) : nil
        let content = link != nil ? url.resolvingSymlinksInPath() : url
        let data = try readFile(content, maximum: dllMaximum)
        let digest = sha256(data)
        if link == nil, digest == destination.digest { return Inspection(original: nil, content: nil) }
        if link == nil, digest == destination.redistributableDigest {
            try validatePE(data, machine: destination.machine, builtin: false)
            return Inspection(original: Original(path: destination.path, kind: "file", digest: digest, link: nil),
                              content: content, preservesNative: true)
        }
        do { try validatePE(data, machine: destination.machine, builtin: true) }
        catch { throw MagicWineError.setup("The bottle has a custom or invalid \(destination.path). MagicWine will not overwrite it.") }
        return Inspection(original: Original(path: destination.path, kind: link == nil ? "file" : "link",
                                             digest: digest, link: link), content: content)
    }

    private static func matchOriginals(_ inspections: [Inspection], receipt: Receipt) throws {
        guard inspections.count == receipt.originals.count else { throw MagicWineError.setup("The XInput backup is incomplete.") }
        for (inspection, original) in zip(inspections, receipt.originals) {
            // A pinned Microsoft redistributable may have replaced our bridge
            // since the original was saved. Preserve both it and the old backup.
            if !inspection.preservesNative, let current = inspection.original, current != original {
                throw MagicWineError.setup("The original XInput DLL changed after backup: \(original.path). No custom file was overwritten.")
            }
        }
    }

    private static func validateBackup(_ backup: URL, destinations: [Destination], payload: Payload) throws -> Receipt {
        try requireDirectory(backup)
        let entries = Set(try manager.contentsOfDirectory(atPath: backup.path))
        guard entries == Set(["originals.json", "system32", "syswow64", sourceName, licenseName]) else {
            throw MagicWineError.setup("The XInput backup contains missing or unrecognized files.")
        }
        let receipt = try JSONDecoder().decode(Receipt.self, from: readFile(backup.appendingPathComponent("originals.json"), maximum: 65_536))
        guard receipt.version == 1, receipt.originals.map(\.path) == destinations.map(\.path) else {
            throw MagicWineError.setup("The XInput backup manifest has an unsupported layout.")
        }
        try verify(backup.appendingPathComponent(sourceName), digest: payload.sourceSHA256, maximum: sourceMaximum)
        try verify(backup.appendingPathComponent(licenseName), digest: payload.licenseSHA256, maximum: licenseMaximum)
        var expected: [String: Set<String>] = ["system32": [], "syswow64": []]
        for directory in ["system32", "syswow64"] {
            try requireDirectory(backup.appendingPathComponent(directory, isDirectory: true))
        }
        for (original, destination) in zip(receipt.originals, destinations) {
            let saved = backup.appendingPathComponent(original.path + ".original")
            let directory = saved.deletingLastPathComponent().lastPathComponent
            let content: URL
            switch original.kind {
            case "absent":
                guard original.digest == nil, original.link == nil else { throw MagicWineError.setup("An absent XInput original has invalid metadata.") }
                continue
            case "file":
                guard original.link == nil else { throw MagicWineError.setup("An XInput original has invalid link metadata.") }
                expected[directory, default: []].insert(saved.lastPathComponent)
                content = saved
            case "link":
                var status = stat()
                guard let link = original.link, lstat(saved.path, &status) == 0,
                      status.st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                      try manager.destinationOfSymbolicLink(atPath: saved.path) == link else {
                    throw MagicWineError.setup("An original XInput symbolic link was changed or lost.")
                }
                content = backup.appendingPathComponent(original.path + ".content")
                expected[directory, default: []].formUnion([saved.lastPathComponent, content.lastPathComponent])
            default: throw MagicWineError.setup("The XInput backup contains an unknown original type.")
            }
            let data = try readFile(content, maximum: dllMaximum)
            let digest = sha256(data)
            guard digest == original.digest else { throw MagicWineError.setup("The preserved XInput original failed its SHA-256 check.") }
            let native = original.kind == "file" && digest == destination.redistributableDigest
            try validatePE(data, machine: destination.machine, builtin: !native)
        }
        for directory in ["system32", "syswow64"] {
            let url = backup.appendingPathComponent(directory, isDirectory: true)
            try requireDirectory(url)
            guard Set(try manager.contentsOfDirectory(atPath: url.path)) == expected[directory] else {
                throw MagicWineError.setup("The XInput original backup is incomplete or contains unrecognized files.")
            }
        }
        return receipt
    }

    private static func validatePE(_ data: Data, machine: UInt16, builtin: Bool) throws {
        func word(_ offset: Int) -> UInt16 { UInt16(data[offset]) | UInt16(data[offset + 1]) << 8 }
        guard data.count >= 128, data[0] == 0x4d, data[1] == 0x5a else { throw MagicWineError.setup("Invalid XInput PE header.") }
        let pe = Int(UInt32(word(0x3c)) | UInt32(word(0x3e)) << 16)
        guard pe >= 64, pe <= data.count - 24,
              data[pe] == 0x50, data[pe + 1] == 0x45, data[pe + 2] == 0, data[pe + 3] == 0,
              word(pe + 4) == machine, word(pe + 22) & 0x2000 != 0 else {
            throw MagicWineError.setup("The XInput DLL has an invalid PE architecture or image type.")
        }
        if builtin {
            let markers = [Array("Wine builtin DLL\0".utf8), Array("Wine placeholder DLL\0".utf8)]
            guard markers.contains(where: { data[64..<(64 + $0.count)].elementsEqual($0) }) else {
                throw MagicWineError.setup("The existing XInput DLL is not a Wine builtin.")
            }
        }
    }

    private static func verify(_ url: URL, digest: String, maximum: Int) throws {
        guard digest.count == 64, digest.allSatisfy({ $0.isHexDigit }),
              try sha256(readFile(url, maximum: maximum)) == digest else {
            throw MagicWineError.setup("XInput bridge SHA-256 mismatch: \(url.path). The bridge payload must be independently pinned before installation.")
        }
    }
    private static func sha256(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }

    /// Match RosettaCPUCompatibility's no-symlink/no-hardlink bounded reads and
    /// detect replacement or mutation while hashing. Backed-up links are never
    /// followed here; their resolved original bytes are stored separately.
    private static func readFile(_ url: URL, maximum: Int) throws -> Data {
        guard url.isFileURL else { throw MagicWineError.setup("XInput resources must be local files.") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw pathError("read without following links", url) }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var before = stat()
        guard fstat(fd, &before) == 0, before.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              before.st_nlink == 1, before.st_size > 0, before.st_size <= maximum else {
            throw MagicWineError.setup("XInput bridge files must be nonempty ordinary files without hard links and within their size limit: \(url.path).")
        }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        var after = stat()
        guard lstat(url.path, &after) == 0, after.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), after.st_nlink == 1,
              after.st_dev == before.st_dev, after.st_ino == before.st_ino, after.st_size == before.st_size,
              data.count == before.st_size,
              after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec,
              after.st_ctimespec.tv_sec == before.st_ctimespec.tv_sec,
              after.st_ctimespec.tv_nsec == before.st_ctimespec.tv_nsec else {
            throw MagicWineError.setup("An XInput bridge file changed during validation: \(url.path).")
        }
        return data
    }

    fileprivate static func exists(_ url: URL) throws -> Bool {
        var status = stat()
        if lstat(url.path, &status) == 0 { return true }
        if errno == ENOENT { return false }
        throw pathError("inspect", url)
    }
    fileprivate static func requireDirectory(_ url: URL) throws {
        var status = stat()
        guard lstat(url.path, &status) == 0 else { throw pathError("inspect", url) }
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else {
            throw MagicWineError.setup("The gamepad bridge requires an ordinary directory, not a symbolic link: \(url.path).")
        }
    }
    fileprivate static func pathError(_ operation: String, _ url: URL) -> MagicWineError {
        let code = errno
        return .setup("Cannot \(operation) at \(url.path): \(String(cString: strerror(code))).")
    }
}
