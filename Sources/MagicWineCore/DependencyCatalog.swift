import Foundation

/// A redistributable a game or launcher may need inside a bottle. Every download is
/// pinned by URL, size and SHA-256; nothing here follows a rolling "latest" link.
public struct DependencyItem: Identifiable, Hashable, Sendable {
    public let id: String
    public let name: String
    public let version: String
    public let summary: String
    /// Windows architectures the item provides; empty for architecture-neutral fonts.
    public let architectures: [DependencyArchitecture]
    public let license: DependencyLicense
    public let downloads: [DependencyDownload]
    let method: DependencyInstallMethod
    /// Imported after the files are in place: DLL overrides and font registrations.
    let registry: [DependencyRegistryValue]
    /// All must pass after installation; they are also the installed status.
    let checks: [DependencyCheck]

    public var downloadSize: Int64 { downloads.reduce(0) { $0 + $1.size } }

    public static func == (lhs: DependencyItem, rhs: DependencyItem) -> Bool { lhs.id == rhs.id }
    public func hash(into hasher: inout Hasher) { hasher.combine(id) }
}

public enum DependencyArchitecture: String, Hashable, Sendable {
    case x86, x64

    /// Directory below `drive_c/windows` of a 64-bit (WoW64) prefix.
    var systemDirectory: String { self == .x64 ? "system32" : "syswow64" }
    var machine: UInt16 { self == .x64 ? PEInspector.amd64 : PEInspector.i386 }
}

public struct DependencyLicense: Hashable, Sendable {
    public let name: String
    public let url: URL
}

public struct DependencyDownload: Hashable, Sendable {
    public let url: URL
    public let fileName: String
    public let sha256: String
    public let size: Int64
}

/// A file taken from a downloaded cabinet and placed below `drive_c/windows`.
struct DependencyFile: Hashable, Sendable {
    /// Index into the item's `downloads`.
    let download: Int
    let member: String
    let sha256: String
    let size: Int
    /// Relative to `drive_c/windows`, for example `syswow64/d3dcompiler_47.dll`.
    let destination: String
    /// PE machine for DLLs; nil for fonts.
    let machine: UInt16?
    /// Registered under the Windows font keys as "<name> (TrueType)".
    let fontName: String?
}

enum DependencyInstallMethod: Hashable, Sendable {
    /// Runs the single download with these arguments; the post-install checks decide success.
    case silentInstaller(arguments: [String])
    /// Extracts pinned members and places them, refusing to overwrite unknown files.
    case files([DependencyFile])
}

enum DependencyCheck: Hashable, Sendable {
    /// A non-Wine PE DLL of this machine, relative to `drive_c/windows`.
    case nativeDLL(String, machine: UInt16)
    /// A nonempty regular file, relative to `drive_c/windows`.
    case file(String)
    case registry(DependencyRegistryValue)
}

struct DependencyRegistryValue: Hashable, Sendable {
    enum Hive: Hashable, Sendable {
        case currentUser, localMachine
        var regName: String { self == .currentUser ? "HKEY_CURRENT_USER" : "HKEY_LOCAL_MACHINE" }
        var fileName: String { self == .currentUser ? "user.reg" : "system.reg" }
    }
    let hive: Hive
    /// Backslash-separated key below the hive.
    let key: String
    let name: String
    let value: String
}

public enum DependencyCatalog {
    public static let items: [DependencyItem] = [vcRuntime(.x64), vcRuntime(.x86), d3dCompiler, coreFonts]

    public static func item(id: String) -> DependencyItem? { items.first { $0.id == id } }

    // MARK: Visual C++

    private static let vcLicense = DependencyLicense(
        name: "Microsoft Visual C++ Redistributable license terms",
        url: URL(string: "https://visualstudio.microsoft.com/license-terms/vs2022-cruntime/")!)

    /// Winetricks' vcrun2022 override list; vcruntime140_1 exists only for x64.
    private static let vcDLLs = ["concrt140", "msvcp140", "msvcp140_1", "msvcp140_2", "msvcp140_atomic_wait",
                                 "msvcp140_codecvt_ids", "vcamp140", "vccorlib140", "vcomp140", "vcruntime140"]

