import CryptoKit
import Darwin
import Foundation

/// Wine always searches the DLL directory derived from the *real path of ntdll.so*
/// before WINEDLLPATH. Copying just PE files into a prefix therefore cannot select
/// Unix-backed graphics builtins. This private view copies unchanged loaders
/// and native Wine modules, overlays selected graphics, and links other files
/// to the original runtime. Native @loader_path dependencies stay inside the view.
/// Reference: wine-11.0 dlls/ntdll/unix/loader.c, init_paths/set_dll_path.
enum GraphicsRuntimeView {
    private struct Link: Codable, Equatable {
        let target: String
        let device: Int32
        let inode: UInt64
        let size: Int64
        let modifiedSeconds: Int
        let modifiedNanoseconds: Int
        let changedSeconds: Int
        let changedNanoseconds: Int

        init(_ url: URL, _ status: stat) {
            target = url.path
            device = status.st_dev
            inode = status.st_ino
            size = status.st_size
            modifiedSeconds = status.st_mtimespec.tv_sec
            modifiedNanoseconds = status.st_mtimespec.tv_nsec
            changedSeconds = status.st_ctimespec.tv_sec
            changedNanoseconds = status.st_ctimespec.tv_nsec
        }
    }

    private struct Receipt: Codable, Equatable {
        let schema: Int
        let runtime: String
        let component: String
        let backend: GraphicsBackend
        let loader: String
        let directories: [String]
        let copies: [String: String]
        let hashes: [String: String]
        let links: [String: Link]
    }

    /// The `.graphics-views` directory name `prepare` uses for these inputs right now.
    /// It hashes the exact receipt, so it changes whenever the runtime or provider files do.
    static func identity(executable: URL, component: URL, backend: GraphicsBackend) throws -> String {
        try plan(executable: executable, component: component, backend: backend).identity
    }

    /// The inputs a published view was built from, read without following links.
    static func receiptInputs(of view: URL) -> (runtime: String, component: String, backend: GraphicsBackend)? {
        guard let data = try? readFile(view.appendingPathComponent("installation.json"), maximum: 16 * 1_048_576),
              let receipt = try? JSONDecoder().decode(Receipt.self, from: data) else { return nil }
        return (receipt.runtime, receipt.component, receipt.backend)
    }

