import Foundation
import Testing
@testable import MagicWineCore

struct WindowsShortcutTests {
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
            return WindowsShortcut.candidates(for: shortcut, prefix: prefix)
        }

        func internetCandidates(_ data: Data, fileExtension suffix: String = "url") throws -> [WindowsIconSource] {
            let url = shortcut.deletingPathExtension().appendingPathExtension(suffix)
            try data.write(to: url)
            return WindowsShortcut.candidates(for: url, prefix: prefix)
        }

        func identity(_ data: Data, named name: String = "Game.lnk") throws -> WindowsShortcut.LaunchIdentity {
            let url = shortcut.deletingLastPathComponent().appendingPathComponent(name)
            try data.write(to: url)
            return WindowsShortcut.launchIdentity(for: url, prefix: prefix)
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
                      additionalFlags: UInt32 = 0, name: String? = nil, show: UInt32 = 1) -> Data {
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
        let fields: [(UInt32, String?)] = [(4, name), (8, relative), (16, working), (32, arguments), (64, icon)]
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
        put(show, in: &data, at: 60)
        for block in extra { data.append(block) }
        data.append(Data(repeating: 0, count: 4))
        return data
    }

    @Test func launchIdentityIgnoresNamesIconsEncodingAndEmptyArgumentRepresentation() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("drive_c/Program Files (x86)/Steam/steam.exe")
        let target = info(base: "C:\\Program Files (x86)\\Steam\\steam.exe")
        let cwd = "C:\\Program Files (x86)\\Steam"
        let first = try fixture.identity(link(info: target, working: cwd + "\0", arguments: "\0", name: "\0"),
                                         named: "Desktop.lnk")
        let second = try fixture.identity(link(info: target, icon: "C:\\Different.ico", index: -7,
                                              working: cwd, unicode: false, name: "Different display name"),
                                          named: "Start Menu.lnk")
        let third = try fixture.identity(link(info: target, working: cwd, arguments: ""), named: "User.lnk")
        #expect(first == second)
        #expect(second == third)
        #expect(first == WindowsShortcut.launchIdentity(for: executable, prefix: fixture.prefix))
    }

    @Test func launchIdentityPreservesExactArgumentsAndDifferentTargets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("drive_c/Games/Play.exe")
        _ = try fixture.file("drive_c/Games/Other.exe")
        let target = info(base: "C:\\Games\\Play.exe")
        var identities: Set<WindowsShortcut.LaunchIdentity> = []
        let arguments = ["", "-applaunch 10", "-applaunch 20", "--flag  value", "--flag value", "\"value\"", "value"]
        for argument in arguments {
            identities.insert(try fixture.identity(link(info: target, working: "C:\\Games", arguments: argument)))
        }
        #expect(identities.count == arguments.count)
        let other = try fixture.identity(link(info: info(base: "C:\\Games\\Other.exe"), working: "C:\\Games"))
        #expect(!identities.contains(other))
    }

    @Test func launchIdentityPreservesWorkingDirectoryRunAsAndWindowMode() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("drive_c/Games/Play.exe")
        _ = try fixture.file("drive_c/Other/data")
        let target = info(base: "C:\\Games\\Play.exe")
        let standard = try fixture.identity(link(info: target, working: "C:\\Games"))
        #expect(standard == WindowsShortcut.launchIdentity(for: executable, prefix: fixture.prefix))
        let inherited = try fixture.identity(link(info: target))
        let empty = try fixture.identity(link(info: target, working: ""))
        #expect(inherited == empty)
        #expect(inherited != standard)
        let other = try fixture.identity(link(info: target, working: "C:\\Other"))
        let runAs = try fixture.identity(link(info: target, working: "C:\\Games", additionalFlags: 0x2000))
        let separate = try fixture.identity(link(info: target, working: "C:\\Games", additionalFlags: 0x400))
        let maximized = try fixture.identity(link(info: target, working: "C:\\Games", show: 3))
        let minimized = try fixture.identity(link(info: target, working: "C:\\Games", show: 7))
        let hidden = try fixture.identity(link(info: target, working: "C:\\Games", show: 0))
        let unknown = try fixture.identity(link(info: target, working: "C:\\Games", show: 42))
        #expect(Set([standard, inherited, other, runAs, separate, maximized, minimized, hidden, unknown]).count == 9)
    }

    @Test func launchIdentityResolvesCaseDriveAliasesAndEnvironmentTargets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let executable = try fixture.file("drive_c/Program Files/Game/Play.exe")
        let devices = fixture.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("d:").path,
                                                 withDestinationPath: "../drive_c")
        let expected = WindowsShortcut.launchIdentity(for: executable, prefix: fixture.prefix)
        let alias = try fixture.identity(link(info: info(base: "d:\\program files\\game\\PLAY.EXE"),
                                             working: "D:\\PROGRAM FILES\\GAME"))
        let environmentIdentity = try fixture.identity(link(working: "%ProgramFiles%\\Game",
                                                   extra: [environment("%ProgramFiles%\\Game\\Play.exe", icon: false)],
                                                   additionalFlags: 0x02000200))
        let relative = try fixture.identity(link(relative: ".\\Play.exe", working: "C:\\Program Files\\Game"))
        #expect(alias == expected)
        #expect(environmentIdentity == expected)
        #expect(relative == expected)
    }

    @Test func launchIdentityRespectsEnvironmentPreferenceAndKeepsAmbiguousRelativeTargets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let original = try fixture.file("drive_c/Games/Play.exe")
        let alternate = try fixture.file("drive_c/Games/Alternate.exe")
        let extra = [environment("C:\\Games\\Alternate.exe", icon: false)]
        let target = info(base: "C:\\Games\\Play.exe")
        let normal = try fixture.identity(link(info: target, working: "C:\\Games", extra: extra,
                                              additionalFlags: 0x200))
        let preferred = try fixture.identity(link(info: target, working: "C:\\Games", extra: extra,
                                                 additionalFlags: 0x02000200))
        #expect(normal == WindowsShortcut.launchIdentity(for: original, prefix: fixture.prefix))
        #expect(preferred == WindowsShortcut.launchIdentity(for: alternate, prefix: fixture.prefix))
        _ = try fixture.file("drive_c/Links/Play.exe")
        let ambiguous = link(relative: "Play.exe", working: "C:\\Games")
        #expect(try fixture.identity(ambiguous, named: "First.lnk") != fixture.identity(ambiguous, named: "Second.lnk"))
    }

    @Test func launchIdentityKeepsUnresolvedUnsupportedAndMalformedLinksSeparate() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("drive_c/Games/Play.exe")
        let target = info(base: "C:\\Games\\Play.exe")
        var unknownBlock = Data(repeating: 0, count: 8)
        put(8, in: &unknownBlock, at: 0)
        put(0xa0000006, in: &unknownBlock, at: 4) // Darwin/advertised target.
        var malformedVolume = target
        put(UInt32.max, in: &malformedVolume, at: 12)
        let cases = [
            Data([0, 1, 2]),
            Data(link(info: target).dropLast()),
            link(info: info(base: "C:\\Missing.exe")),
            link(info: info(base: "\\\\server\\share\\Play.exe")),
            link(info: target, working: "C:\\Missing"),
            link(info: target, working: "%UNKNOWN%"),
            link(info: target, additionalFlags: 0x100), // ForceNoLinkInfo.
            link(info: target, extra: [unknownBlock]),
            link(info: malformedVolume),
            link(info: target, idList: Data([1, 0])),
            link(info: target, additionalFlags: 0x200), // Missing promised environment target.
            link(icon: "C:\\Games\\Play.exe"),
            Data(repeating: 0, count: 1_048_577)
        ]
        for data in cases {
            let first = try fixture.identity(data, named: "First.lnk")
            let second = try fixture.identity(data, named: "Second.lnk")
            #expect(first == .file(fixture.shortcut.deletingLastPathComponent().appendingPathComponent("First.lnk").standardizedFileURL))
            #expect(first != second)
        }
        let missing = fixture.shortcut.deletingLastPathComponent().appendingPathComponent("Missing.lnk")
        #expect(WindowsShortcut.launchIdentity(for: missing, prefix: fixture.prefix) == .file(missing.standardizedFileURL))
        #expect(try fixture.identity(link(info: target), named: "Unsupported.txt")
                == .file(fixture.shortcut.deletingLastPathComponent().appendingPathComponent("Unsupported.txt").standardizedFileURL))
    }

    @Test func internetLaunchIdentityUsesExactURLAcrossEncodingsAndIgnoresIconMetadata() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let text = "[Other]\nURL=steam://rungameid/999\n[InternetShortcut]\nURL=steam://rungameid/10?mode=one\n"
        let expected = WindowsShortcut.LaunchIdentity.internet("steam://rungameid/10?mode=one")
        for data in [Data(text.utf8), Data([0xef, 0xbb, 0xbf]) + Data(text.utf8), ansi(text),
                     Data([0xff, 0xfe]) + wide(text), Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!] {
            #expect(try fixture.identity(data, named: "Game.url") == expected)
        }
        #expect(try fixture.identity(Data((text + "IconFile=Different.ico\nIconIndex=-3").utf8), named: "Other.URL") == expected)
        for fields in ["IconFile=", "IconFile=Game.ico\nIconIndex=invalid",
                       "IconFile=One.ico\nIconFile=Two.ico", "IconIndex=0\nIconIndex=1"] {
            #expect(try fixture.identity(Data((text + fields).utf8), named: "Bad Icon.url") == expected)
        }
        for target in ["steam://rungameid/20?mode=one", "steam://rungameid/10?mode=two",
                       "steam://rungameid/10", "https://example.invalid/launch?id=10"] {
            #expect(try fixture.identity(Data("[InternetShortcut]\nURL=\(target)".utf8), named: "Game.url") != expected)
        }
    }

    @Test func internetLaunchIdentityFallsBackForMissingMalformedAndAmbiguousTargets() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for text in ["[InternetShortcut]\nIconFile=Game.ico", "[Other]\nURL=steam://rungameid/10",
                     "[InternetShortcut]\nURL=", "[InternetShortcut]\nURL=not a URL",
                     "[InternetShortcut]\nURL=steam://rungameid/10\nURL=steam://rungameid/20",
                     "[InternetShortcut]\nURL=steam://rungameid/10\nWorkingDirectory=C:\\Games"] {
            let first = try fixture.identity(Data(text.utf8), named: "First.url")
            let second = try fixture.identity(Data(text.utf8), named: "Second.url")
            #expect(first == .file(fixture.shortcut.deletingLastPathComponent().appendingPathComponent("First.url").standardizedFileURL))
            #expect(first != second)
        }
    }

    @Test func steamInternetShortcutResolvesLocalIconAndIgnoresLaunchURL() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/Program Files (x86)/Steam/steam/games/614a29118f5ee9d50971e2c1d6ac3486e94717f3.ico")
        let text = """
        [InternetShortcut]
        URL=steam://rungameid/4369130
        ICONFILE=C:\\Program Files (x86)\\Steam\\steam\\games\\614a29118f5ee9d50971e2c1d6ac3486e94717f3.ico
        ICONINDEX=0
        """
        let result = try fixture.internetCandidates(Data(text.utf8), fileExtension: "URL")
        #expect(result.map(\.url) == [icon])
        #expect(result.map(\.index) == [0])
    }

    @Test func internetShortcutEncodingsSectionsAndCaseInsensitiveKeys() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/Icons/Café.ico")
        let text = """
        IconFile=C:\\missing.ico
        [Other]
        IconFile=C:\\missing.ico
        [iNtErNeTsHoRtCuT]
        ; ignored comment
         iCoNfIlE = "c:\\icons\\café.ico"
         IcOnInDeX = -103
        [Other]
        IconIndex=not-an-index
        """
        let encodings = [
            Data(text.utf8),
            Data([0xef, 0xbb, 0xbf]) + Data(text.utf8),
            ansi(text),
            Data([0xff, 0xfe]) + wide(text),
            Data([0xfe, 0xff]) + text.data(using: .utf16BigEndian)!
        ]
        for data in encodings {
            let result = try fixture.internetCandidates(data)
            #expect(result.map(\.url) == [icon])
            #expect(result.map(\.index) == [-103])
        }
        let unicodeIcon = try fixture.file("drive_c/Icons/遊び.ico")
        for data in [Data("[InternetShortcut]\nIconFile=C:\\Icons\\遊び.ico".utf8),
                     Data([0xff, 0xfe]) + wide("[InternetShortcut]\nIconFile=C:\\Icons\\遊び.ico")] {
            #expect(try fixture.internetCandidates(data).map(\.url) == [unicodeIcon])
        }
    }

    @Test func internetShortcutUsesExistingRelativeEnvironmentAndDriveResolution() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let relative = try fixture.file("drive_c/Links/Game.ico")
        let program = try fixture.file("drive_c/Program Files (x86)/Game/Game.ico")
        let mapped = try fixture.file("External/Game.ico")
        let devices = fixture.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("d:").path, withDestinationPath: "../External")
        for (path, expected) in [(".\\game.ico", relative),
                                 ("%ProgramFiles(x86)%\\Game\\Game.ico", program),
                                 ("D:\\game.ico", mapped)] {
            let result = try fixture.internetCandidates(Data("[InternetShortcut]\r\nIconFile=\(path)\r\n".utf8))
            #expect(result.map(\.url) == [expected])
            #expect(result.map(\.index) == [0])
        }
    }

    @Test func internetShortcutIndexBoundariesAndMalformedFields() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        _ = try fixture.file("drive_c/Links/Game.ico")
        let text = "[InternetShortcut]\nIconFile=Game.ico\n"
        for index in [Int32.min, -1, 0, 1, Int32.max] {
            let result = try fixture.internetCandidates(Data("\(text)IconIndex=\(index)".utf8))
            #expect(result.map(\.index) == [Int(index)])
        }
        for index in ["", "2147483648", "-2147483649", "1.5", "0x10", "one", "1; comment"] {
            #expect(try fixture.internetCandidates(Data("\(text)IconIndex=\(index)".utf8)).isEmpty)
        }
        for text in ["", "[Other]\nIconFile=Game.ico", "[InternetShortcut]\nURL=Game.ico",
                     "[InternetShortcut]\nIconFile=", "[InternetShortcut]\nIconIndex=0",
                     "[InternetShortcut\nIconFile=Game.ico", "\(text)IconFile=Game.ico",
                     "\(text)IconIndex=0\nIconIndex=1", "\(text)\0"] {
            #expect(try fixture.internetCandidates(Data(text.utf8)).isEmpty)
        }
    }

    @Test func internetShortcutRejectsMissingNonlocalAndNonfileIconPaths() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        for path in ["Missing.ico", ".", "\\\\server\\share\\Game.ico", "//server/share/Game.ico",
                     "https://example.invalid/Game.ico", "file://server/share/Game.ico",
                     "steam://rungameid/4369130", "Q:\\Game.ico", "C:Game.ico", "%UNKNOWN%\\Game.ico"] {
            let text = "[InternetShortcut]\nURL=https://example.invalid/game\nIconFile=\(path)"
            #expect(try fixture.internetCandidates(Data(text.utf8)).isEmpty)
        }
        let devices = fixture.prefix.appendingPathComponent("dosdevices")
        try FileManager.default.createDirectory(at: devices, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(atPath: devices.appendingPathComponent("n:").path, withDestinationPath: "//server/share")
        #expect(try fixture.internetCandidates(Data("[InternetShortcut]\nIconFile=N:\\Game.ico".utf8)).isEmpty)
        let remote = URL(string: "https://example.invalid/Game.url")!
        #expect(WindowsShortcut.candidates(for: remote, prefix: fixture.prefix).isEmpty)
        let remoteFile = URL(string: "file://server/share/Game.url")!
        #expect(WindowsShortcut.candidates(for: remoteFile, prefix: fixture.prefix).isEmpty)
        #expect(WindowsShortcut.candidates(for: fixture.shortcut, prefix: remoteFile).isEmpty)
    }

    @Test func internetShortcutBoundedReadAndInvalidEncodingReturnNoCandidates() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let icon = try fixture.file("drive_c/Links/Game.ico")
        var data = Data("[InternetShortcut]\nIconFile=Game.ico\n;".utf8)
        data.append(Data(repeating: 32, count: 1_048_576 - data.count))
        #expect(try fixture.internetCandidates(data).map(\.url) == [icon])
        data.append(32)
        #expect(try fixture.internetCandidates(data).isEmpty)
        for data in [Data([0xff, 0xfe, 0x5b]), Data([0xfe, 0xff, 0x00]),
                     Data([0xef, 0xbb, 0xbf, 0xff]),
                     Data([0xff, 0xfe]) + wide("[InternetShortcut]\nIconFile=Game.ico") + Data([0x00, 0xd8])] {
            #expect(try fixture.internetCandidates(data).isEmpty)
        }
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