    /// 14.44.35211 is the final 2015-2022 (VS 17) release. Microsoft documents the
    /// versioned `aka.ms/vs/17/release/<version>/` links; these are their targets.
    private static func vcRuntime(_ architecture: DependencyArchitecture) -> DependencyItem {
        let x64 = architecture == .x64
        let dlls = x64 ? vcDLLs + ["vcruntime140_1"] : vcDLLs
        let directory = architecture.systemDirectory
        let checked = x64 ? ["vcruntime140", "vcruntime140_1", "msvcp140", "concrt140"] : ["vcruntime140", "msvcp140", "concrt140"]
        let download = x64
            ? DependencyDownload(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/e7e6edbd-bd7b-49c0-a85a-5b730b468df1/CC0FF0EB1DC3F5188AE6300FAEF32BF5BEEBA4BDD6E8E445A9184072096B713B/VC_redist.x64.exe")!,
                                 fileName: "VC_redist.x64.exe",
                                 sha256: "cc0ff0eb1dc3f5188ae6300faef32bf5beeba4bdd6e8e445a9184072096b713b", size: 25_635_768)
            : DependencyDownload(url: URL(string: "https://download.visualstudio.microsoft.com/download/pr/e7e6edbd-bd7b-49c0-a85a-5b730b468df1/0C09F2611660441084CE0DF425C51C11E147E6447963C3690F97E0B25C55ED64/VC_redist.x86.exe")!,
                                 fileName: "VC_redist.x86.exe",
                                 sha256: "0c09f2611660441084ce0df425c51c11e147e6447963c3690f97e0b25c55ed64", size: 13_953_392)
        let registry = dlls.map { override($0, mode: "native,builtin") }
        return DependencyItem(
            id: x64 ? "vcrun2022-x64" : "vcrun2022-x86",
            name: "Visual C++ 2015–2022 Redistributable (\(architecture.rawValue))",
            version: "14.44.35211",
            summary: "Microsoft C/C++ runtime DLLs (msvcp140, vcruntime140, concrt140, MFC) for \(x64 ? "64" : "32")-bit programs.",
            architectures: [architecture], license: vcLicense, downloads: [download],
            method: .silentInstaller(arguments: ["/install", "/quiet", "/norestart"]),
            registry: registry,
            checks: checked.map { .nativeDLL("\(directory)/\($0).dll", machine: architecture.machine) }
                + registry.map { .registry($0) })
    }

    // MARK: d3dcompiler_47

    /// Windows 8.1 SDK cabinets on download.microsoft.com, as used by winetricks:
    /// 6.3.9600.16384 for 32-bit and 64-bit programs.
    private static let d3dCompiler: DependencyItem = {
        let base = "https://download.microsoft.com/download/B/0/C/B0C80BA3-8AD6-4958-810B-6882485230B5/standalonesdk/Installers/"
        let files = [
            DependencyFile(download: 0, member: "fila319f706acfa16d6707473ebf29bdc7f",
                           sha256: "efbdbbcd0d954f8fdc53467de5d89ad525e4e4a9cfff8a15d07c6fdb350c407f", size: 3_466_856,
                           destination: "syswow64/d3dcompiler_47.dll", machine: PEInspector.i386, fontName: nil),
            DependencyFile(download: 1, member: "fil3585cb2ea5db13cc0838f8d06b5c9679",
                           sha256: "e994847e01a6f1e4cbdc5a864616ac262f67ee4f14db194984661a8d927ab7f4", size: 4_173_928,
                           destination: "system32/d3dcompiler_47.dll", machine: PEInspector.amd64, fontName: nil)
        ]
        let registry = [override("d3dcompiler_47", mode: "native")]
        return DependencyItem(
            id: "d3dcompiler_47", name: "D3DCompiler 47", version: "6.3.9600.16384",
            summary: "Microsoft's HLSL shader compiler DLL for 32- and 64-bit programs; many launchers and engines load it at startup.",
            architectures: [.x86, .x64],
            license: DependencyLicense(name: "Windows SDK license terms (redistributable code)",
                                       url: URL(string: "https://learn.microsoft.com/en-us/legal/windows-sdk/license")!),
            downloads: [
                DependencyDownload(url: URL(string: base + "2630bae9681db6a9f6722366f47d055c.cab")!,
                                   fileName: "2630bae9681db6a9f6722366f47d055c.cab",
                                   sha256: "d0440eb81c532dc23639c0c63f2fcde9deddb23bb4cce01c19ac6b96cc3e269d", size: 1_488_323),
                DependencyDownload(url: URL(string: base + "61d57a7a82309cd161a854a6f4619e52.cab")!,
                                   fileName: "61d57a7a82309cd161a854a6f4619e52.cab",
                                   sha256: "f736e161547095bb8d98c636b85fdfeb4070fefeee3c3745db3ce88f6eb1d9de", size: 1_776_364)
            ],
            method: .files(files), registry: registry,
            checks: files.map { .nativeDLL($0.destination, machine: $0.machine!) } + registry.map { .registry($0) })
    }()

    // MARK: Core fonts

