import Foundation
import Testing
@testable import MagicWineCore

struct WindowsShortcutIconSourcesTests {
    private struct Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        var prefix: URL { root.appendingPathComponent("prefix") }
        var shortcut: URL { prefix.appendingPathComponent("drive_c/Links/Game.lnk") }

        init() throws {
            try FileManager.default.createDirectory(at: shortcut.deletingLastPathComponent(), withIntermediateDirectories: true)
        }

        func file(_ path: String) throws -> URL {
            let url = prefix.appendingPathComponent(path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data([1]).write(to: url)
            return url.resolvingSymlinksInPath()
        }

        func candidates(_ data: Data) throws -> [WindowsIconSource] {
            try data.write(to: shortcut)
            return WindowsShortcutIconSources.candidates(for: shortcut, prefix: prefix)
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    private func put(_ value: UInt32, in data: inout Data, at offset: Int) {
        for byte in 0..<4 { data[offset + byte] = UInt8(truncatingIfNeeded: value >> (byte * 8)) }
    }

    private func ansi(_ string: String) -> Data { string.data(using: .windowsCP1252)! }
    private func wide(_ string: String) -> Data { string.data(using: .utf16LittleEndian)! }

    private func info(base: String, suffix: String = "", unicode: String? = nil, unicodeSuffix: String? = nil) -> Data {
        var data = Data(repeating: 0, count: unicode == nil ? 28 : 36)
        put(UInt32(data.count), in: &data, at: 4)
        put(1, in: &data, at: 8)
        put(UInt32(data.count), in: &data, at: 12)
        // Local volume descriptor: fixed disk, empty volume label.
        var volume = Data(repeating: 0, count: 17)
        put(17, in: &volume, at: 0)
        put(3, in: &volume, at: 4)
        put(16, in: &volume, at: 12)
        data.append(volume)
        put(UInt32(data.count), in: &data, at: 16)
        data.append(ansi(base + "\0"))
        put(UInt32(data.count), in: &data, at: 24)
        data.append(ansi(suffix + "\0"))
        if let unicode {
            put(UInt32(data.count), in: &data, at: 28)
            data.append(wide(unicode + "\0"))
            put(UInt32(data.count), in: &data, at: 32)
            data.append(wide((unicodeSuffix ?? suffix) + "\0"))
        }
        put(UInt32(data.count), in: &data, at: 0)
        return data
    }

    private func environment(_ path: String, icon: Bool, unicode: Bool = true) -> Data {
        var data = Data(repeating: 0, count: 788)
        put(788, in: &data, at: 0)
        put(icon ? 0xa0000007 : 0xa0000001, in: &data, at: 4)
        let narrow = ansi(unicode ? "C:\\unavailable.exe" : path)
        data.replaceSubrange(8..<(8 + narrow.count), with: narrow)
        if unicode {
            let utf16 = wide(path)
            data.replaceSubrange(268..<(268 + utf16.count), with: utf16)
        }
        return data
    }

    private func link(info: Data? = nil, icon: String? = nil, index: Int32 = 0,
                      relative: String? = nil, working: String? = nil, arguments: String? = nil,
                      unicode: Bool = true, extra: [Data] = [], idList: Data? = nil,
                      additionalFlags: UInt32 = 0) -> Data {
        var data = Data(repeating: 0, count: 76)
        put(76, in: &data, at: 0)
        data.replaceSubrange(4..<20, with: [1, 0x14, 2, 0, 0, 0, 0, 0, 0xc0, 0, 0, 0, 0, 0, 0, 0x46])
        var flags: UInt32 = (unicode ? 0x80 : 0) | additionalFlags
        if let idList {
            flags |= 1
            data.append(UInt8(truncatingIfNeeded: idList.count))
            data.append(UInt8(truncatingIfNeeded: idList.count >> 8))
            data.append(idList)
        }
        if let info { flags |= 2; data.append(info) }
        let fields: [(UInt32, String?)] = [(8, relative), (16, working), (32, arguments), (64, icon)]
        for (flag, value) in fields {
            guard let value else { continue }
            flags |= flag
            let encoded = unicode ? wide(value) : ansi(value)
            let count = encoded.count / (unicode ? 2 : 1)
            data.append(UInt8(truncatingIfNeeded: count))
            data.append(UInt8(truncatingIfNeeded: count >> 8))
            data.append(encoded)
        }
        put(flags, in: &data, at: 20)
        put(UInt32(bitPattern: index), in: &data, at: 56)
        for block in extra { data.append(block) }
        data.append(Data(repeating: 0, count: 4))
        return data
    }

    @Test func explicitIconPrecedesTargetAndPreservesNegativeResourceID() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/Games/Custom.ico")
        let executable = try fixture.file("drive_c/Games/Play.exe")
        let result = try fixture.candidates(link(info: info(base: "C:\\Games\\Play.exe"),
                                                icon: "C:\\Games\\Custom.ico", index: -103))
        #expect(result.map(\.url) == [icon, executable])
        #expect(result.map(\.index) == [-103, 0])
    }

    @Test func missingIconFallsBackAndArgumentsAreNeverInterpreted() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("drive_c/Games/Play.exe")
        let result = try fixture.candidates(link(info: info(base: "C:\\Games\\Play.exe"),
                                                icon: "C:\\Missing.ico", arguments: "C:\\Other.exe --icon"))
        #expect(result.map(\.url) == [executable])
        #expect(try fixture.candidates(link(relative: "C:\\Games\\Play.exe --launch")).isEmpty)
        #expect(try fixture.candidates(link(arguments: "C:\\Games\\Play.exe")).isEmpty)
    }

