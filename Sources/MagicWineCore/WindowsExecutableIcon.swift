import Foundation

/// Reads icon resources without loading or executing the Windows executable.
internal enum WindowsExecutableIcon {
    static func data(at url: URL, index: Int = 0) -> Data? {
        guard url.isFileURL, let reader = try? Reader(url: url) else { return nil }
        return reader.icon(index: index)
    }

    private final class Reader {
        private struct Section {
            let address: Int
            let virtualSize: Int
            let offset: Int
            let size: Int
        }

        private struct Entry {
            let name: UInt32
            let target: UInt32
            var id: Int? { name & 0x8000_0000 == 0 ? Int(name) : nil }
            var isDirectory: Bool { target & 0x8000_0000 != 0 }
            var offset: Int { Int(target & 0x7fff_ffff) }
        }

        private let handle: FileHandle
        private let fileSize: Int
        private var sections: [Section] = []
        private var resourceOffset = 0
        private var resourceSize = 0
        private var remainingDirectoryEntries = 131_072
        // Bound both individual reads and the final ICO, even for hostile files.
        private let maximumIconSize = 32 * 1024 * 1024

        init(url: URL) throws {
            let handle = try FileHandle(forReadingFrom: url)
            do {
                let size = try handle.seekToEnd()
                guard size <= UInt64(Int.max) else {
                    throw CocoaError(.fileReadTooLarge)
                }
                self.handle = handle
                fileSize = Int(size)
            } catch {
                try? handle.close()
                throw error
            }
        }

        deinit { try? handle.close() }

        private func read(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, count >= 0, count <= maximumIconSize,
                  offset <= fileSize, count <= fileSize - offset else { return nil }
            do {
                try handle.seek(toOffset: UInt64(offset))
                guard let data = try handle.read(upToCount: count), data.count == count else { return nil }
                return data
            } catch {
                return nil
            }
        }

        private func fileOffset(rva: Int, count: Int) -> Int? {
            guard count > 0 else { return nil }
            var result: Int?
            for section in sections where rva >= section.address {
                let delta = rva - section.address
                guard delta < max(section.virtualSize, section.size), delta <= section.size,
                      count <= section.size - delta else { continue }
                let offset = section.offset + delta
                guard offset <= fileSize, count <= fileSize - offset, result == nil else { return nil }
                result = offset
            }
            return result
        }

        private func resource(_ offset: Int, _ count: Int) -> Data? {
            guard offset >= 0, offset <= resourceSize, count <= resourceSize - offset else { return nil }
            return read(resourceOffset + offset, count)
        }

        private func directory(_ offset: Int) -> [Entry]? {
            guard let header = resource(offset, 16) else { return nil }
            let count = Int(header.word(12)) + Int(header.word(14))
            guard count <= 65_536, count <= remainingDirectoryEntries,
                  let bytes = resource(offset + 16, count * 8) else { return nil }
            remainingDirectoryEntries -= count
            var entries: [Entry] = []
            entries.reserveCapacity(count)
            for position in stride(from: 0, to: bytes.count, by: 8) {
                let entry = Entry(name: bytes.dword(position), target: bytes.dword(position + 4))
                if entry.name & 0x8000_0000 != 0 {
                    let nameOffset = Int(entry.name & 0x7fff_ffff)
                    guard let length = resource(nameOffset, 2),
                          nameOffset + 2 <= resourceSize,
                          Int(length.word(0)) * 2 <= resourceSize - nameOffset - 2 else { return nil }
                }
                entries.append(entry)
            }
            return entries
        }

        private func languages(_ entry: Entry) -> [Entry]? {
            guard entry.isDirectory, let entries = directory(entry.offset),
                  !entries.isEmpty, entries.allSatisfy({ !$0.isDirectory }) else { return nil }
            return entries
        }

        private func payload(_ entry: Entry, limit: Int) -> Data? {
            guard !entry.isDirectory, let descriptor = resource(entry.offset, 16) else { return nil }
            let size = Int(descriptor.dword(4))
            guard size > 0, size <= limit,
                  let offset = fileOffset(rva: Int(descriptor.dword(0)), count: size) else { return nil }
            return read(offset, size)
        }