    /// Microsoft's 1998-2000 "TrueType core fonts for the Web" self-extracting cabinets,
    /// mirrored at a pinned commit of github.com/pushcx/corefonts (winetricks' source).
    private static let coreFonts: DependencyItem = {
        let commit = "8f8627b0004b5f1b952c09cf6390e4ae46475e59"
        let packages: [(file: String, sha256: String, size: Int64, fonts: [(member: String, sha256: String, size: Int, name: String)])] = [
            ("andale32.exe", "0524fe42951adc3a7eb870e32f0920313c71f170c859b5f770d82b4ee111e970", 198_384, [
                ("AndaleMo.TTF", "48d9bc613917709d3b0e0f4a6d4fe33a5c544c5035dffe9e90bc11e50e822071", 105_468, "Andale Mono")]),
            ("arial32.exe", "85297a4d146e9c87ac6f74822734bdee5f4b2a722d7eaa584b7f2cbf76f478f6", 554_208, [
                ("Arial.TTF", "35c0f3559d8db569e36c31095b8a60d441643d95f59139de40e23fada819b833", 275_572, "Arial"),
                ("Arialbd.TTF", "4044aa6b5bebbc36980206b45b0aaaaa5681552a48bcadb41746d5d1d71fd7b4", 286_620, "Arial Bold"),
                ("Arialbi.TTF", "2f371cd9d96b3ac544519d85c16dc43ceacdfcea35090ee8ddf3ec5857c50328", 224_692, "Arial Bold Italic"),
                ("Ariali.TTF", "70ade233175a6a6675e4501461af9326e6f78b1ffdf787ca0da5ab0fc8c9cfd6", 206_132, "Arial Italic")]),
            ("arialb32.exe", "a425f0ffb6a1a5ede5b979ed6177f4f4f4fdef6ae7c302a7b7720ef332fec0a8", 168_176, [
                ("AriBlk.TTF", "dad7c04acb26e23dfe4780e79375ca193ddaf68409317e81577a30674668830e", 117_028, "Arial Black")]),
            ("comic32.exe", "9c6df3feefde26d4e41d4a4fe5db2a89f9123a772594d7f59afd062625cd204e", 246_008, [
                ("Comic.TTF", "b82c53776058f291382ff7e008d4675839d2dc21eb295c66391f6fb0655d8fc0", 126_364, "Comic Sans MS"),
                ("Comicbd.TTF", "873361465d994994762d0b9845c99fc7baa2a600442ea8db713a7dd19f8b0172", 111_476, "Comic Sans MS Bold")]),
            ("courie32.exe", "bb511d861655dde879ae552eb86b134d6fae67cb58502e6ff73ec5d9151f3384", 646_368, [
                ("cour.ttf", "6715838c52f813f3821549d3f645db9a768bd6f3a43d8f85a89cb6875a546c61", 302_688, "Courier New"),
                ("courbd.ttf", "edf8a7c5bfcac2e1fe507faab417137cbddc9071637ef4648238d0768c921e02", 311_508, "Courier New Bold"),
                ("courbi.ttf", "66dbfa20b534fba0e203da140fec7276a45a1069e424b1b9c35547538128bbe8", 234_788, "Courier New Bold Italic"),
                ("couri.ttf", "f3f6b09855b6700977e214aab5eb9e5be6813976a24f894bd7766e92c732fbe1", 244_156, "Courier New Italic")]),
            ("georgi32.exe", "2c2c7dcda6606ea5cf08918fb7cd3f3359e9e84338dc690013f20cd42e930301", 392_440, [
                ("Georgia.TTF", "7d0bb20c632bb59e81a0885f573bd2173f71f73204de9058feb68ce032227072", 142_964, "Georgia"),
                ("Georgiab.TTF", "82d2fbadb88a8632d7f2e8ad50420c9fd2e7d3cbc0e90b04890213a711b34b93", 139_584, "Georgia Bold"),
                ("Georgiai.TTF", "1523f19bda6acca42c47c50da719a12dd34f85cc2606e6a5af15a7728b377b60", 156_668, "Georgia Italic"),
                ("Georgiaz.TTF", "c983e037d8e4e694dd0fb0ba2e625bca317d67a41da2dc81e46a374e53d0ec8a", 158_796, "Georgia Bold Italic")]),
            ("impact32.exe", "6061ef3b7401d9642f5dfdb5f2b376aa14663f6275e60a51207ad4facf2fccfb", 173_288, [
                ("Impact.TTF", "00f1fc230ac99f9b97ba1a7c214eb5b909a78660cb3826fca7d64c3af5a14848", 136_076, "Impact")]),
            ("times32.exe", "db56595ec6ef5d3de5c24994f001f03b2a13e37cee27bc25c58f6f43e8f807ab", 661_728, [
                ("Times.TTF", "4e98adeff8ccc8ef4e3ece8d4547e288ff85fdc9c7ca711a4599c234874bbe86", 330_412, "Times New Roman"),
                ("Timesbd.TTF", "4357b63cef20c01661a53c5dae70ffd20cb4765503aaed6d38b17a57c5a90bff", 333_900, "Times New Roman Bold"),
                ("Timesbi.TTF", "192e1b0d18e90334e999a99f8c32808d6a2e74b3698b8cd90c943c2249a46549", 238_612, "Times New Roman Bold Italic"),
                ("Timesi.TTF", "c25ae529b4cecdbca148b6ccb862ee0abad770af8b1fd29c8dba619d1b8da78a", 247_092, "Times New Roman Italic")]),
            ("trebuc32.exe", "5a690d9bb8510be1b8b4fe49f1f2319651fe51bbe54775ddddd8ef0bd07fdac9", 357_200, [
                ("trebuc.ttf", "ec3ffb302488251e1b67fb09dd578b364c5339e27c1cfb26eb627666236453d0", 126_796, "Trebuchet MS"),
                ("Trebucbd.ttf", "f65941f9487c0a0a3b7445996ecbbd24466d7ae76ea2a597ced55f438fa63838", 123_828, "Trebuchet MS Bold"),
                ("trebucbi.ttf", "c0a6bdf31f9f2953b2f08a0c1734c892bc825f0fb17c604d420f7acf203a213b", 131_188, "Trebuchet MS Bold Italic"),
                ("trebucit.ttf", "db56fdac7d3ba20b7aededcb6ee86c46687489d17b759e1708ea4e2d21e38410", 139_288, "Trebuchet MS Italic")]),
            ("verdan32.exe", "c1cb61255e363166794e47664e2f21af8e3a26cb6346eb8d2ae2fa85dd5aad96", 351_992, [
                ("Verdana.TTF", "96ed14949ca4b7392cff235b9c41d55c125382abbe0c0d3c2b9dd66897cae0cb", 139_640, "Verdana"),
                ("Verdanab.TTF", "c8f5065ba91680f596af3b0378e2c3e713b95a523be3d56ae185ca2b8f5f0b23", 136_032, "Verdana Bold"),
                ("Verdanai.TTF", "91b59186656f52972531a11433c866fd56e62ec4e61e2621a2dba70c8f19a828", 154_264, "Verdana Italic"),
                ("Verdanaz.TTF", "698e220f48f4a40e77af7eb34958c8fd02f1e18c3ba3f365d93bfa2ed4474c80", 153_324, "Verdana Bold Italic")]),
            ("webdin32.exe", "64595b5abc1080fba8610c5c34fab5863408e806aafe84653ca8575bed17d75a", 185_072, [
                ("Webdings.TTF", "10d099c88521b1b9e380b7690cbe47b54bb19396ca515358cfdc15ac249e2f5d", 118_752, "Webdings")])
        ]
        let downloads = packages.map {
            DependencyDownload(url: URL(string: "https://raw.githubusercontent.com/pushcx/corefonts/\(commit)/\($0.file)")!,
                               fileName: $0.file, sha256: $0.sha256, size: $0.size)
        }
        let files = packages.enumerated().flatMap { index, package in
            package.fonts.map {
                DependencyFile(download: index, member: $0.member, sha256: $0.sha256, size: $0.size,
                               destination: "Fonts/" + $0.member.lowercased(), machine: nil, fontName: $0.name)
            }
        }
        let registry = files.flatMap(fontRegistrations)
        return DependencyItem(
            id: "corefonts", name: "Microsoft Core Fonts", version: "2000",
            summary: "Arial, Arial Black, Andale Mono, Comic Sans MS, Courier New, Georgia, Impact, Times New Roman, Trebuchet MS, Verdana and Webdings.",
            architectures: [],
            license: DependencyLicense(name: "TrueType core fonts for the Web EULA",
                                       url: URL(string: "https://github.com/pushcx/corefonts/blob/\(commit)/LICENSE")!),
            downloads: downloads, method: .files(files), registry: registry,
            checks: files.map { .file($0.destination) } + registry.map { .registry($0) })
    }()

    // MARK: Registry values

    /// The persistent per-prefix load order winetricks also writes; `WINEDLLOVERRIDES`
    /// set by a launch still wins for the DLLs it names.
    private static func override(_ dll: String, mode: String) -> DependencyRegistryValue {
        DependencyRegistryValue(hive: .currentUser, key: #"Software\Wine\DllOverrides"#, name: dll, value: mode)
    }

    /// Winetricks' `w_register_font`: the NT key plus the legacy key Wine also maintains.
    static func fontRegistrations(_ file: DependencyFile) -> [DependencyRegistryValue] {
        guard let name = file.fontName else { return [] }
        let fileName = (file.destination as NSString).lastPathComponent
        return [#"Software\Microsoft\Windows NT\CurrentVersion\Fonts"#, #"Software\Microsoft\Windows\CurrentVersion\Fonts"#].map {
            DependencyRegistryValue(hive: .localMachine, key: $0, name: name + " (TrueType)", value: fileName)
        }
    }
}
