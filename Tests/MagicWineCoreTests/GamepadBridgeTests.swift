import CryptoKit
import Foundation
import Testing
@testable import MagicWineCore

struct GamepadBridgeTests {
    private func fixture() throws -> (ApplicationPaths, URL, URL) {
        let paths = ApplicationPaths(root: FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString))
        try paths.prepare()
        let bottle = paths.bottlesDirectory.appendingPathComponent(UUID().uuidString)
        let prefix = bottle.appendingPathComponent("prefix")
        for folder in ["system32", "syswow64"] {
            try FileManager.default.createDirectory(at: prefix.appendingPathComponent("drive_c/windows/" + folder), withIntermediateDirectories: true)
        }
        return (paths, bottle, prefix)
    }

    private func builtin(machine: UInt16) -> Data {
        var data = Data(repeating: 0, count: 128)
        data[0] = 0x4d
        data[1] = 0x5a
        data[0x3c] = 0x60
        data.replaceSubrange(64..<81, with: "Wine builtin DLL\0".utf8)
        data[96] = 0x50
        data[97] = 0x45
        data[100] = UInt8(truncatingIfNeeded: machine)
        data[101] = UInt8(machine >> 8)
        data[119] = 0x20
        return data
    }

    private func native(machine: UInt16, tag: UInt8) -> Data {
        var data = builtin(machine: machine)
        data.replaceSubrange(64..<96, with: repeatElement(UInt8(0), count: 32))
        data[127] = tag
        return data
    }

    private func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // Explicit independent pins exercise native preservation without downloading
    // Microsoft's redistributable or depending on any real user's Steam bottle.
    private func payload(at root: URL) throws -> (GamepadBridge.Payload, [String: Data]) {
        let i686 = root.appendingPathComponent("bridge-i686.dll")
        let x8664 = root.appendingPathComponent("bridge-x86_64.dll")
        let source = root.appendingPathComponent("source.tar.gz")
        let license = root.appendingPathComponent("license.txt")
        let i686Bytes = native(machine: 0x014c, tag: 1)
        let x8664Bytes = native(machine: 0x8664, tag: 2)
        let sourceBytes = Data("test source".utf8)
        let licenseBytes = Data("test license".utf8)
        for (url, data) in [(i686, i686Bytes), (x8664, x8664Bytes), (source, sourceBytes), (license, licenseBytes)] {
            try data.write(to: url)
        }
        var natives: [String: Data] = [:]
        for (directory, machine) in [("system32", UInt16(0x8664)), ("syswow64", UInt16(0x014c))] {
            for (index, name) in ["xinput1_1", "xinput1_2", "xinput1_3", "xinput9_1_0"].enumerated() {
                natives[directory + "/" + name + ".dll"] = native(machine: machine, tag: UInt8(index + 10))
            }
        }
        return (GamepadBridge.Payload(i686: i686, x8664: x8664, source: source, license: license,
                                      i686SHA256: digest(i686Bytes), x8664SHA256: digest(x8664Bytes),
                                      sourceSHA256: digest(sourceBytes), licenseSHA256: digest(licenseBytes),
                                      redistributableSHA256: natives.mapValues { digest($0) }), natives)
    }

    private func files(in directory: URL) throws -> [String: Data] {
        var result: [String: Data] = [:]
        let entries = try #require(FileManager.default.enumerator(at: directory, includingPropertiesForKeys: [.isRegularFileKey]))
        for case let url as URL in entries where try url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile == true {
            result[String(url.path.dropFirst(directory.path.count))] = try Data(contentsOf: url)
        }
        return result
    }

    private func inode(_ url: URL) throws -> UInt64 {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        return try #require(attributes[.systemFileNumber] as? NSNumber).uint64Value
    }

    @Test func redistributablesBeforeFirstLaunchArePreservedAndBackedUp() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (payload, natives) = try payload(at: paths.root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        var nativeInodes: [String: UInt64] = [:]
        for (path, bytes) in natives {
            let url = windows.appendingPathComponent(path)
            try bytes.write(to: url)
            nativeInodes[path] = try inode(url)
        }
        let builtinURL = windows.appendingPathComponent("system32/xinput1_4.dll")
        let original = builtin(machine: 0x8664)
        try original.write(to: builtinURL)
        #expect(try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload) == GamepadBridge.overrides)
        let backup = bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1")
        for (path, bytes) in natives {
            #expect(try Data(contentsOf: windows.appendingPathComponent(path)) == bytes)
            #expect(try inode(windows.appendingPathComponent(path)) == nativeInodes[path])
            #expect(try Data(contentsOf: backup.appendingPathComponent(path + ".original")) == bytes)
        }
        #expect(try Data(contentsOf: backup.appendingPathComponent("system32/xinput1_4.dll.original")) == original)
        #expect(try Data(contentsOf: builtinURL) == Data(contentsOf: payload.x8664))
        #expect(try Data(contentsOf: windows.appendingPathComponent("syswow64/xinput1_4.dll")) == Data(contentsOf: payload.i686))
        let saved = try files(in: backup)
        _ = try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        #expect(try files(in: backup) == saved)
        for (path, bytes) in natives {
            #expect(try Data(contentsOf: windows.appendingPathComponent(path)) == bytes)
            #expect(try inode(windows.appendingPathComponent(path)) == nativeInodes[path])
        }
    }

    @Test func redistributablesReplacingInstalledBridgeKeepOriginalReceiptAndDLLs() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (payload, natives) = try payload(at: paths.root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        for (directory, machine) in [("system32", UInt16(0x8664)), ("syswow64", UInt16(0x014c))] {
            for name in GamepadBridge.dllNames {
                try builtin(machine: machine).write(to: windows.appendingPathComponent(directory + "/" + name + ".dll"))
            }
        }
        _ = try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        let backup = bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1")
        let saved = try files(in: backup)
        for (path, bytes) in natives { try bytes.write(to: windows.appendingPathComponent(path)) }
        #expect(try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload) == GamepadBridge.overrides)
        #expect(try files(in: backup) == saved)
        for (path, bytes) in natives { #expect(try Data(contentsOf: windows.appendingPathComponent(path)) == bytes) }
        #expect(try Data(contentsOf: windows.appendingPathComponent("system32/xinput1_4.dll")) == Data(contentsOf: payload.x8664))

        // Recognizing a redistributable must not bypass its old Wine backup.
        try Data("corrupt preserved original".utf8).write(to: backup.appendingPathComponent("system32/xinput1_1.dll.original"))
        let before = try files(in: windows)
        #expect(throws: MagicWineError.self) {
            try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        }
        #expect(try files(in: windows) == before)
    }

    @Test func redistributableDoesNotAllowAdoptingBridgeWithoutOriginalBackup() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (payload, natives) = try payload(at: paths.root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        _ = try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        let backup = bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1")
        try FileManager.default.removeItem(at: backup)
        for (path, bytes) in natives { try bytes.write(to: windows.appendingPathComponent(path)) }
        let before = try files(in: windows)
        #expect(throws: MagicWineError.self) {
            try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        }
        #expect(try files(in: windows) == before)
        #expect(!FileManager.default.fileExists(atPath: backup.path))
    }

    @Test(arguments: ["modified", "wrongName", "wrongArchitecture", "symbolicLink", "hardLink"])
    func untrustedRedistributableRejectsWholeInstallation(kind: String) throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (payload, natives) = try payload(at: paths.root)
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let target = windows.appendingPathComponent("syswow64/xinput9_1_0.dll")
        var bytes = try #require(natives["syswow64/xinput9_1_0.dll"])
        switch kind {
        case "modified": bytes[126] = 1
        case "wrongName": bytes = try #require(natives["syswow64/xinput1_1.dll"])
        case "wrongArchitecture": bytes = try #require(natives["system32/xinput9_1_0.dll"])
        default: break
        }
        if kind == "symbolicLink" || kind == "hardLink" {
            let linked = paths.root.appendingPathComponent("linked-native.dll")
            try bytes.write(to: linked)
            if kind == "symbolicLink" {
                try FileManager.default.createSymbolicLink(at: target, withDestinationURL: linked)
            } else {
                try FileManager.default.linkItem(at: linked, to: target)
            }
        } else {
            try bytes.write(to: target)
        }
        let first = windows.appendingPathComponent("system32/xinput1_1.dll")
        let original = builtin(machine: 0x8664)
        try original.write(to: first)
        #expect(throws: MagicWineError.self) {
            try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: first) == original)
        #expect(!FileManager.default.fileExists(atPath: bottle.appendingPathComponent("runtime-compatibility").path))
        #expect(!FileManager.default.fileExists(atPath: windows.appendingPathComponent("system32/xinput1_2.dll").path))
    }

    @Test func forgedReceiptCannotTrustCustomNativeBackup() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let (payload, natives) = try payload(at: paths.root)
        let path = "system32/xinput1_1.dll"
        let bytes = try #require(natives[path])
        let target = prefix.appendingPathComponent("drive_c/windows/" + path)
        try bytes.write(to: target)
        _ = try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        let backup = bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1")
        let receipt = backup.appendingPathComponent("originals.json")
        var forged = bytes
        forged[126] = 1
        try forged.write(to: backup.appendingPathComponent(path + ".original"))
        let json = try String(contentsOf: receipt, encoding: .utf8)
        try Data(json.replacingOccurrences(of: digest(bytes), with: digest(forged)).utf8).write(to: receipt)
        #expect(throws: MagicWineError.self) {
            try GamepadBridge.install(prefix: prefix, bottleDirectory: bottle, payload: payload)
        }
        #expect(try Data(contentsOf: target) == bytes)
        #expect(try Data(contentsOf: backup.appendingPathComponent(path + ".original")) == forged)
    }

    @Test func customControllerDLLRejectsWholeInstallationBeforeAnyReplacement() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let original = builtin(machine: 0x8664)
        let first = windows.appendingPathComponent("system32/xinput1_1.dll")
        try original.write(to: first)
        let custom = windows.appendingPathComponent("syswow64/xinput9_1_0.dll")
        let customBytes = Data("user controller middleware".utf8)
        try customBytes.write(to: custom)
        #expect(throws: MagicWineError.self) { try GamepadBridge.prepare(prefix: prefix, bottleDirectory: bottle) }
        #expect(try Data(contentsOf: first) == original)
        #expect(try Data(contentsOf: custom) == customBytes)
        #expect(!FileManager.default.fileExists(atPath: bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1").path))
        #expect(!FileManager.default.fileExists(atPath: windows.appendingPathComponent("system32/xinput1_2.dll").path))
    }

    @Test func originalLinksAndAbsentDLLsSurviveInstallationAndTamperedBackupIsRejected() throws {
        let (paths, bottle, prefix) = try fixture()
        defer { try? FileManager.default.removeItem(at: paths.root) }
        let windows = prefix.appendingPathComponent("drive_c/windows")
        let target = paths.root.appendingPathComponent("runtime-xinput.dll")
        let original = builtin(machine: 0x8664)
        try original.write(to: target)
        let linked = windows.appendingPathComponent("system32/xinput1_3.dll")
        try FileManager.default.createSymbolicLink(at: linked, withDestinationURL: target)
        _ = try GamepadBridge.prepare(prefix: prefix, bottleDirectory: bottle)
        let backup = bottle.appendingPathComponent("runtime-compatibility/magicwine-xinput-v1")
        let savedLink = backup.appendingPathComponent("system32/xinput1_3.dll.original")
        #expect(try FileManager.default.destinationOfSymbolicLink(atPath: savedLink.path) == target.path)
        #expect(try Data(contentsOf: backup.appendingPathComponent("system32/xinput1_3.dll.content")) == original)
        #expect(try Data(contentsOf: target) == original)
        #expect(!FileManager.default.fileExists(atPath: backup.appendingPathComponent("system32/xinput1_1.dll.original").path))
        let installed = try Data(contentsOf: linked)
        _ = try GamepadBridge.prepare(prefix: prefix, bottleDirectory: bottle)
        #expect(try Data(contentsOf: linked) == installed)
        try Data("tampered".utf8).write(to: backup.appendingPathComponent("system32/xinput1_3.dll.content"))
        #expect(throws: MagicWineError.self) { try GamepadBridge.prepare(prefix: prefix, bottleDirectory: bottle) }
        #expect(try Data(contentsOf: linked) == installed)
        #expect(try Data(contentsOf: target) == original)
    }
}