        func icon(index: Int) -> Data? {
            guard let dos = read(0, 64), dos.word(0) == 0x5a4d else { return nil }
            let peOffset = Int(dos.dword(60))
            guard peOffset >= 64, let pe = read(peOffset, 24), pe.dword(0) == 0x0000_4550 else { return nil }
            let sectionCount = Int(pe.word(6))
            let optionalSize = Int(pe.word(20))
            guard (1...96).contains(sectionCount), optionalSize <= 4096,
                  optionalSize >= 2, let optional = read(peOffset + 24, optionalSize) else { return nil }
            let directoriesOffset: Int
            switch optional.word(0) {
            case 0x10b: directoriesOffset = 96
            case 0x20b: directoriesOffset = 112
            default: return nil
            }
            guard optional.count >= directoriesOffset + 24,
                  optional.dword(directoriesOffset - 4) >= 3,
                  let table = read(peOffset + 24 + optionalSize, sectionCount * 40) else { return nil }
            for position in stride(from: 0, to: table.count, by: 40) {
                let section = Section(
                    address: Int(table.dword(position + 12)),
                    virtualSize: Int(table.dword(position + 8)),
                    offset: Int(table.dword(position + 20)),
                    size: Int(table.dword(position + 16))
                )
                guard section.offset <= fileSize, section.size <= fileSize - section.offset else { return nil }
                sections.append(section)
            }
            let resourceRVA = Int(optional.dword(directoriesOffset + 16))
            resourceSize = Int(optional.dword(directoriesOffset + 20))
            guard resourceRVA != 0, resourceSize >= 16,
                  let base = fileOffset(rva: resourceRVA, count: resourceSize) else { return nil }
            resourceOffset = base
            guard let types = directory(0),
                  let groupsType = types.first(where: { $0.id == 14 }), groupsType.isDirectory,
                  let iconsType = types.first(where: { $0.id == 3 }), iconsType.isDirectory,
                  let groups = directory(groupsType.offset),
                  let icons = directory(iconsType.offset) else { return nil }
            let group: Entry
            if index < 0 {
                guard index.magnitude <= 0x7fff_ffff,
                      let selected = groups.first(where: { $0.id == Int(index.magnitude) }) else { return nil }
                group = selected
            } else {
                guard groups.indices.contains(index) else { return nil }
                group = groups[index]
            }
            guard let groupLanguages = languages(group),
                  let language = groupLanguages.first(where: { $0.id == 0 }) ?? groupLanguages.first,
                  let groupData = payload(language, limit: 6 + 256 * 14), groupData.count >= 6,
                  groupData.word(0) == 0, groupData.word(2) == 1 else { return nil }
            let count = Int(groupData.word(4))
            guard (1...256).contains(count), groupData.count == 6 + count * 14 else { return nil }
            var result = Data(count: 6 + count * 16)
            result.replaceSubrange(0..<6, with: [0, 0, 1, 0, UInt8(count & 255), UInt8(count >> 8)])
            var imageOffset = 6 + count * 16
            for frame in 0..<count {
                let position = 6 + frame * 14
                let id = Int(groupData.word(position + 12))
                guard let icon = icons.first(where: { $0.id == id }),
                      let iconLanguages = languages(icon),
                      let iconLanguage = iconLanguages.first(where: { $0.id == language.id })
                        ?? iconLanguages.first(where: { $0.id == 0 }) ?? iconLanguages.first,
                      let image = payload(iconLanguage, limit: maximumIconSize - imageOffset),
                      image.count == Int(groupData.dword(position + 8)) else { return nil }
                let header = 6 + frame * 16
                result.replaceSubrange(header..<(header + 12), with: groupData[position..<(position + 12)])
                let offset = UInt32(imageOffset)
                for byte in 0..<4 {
                    result[header + 12 + byte] = UInt8(truncatingIfNeeded: offset >> (byte * 8))
                }
                result.append(image)
                imageOffset += image.count
            }
            return result
        }
    }
}

private extension Data {
    // Callers establish the byte range before accessing these little-endian fields.
    func word(_ offset: Int) -> UInt16 {
        UInt16(self[offset]) | UInt16(self[offset + 1]) << 8
    }

    func dword(_ offset: Int) -> UInt32 {
        UInt32(word(offset)) | UInt32(word(offset + 2)) << 16
    }
}