    private static func plan(executable: URL, component: URL,
                             backend: GraphicsBackend) throws -> (receipt: Receipt, encoded: Data, identity: String) {
        guard backend == .dxmt || backend == .d3dmetal else { throw failure("A private graphics view is only needed for Metal backends.") }
        guard executable.isFileURL, executable.deletingLastPathComponent().lastPathComponent == "bin" else {
            throw failure("Select a compatible native Wine loader in its runtime's bin directory, not a wrapper or relocated executable.")
        }
        let runtime = executable.deletingLastPathComponent().deletingLastPathComponent().resolvingSymlinksInPath()
        let originalLoader = executable.resolvingSymlinksInPath()
        try requireDirectory(runtime)
        try requireFile(originalLoader, allowHardLinks: true)
        guard originalLoader.path.hasPrefix(runtime.path + "/") else { throw failure("The selected loader escapes its runtime directory.") }
        let provider = backend == .d3dmetal ? component.appendingPathComponent("wine") : component
        try requireDirectory(component)
        try requireDirectory(provider)
        let wineRoots = ["lib/wine", "lib64/wine"].filter {
            FileManager.default.fileExists(atPath: runtime.appendingPathComponent($0 + "/x86_64-unix/ntdll.so").path)
        }
        guard wineRoots.count == 1, let wineRoot = wineRoots.first else {
            throw failure("Expected exactly one x86_64 Wine library root (lib/wine or lib64/wine).")
        }
        let loaderName = "bin/" + executable.lastPathComponent
        var directories = Set<String>(["bin", wineRoot, String(wineRoot.split(separator: "/")[0])])
        var copies: [String: String] = [:]
        var hashes: [String: String] = [:]
        var links: [String: Link] = [:]
        let substitutions: [String]
        if backend == .dxmt {
            substitutions = ["x86_64-windows", "i386-windows"].flatMap { architecture in
                ["d3d10core", "d3d11", "dxgi", "winemetal"].map { architecture + "/" + $0 + ".dll" }
            } + ["x86_64-unix/winemetal.so"]
        } else {
            substitutions = ["d3d11", "d3d12", "dxgi"].flatMap {
                ["x86_64-windows/" + $0 + ".dll", "x86_64-unix/" + $0 + ".so"]
            }
        }
        let replacementNames = Set(substitutions.map { wineRoot + "/" + $0 })
        let loaderNames = Set(["wine", "wine64", "wineloader", executable.lastPathComponent])
        var sourceHashes: [String: String] = [:]
        func addCopy(_ source: URL, _ name: String, within root: URL) throws {
            let resolved = source.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else { throw failure("A private runtime copy escapes its owning directory.") }
            try requireFile(resolved, allowHardLinks: true)
            copies[name] = resolved.path
            if sourceHashes[resolved.path] == nil { sourceHashes[resolved.path] = try hash(resolved, allowHardLinks: true) }
            hashes[name] = sourceHashes[resolved.path]
        }
        func addLink(_ source: URL, _ name: String, within root: URL) throws {
            let resolved = source.resolvingSymlinksInPath()
            guard resolved.path.hasPrefix(root.resolvingSymlinksInPath().path + "/") else {
                throw failure("A runtime/provider link escapes its owning directory: \(source.path).")
            }
            let status = try inspect(resolved)
            let type = status.st_mode & mode_t(S_IFMT)
            guard type == mode_t(S_IFREG) || type == mode_t(S_IFDIR) else { throw failure("Unsupported runtime entry: \(source.path).") }
            links[name] = Link(resolved, status)
        }
        func walk(_ folder: URL, _ relative: String) throws {
            try requireDirectory(folder)
            for entry in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: []).sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                let leaf = entry.lastPathComponent
                guard !leaf.contains(":"), !leaf.contains("\n"), !leaf.contains("\\") else { throw failure("Unsafe runtime filename.") }
                let name = relative.isEmpty ? leaf : relative + "/" + leaf
                if replacementNames.contains(name) { continue }
                let archParent = name.hasPrefix(wineRoot + "/") && name.split(separator: "/").count == 3 &&
                    (leaf.hasSuffix("-windows") || leaf.hasSuffix("-unix"))
                if name == "bin" || name == wineRoot || wineRoot.hasPrefix(name + "/") || archParent {
                    if try inspect(entry).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) {
                        directories.insert(name)
                        try walk(entry, name)
                    } else { throw failure("Wine library directories must not be links: \(entry.path).") }
                } else if relative == "bin", loaderNames.contains(leaf) {
                    // Never retain a distribution's shell/Perl wine wrapper: children must
                    // remain in this exact view, without wrapper environment rewriting.
                    try addCopy(originalLoader, name, within: runtime)
                } else if (relative == wineRoot + "/x86_64-unix" && leaf.hasSuffix(".so")) ||
                            (relative.hasPrefix(wineRoot + "/") && (leaf == "ntdll.so" || leaf == "wine" || leaf == "wine64")) {
                    try addCopy(entry, name, within: runtime)
                } else {
                    try addLink(entry, name, within: runtime)
                }
            }
        }
        try walk(runtime, "")
        for alias in loaderNames { try addCopy(originalLoader, "bin/" + alias, within: runtime) }
        // New Wine obtains its child loader from ntdll_dir/wine. A symlink to the
        // original would silently escape the view on the next CreateProcess.
        if copies[wineRoot + "/x86_64-unix/wine"] == nil {
            try addCopy(originalLoader, wineRoot + "/x86_64-unix/wine", within: runtime)
        }
        for name in substitutions {
            let relative = wineRoot + "/" + name
            directories.insert(wineRoot + "/" + String(name.split(separator: "/")[0]))
            // Apple's Unix modules are aliases of one shared dispatch image. Loading
            // expanded archive copies separately breaks global state and @loader_path
            // framework lookup. The importer verifies their identical bytes.
            let source = backend == .d3dmetal && name.hasPrefix("x86_64-unix/")
                ? component.appendingPathComponent("external/libd3dshared.dylib")
                : provider.appendingPathComponent(name)
            try requireFile(source)
            if backend == .dxmt && name == "x86_64-unix/winemetal.so" {
                // dyld resolves @loader_path from the real image path. A provider
                // symlink cannot find this runtime's @rpath/winemac.so dependency.
                try addCopy(source, relative, within: component)
            } else {
                try addLink(source, relative, within: component)
            }
        }
        let receipt = Receipt(schema: 1, runtime: runtime.path, component: component.path, backend: backend,
                              loader: loaderName, directories: directories.sorted(), copies: copies, hashes: hashes, links: links)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let encoded = try encoder.encode(receipt)
        let identity = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        return (receipt, encoded, identity)
    }

    static func prepare(executable: URL, component: URL, backend: GraphicsBackend,
                        paths: ApplicationPaths) throws -> URL {
        let (receipt, encoded, identity) = try plan(executable: executable, component: component, backend: backend)
        let runtime = URL(fileURLWithPath: receipt.runtime, isDirectory: true)
        let loaderName = receipt.loader, copies = receipt.copies, links = receipt.links
        try requireDirectory(paths.root)
        try requireDirectory(paths.runtimesDirectory)
        let parent = paths.runtimesDirectory.appendingPathComponent(".graphics-views", isDirectory: true)
        // mkdir is atomic: another process may create this shared parent after our
        // initial planning. EEXIST is safe only after lstat confirms a real directory.
        if parent.path.withCString({ mkdir($0, 0o700) }) != 0 {
            let code = errno
            guard code == EEXIST else {
                throw failure("Cannot create the private-loader directory: \(String(cString: strerror(code))).")
            }
        }
        try requireDirectory(parent)
        let destination = parent.appendingPathComponent(identity, isDirectory: true)
        if FileManager.default.fileExists(atPath: destination.path) {
            try validate(destination, receipt: receipt, encoded: encoded)
            return destination.appendingPathComponent(loaderName)
        }
        let stage = parent.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: stage, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stage) }
        for directory in receipt.directories {
            try FileManager.default.createDirectory(at: stage.appendingPathComponent(directory), withIntermediateDirectories: true)
        }
        for (name, source) in copies {
            try Task.checkCancellation()
            let input = URL(fileURLWithPath: source), output = stage.appendingPathComponent(name)
            // Foundation's APFS copy preserves executable permissions, signatures and
            // extended attributes without modifying or resigning the original image.
            try FileManager.default.copyItem(at: input, to: output)
            try DXVKInstallation.preserveQuarantine(from: input, to: output)
            try DXVKInstallation.preserveQuarantine(from: runtime, to: output)
        }
        for (name, link) in links {
            try FileManager.default.createSymbolicLink(atPath: stage.appendingPathComponent(name).path, withDestinationPath: link.target)
        }
        try encoded.write(to: stage.appendingPathComponent("installation.json"), options: .atomic)
        try validate(stage, receipt: receipt, encoded: encoded)
        try Task.checkCancellation()
        let result = stage.path.withCString { from in destination.path.withCString { renamex_np(from, $0, UInt32(RENAME_EXCL)) } }
        if result != 0 {
            let code = errno
            guard code == EEXIST || code == ENOTEMPTY else { throw failure("Cannot publish the private loader: \(String(cString: strerror(code))).") }
            try validate(destination, receipt: receipt, encoded: encoded)
        }
        return destination.appendingPathComponent(loaderName)
    }

    private static func validate(_ root: URL, receipt: Receipt, encoded: Data) throws {
        try requireDirectory(root)
        let receiptURL = root.appendingPathComponent("installation.json")
        try requireFile(receiptURL)
        guard try readFile(receiptURL, maximum: 16 * 1_048_576) == encoded else { throw failure("The private loader receipt was changed.") }
        let expected = Set(receipt.directories).union(receipt.copies.keys).union(receipt.links.keys).union(["installation.json"])
        var actual = Set<String>()
        var enumerationError: Error?
        guard let items = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [], options: [],
            errorHandler: { _, error in enumerationError = error; return false }) else { throw failure("Cannot inspect private loader.") }
        let base = root.standardizedFileURL.path + "/"
        for case let entry as URL in items {
            let path = entry.standardizedFileURL.path
            guard path.hasPrefix(base) else { throw failure("Escaping private loader entry.") }
            let name = String(path.dropFirst(base.count))
            guard expected.contains(name) else { throw failure("Unexpected private loader entry: \(name).") }
            actual.insert(name)
            if let link = receipt.links[name] {
                guard try inspect(entry).st_mode & mode_t(S_IFMT) == mode_t(S_IFLNK),
                      try FileManager.default.destinationOfSymbolicLink(atPath: entry.path) == link.target else { throw failure("A private loader link changed: \(name).") }
                let target = URL(fileURLWithPath: link.target)
                guard target.resolvingSymlinksInPath().path == target.path,
                      Link(target, try inspect(target)) == link else { throw failure("The original runtime/provider changed: \(name).") }
            } else if let expectedHash = receipt.hashes[name] {
                // Wine creates hard-linked child launchers while running. Their content
                // remains pinned; reject changed bytes rather than legitimate new names.
                try requireFile(entry, allowHardLinks: true)
                guard try hash(entry, allowHardLinks: true) == expectedHash else { throw failure("A private loader copy changed: \(name).") }
            } else if name != "installation.json" { try requireDirectory(entry) }
        }
        if let enumerationError { throw enumerationError }
        guard actual == expected else { throw failure("The private loader is incomplete.") }
    }

    private static func inspect(_ url: URL) throws -> stat {
        var status = stat()
        guard url.isFileURL, url.path.withCString({ lstat($0, &status) }) == 0 else { throw failure("Cannot inspect \(url.path).") }
        return status
    }
    private static func requireDirectory(_ url: URL) throws {
        guard try inspect(url).st_mode & mode_t(S_IFMT) == mode_t(S_IFDIR) else { throw failure("Expected an ordinary directory: \(url.path).") }
    }
    private static func requireFile(_ url: URL, allowHardLinks: Bool = false) throws {
        let status = try inspect(url)
        guard status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), (allowHardLinks || status.st_nlink == 1), status.st_size > 0,
              status.st_size <= 128 * 1_048_576 else { throw failure("Expected an ordinary bounded runtime file: \(url.path).") }
    }
    private static func openFile(_ url: URL, allowHardLinks: Bool = false) throws -> FileHandle {
        try requireFile(url, allowHardLinks: allowHardLinks)
        let descriptor = url.path.withCString { open($0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK) }
        guard descriptor >= 0 else { throw failure("Cannot safely open runtime file.") }
        var status = stat()
        guard fstat(descriptor, &status) == 0, status.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), (allowHardLinks || status.st_nlink == 1) else {
            close(descriptor)
            throw failure("Runtime file changed while opening.")
        }
        return FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
    }
    private static func readFile(_ url: URL, maximum: Int) throws -> Data {
        let handle = try openFile(url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: maximum + 1) ?? Data()
        guard data.count <= maximum else { throw failure("Runtime metadata exceeds its safety limit.") }
        return data
    }
    private static func hash(_ url: URL, allowHardLinks: Bool = false) throws -> String {
        let handle = try openFile(url, allowHardLinks: allowHardLinks)
        defer { try? handle.close() }
        var sha = SHA256(), count = 0
        while let data = try handle.read(upToCount: 1_048_576), !data.isEmpty {
            try Task.checkCancellation()
            count += data.count
            guard count <= 128 * 1_048_576 else { throw failure("Runtime file exceeds its safety limit.") }
            sha.update(data: data)
        }
        return sha.finalize().map { String(format: "%02x", $0) }.joined()
    }
    private static func failure(_ message: String) -> MagicWineError { .setup("Graphics runtime view: " + message) }
}
