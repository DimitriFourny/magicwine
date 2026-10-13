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