    @Test func unicodeLinkInfoOverridesLossyANSIAndCombinesSuffix() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("drive_c/ゲーム/遊ぶ.exe")
        let local = info(base: "C:\\missing.exe", unicode: "C:\\ゲーム\\遊ぶ.exe")
        #expect(try fixture.candidates(link(info: local)).map(\.url) == [executable])
        let split = info(base: "C:\\????", suffix: "Play.exe", unicode: "C:\\ゲーム", unicodeSuffix: "遊ぶ.exe")
        #expect(try fixture.candidates(link(info: split)).map(\.url) == [executable])
        let other = try fixture.file("drive_c/Games/Play.exe")
        #expect(try fixture.candidates(link(info: info(base: "C:\\Games", suffix: "Play.exe"))).map(\.url) == [other])
    }

    @Test func relativePathsUseWorkingDirectoryAndWineTerminatedStringData() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/Games/Icons/Game.ico")
        let executable = try fixture.file("drive_c/Games/Bin/Play.exe")
        let result = try fixture.candidates(link(icon: "..\\Icons\\Game.ico\0", relative: ".\\Play.exe\0",
                                                working: "c:\\games\\bin\0", idList: Data([0, 0])))
        #expect(result.map(\.url) == [icon, executable])
        #expect(try fixture.candidates(link(relative: "..\\Games\\Bin\\Play.exe", unicode: false)).map(\.url) == [executable])
    }

    @Test func dosdeviceMappingUsesCaseInsensitiveComponentsAndStableDeduplication() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("External/Game/PLAY.EXE")
        let devices = fixture.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("d:").path, withDestinationPath: "../External")
        let result = try fixture.candidates(link(info: info(base: "D:\\game\\play.exe"), icon: "d:\\GAME\\Play.exe",
                                                relative: "D:\\Game\\PLAY.EXE"))
        #expect(result.map(\.url) == [executable])
        #expect(result.map(\.index) == [0])
        let indexed = try fixture.candidates(link(info: info(base: "D:\\game\\play.exe"), icon: "d:\\Game\\PLAY.EXE", index: 2))
        #expect(indexed.map(\.index) == [2, 0])
    }

    @Test func environmentBlocksUseUnicodeAndBottleSpecificUserPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/users/TestUser/AppData/Local/遊び.ico")
        let executable = try fixture.file("drive_c/Program Files/Game/Play.exe")
        let result = try fixture.candidates(link(index: -7, extra: [
            environment("%LOCALAPPDATA%\\遊び.ico", icon: true),
            environment("%ProgramFiles%\\Game\\Play.exe", icon: false, unicode: false)
        ], additionalFlags: 0x4200))
        #expect(result.map(\.url) == [icon, executable])
        #expect(result.map(\.index) == [-7, 0])
        #expect(try fixture.candidates(link(icon: "%UNKNOWN%\\icon.ico")).isEmpty)
    }

    @Test func environmentPreferenceAndExplicitIconOrderAreStable() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let explicit = try fixture.file("drive_c/Icons/Explicit.ico")
        let environmentIcon = try fixture.file("drive_c/windows/Environment.ico")
        let target = try fixture.file("drive_c/Games/Play.exe")
        let environmentTarget = try fixture.file("drive_c/windows/Alternate.exe")
        let result = try fixture.candidates(link(info: info(base: "C:\\Games\\Play.exe"), icon: "C:\\Icons\\Explicit.ico", extra: [
            environment("%SystemRoot%\\Environment.ico", icon: true),
            environment("%windir%\\Alternate.exe", icon: false)
        ], additionalFlags: 0x02004200))
        #expect(result.map(\.url) == [explicit, environmentIcon, environmentTarget, target])
    }

    @Test func networkAndUnmappedDrivePathsAreSkipped() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["\\\\server\\share\\Game.exe", "//server/share/Game.exe", "Q:\\Game.exe", "C:Game.exe", "\\\\?\\UNC\\server\\share\\Game.exe"] {
            #expect(try fixture.candidates(link(icon: path, relative: path)).isEmpty)
        }
        let devices = fixture.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("n:").path, withDestinationPath: "//server/share")
        #expect(try fixture.candidates(link(icon: "N:\\Game.exe")).isEmpty)
    }

    @Test func malformedAndEveryTruncatedBoundaryReturnNoCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("drive_c/Game.exe")
        let valid = link(info: info(base: "C:\\Game.exe"), icon: "C:\\Game.exe", extra: [environment("C:\\Game.exe", icon: true)], idList: Data([0, 0]))
        for count in 0..<valid.count {
            #expect(try fixture.candidates(Data(valid.prefix(count))).isEmpty)
        }
        var badHeader = valid
        badHeader[4] = 0
        #expect(try fixture.candidates(badHeader).isEmpty)
        var badOffset = info(base: "C:\\Game.exe")
        put(UInt32.max, in: &badOffset, at: 16)
        #expect(try fixture.candidates(link(info: badOffset)).isEmpty)
        var badBlock = environment("C:\\Game.exe", icon: true)
        put(UInt32.max, in: &badBlock, at: 0)
        #expect(try fixture.candidates(link(icon: "C:\\Game.exe", extra: [badBlock])).isEmpty)
        var badString = link(icon: "C:\\Game.exe")
        badString[76] = 0xff
        badString[77] = 0xff
        #expect(try fixture.candidates(badString).isEmpty)
        #expect(try fixture.candidates(Data(repeating: 0, count: 1_048_577)).isEmpty)
    }
}
