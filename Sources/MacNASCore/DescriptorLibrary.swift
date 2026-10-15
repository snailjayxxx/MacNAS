import Foundation
import Darwin

public enum FixtureFileKind: String, Codable { case directory, file }
public struct FixtureFileEntry: Codable, Equatable {
    public let name: String
    public let relativePath: String
    public let kind: FixtureFileKind
    public let bytes: Int64?
    public let modifiedAt: Date
}
public struct FixtureTextPreview: Codable, Equatable {
    public let libraryID: String
    public let relativePath: String
    public let text: String
    public let utf8Bytes: Int
}

/// Read-only, descriptor-relative access. Only the typed fixture API can publish this content.
final class DescriptorLibrary: @unchecked Sendable {
    private let rootURL: URL
    private let descriptor: Int32
    private let device: dev_t
    private let inode: ino_t
    private static let directoryFlags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK

    init(mountRoot: URL, relativeRoot: String = "") throws {
        let mount = try Self.absoluteDirectory(mountRoot)
        defer { close(mount) }
        let mountStat = try Self.attributes(mount)
        let opened = try Self.descend(from: mount, relative: relativeRoot, device: mountStat.st_dev)
        let info: stat
        do { info = try Self.attributes(opened) } catch { close(opened); throw error }
        descriptor = opened; device = info.st_dev; inode = info.st_ino
        rootURL = relativeRoot.isEmpty ? mountRoot : mountRoot.appendingPathComponent(relativeRoot, isDirectory: true)
    }
    deinit { close(descriptor) }

    private static func attributes(_ fd: Int32) throws -> stat {
        var result = stat()
        try require(fstat(fd, &result) == 0, .unsafeFile)
        return result
    }
    private static func components(_ path: String, allowEmpty: Bool) throws -> [String] {
        if path.isEmpty && allowEmpty { return [] }
        try SafeFS.relative(path)
        let parts = path.split(separator: "/").map(String.init)
        try require(parts.count <= 128 && path.utf8.count <= 4096, .budgetExceeded)
        return parts
    }
    private static func absoluteDirectory(_ url: URL) throws -> Int32 {
        try require(url.isFileURL && url.query == nil && url.fragment == nil && url.path.hasPrefix("/"), .unsafePath)
        let parts = try components(String(url.path.dropFirst()), allowEmpty: true)
        var fd = open("/", directoryFlags)
        guard fd >= 0 else { throw NASError.unsafeFile }
        do {
            for part in parts {
                let next = openat(fd, part, directoryFlags)
                guard next >= 0 else { throw NASError.unsafeFile }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    private static func descend(from parent: Int32, relative: String, device: dev_t) throws -> Int32 {
        let parts = try components(relative, allowEmpty: true)
        // A fresh open description prevents repeated listings from sharing directory offsets.
        var fd = openat(parent, ".", directoryFlags)
        guard fd >= 0 else { throw NASError.unsafeFile }
        do {
            for part in parts {
                let next = openat(fd, part, directoryFlags)
                guard next >= 0 else { throw NASError.unsafeFile }
                close(fd); fd = next
                let info = try attributes(fd)
                try require(info.st_dev == device && (info.st_mode & S_IFMT) == S_IFDIR, .unsafeFile)
            }
            return fd
        } catch { close(fd); throw error }
    }
    private func validateRoot() throws {
        let current = try Self.absoluteDirectory(rootURL)
        defer { close(current) }
        let info = try Self.attributes(current)
        try require(info.st_dev == device && info.st_ino == inode && info.st_nlink > 0, .staleState)
    }
    private static func sameIdentity(_ left: stat, _ right: stat) -> Bool {
        left.st_dev == right.st_dev && left.st_ino == right.st_ino && left.st_mode == right.st_mode
    }
    private static func sameContentStamp(_ left: stat, _ right: stat) -> Bool {
        sameIdentity(left, right) && left.st_size == right.st_size && left.st_nlink == right.st_nlink
        && left.st_mtimespec.tv_sec == right.st_mtimespec.tv_sec && left.st_mtimespec.tv_nsec == right.st_mtimespec.tv_nsec
        && left.st_ctimespec.tv_sec == right.st_ctimespec.tv_sec && left.st_ctimespec.tv_nsec == right.st_ctimespec.tv_nsec
    }
    private func validateDirectory(_ fd: Int32, relative: String) throws {
        let current = try Self.descend(from: descriptor, relative: relative, device: device)
        defer { close(current) }
        try require(Self.sameIdentity(try Self.attributes(fd), try Self.attributes(current)), .staleState)
        try validateRoot()
    }
    static func checkNames(_ names: [String]) throws {
        var keys: Set<String> = []
        for name in names {
            try SafeFS.relative(name); try require(!name.contains("/"), .unsafePath)
            let key = name.precomposedStringWithCanonicalMapping.lowercased()
            try require(keys.insert(key).inserted, .collision)
        }
    }
    func list(relative: String = "", maximumEntries: Int = 1000) throws -> [FixtureFileEntry] {
        try require((1...1000).contains(maximumEntries), .budgetExceeded)
        try validateRoot()
        let fd = try Self.descend(from: descriptor, relative: relative, device: device)
        // fdopendir owns fd on success.
        guard let stream = fdopendir(fd) else { close(fd); throw NASError.unsafeFile }
        defer { closedir(stream) }
        let before = try Self.attributes(fd)
        var entries: [FixtureFileEntry] = [], nameBytes = 0
        while true {
            errno = 0
            guard let entry = readdir(stream) else {
                try require(errno == 0, .unsafeFile); break
            }
            let nameCapacity = Int(entry.pointee.d_namlen) + 1
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: nameCapacity) { String(validatingCString: $0) }
            }
            guard let name else { throw NASError.unsafeFile }
            if name == "." || name == ".." { continue }
            nameBytes += name.utf8.count
            try require(entries.count < maximumEntries && nameBytes <= 128 * 1024, .budgetExceeded)
            try Self.checkNames([name])
            var info = stat()
            try require(fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 && info.st_dev == device, .unsafeFile)
            let kind = info.st_mode & S_IFMT
            try require(kind == S_IFDIR || (kind == S_IFREG && info.st_nlink == 1), .unsafeFile)
            let path = relative.isEmpty ? name : relative + "/" + name
            entries.append(FixtureFileEntry(name: name, relativePath: path, kind: kind == S_IFDIR ? .directory : .file,
                bytes: kind == S_IFREG ? Int64(info.st_size) : nil,
                modifiedAt: Date(timeIntervalSince1970: Double(info.st_mtimespec.tv_sec) + Double(info.st_mtimespec.tv_nsec) / 1_000_000_000)))
        }
        try Self.checkNames(entries.map(\.name))
        try require(Self.sameContentStamp(before, try Self.attributes(fd)), .staleState)
        try validateDirectory(fd, relative: relative)
        return entries.sorted { $0.name < $1.name }
    }
    /// The hook is internal and used only to deterministically exercise filesystem races in tests.
    func read(relative: String, maximumBytes: Int = 65536, afterOpen: (() throws -> Void)? = nil) throws -> Data {
        try require((1...1_048_576).contains(maximumBytes), .budgetExceeded)
        let parts = try Self.components(relative, allowEmpty: false)
        let name = parts.last!, parent = parts.dropLast().joined(separator: "/")
        try validateRoot()
        let directory = try Self.descend(from: descriptor, relative: parent, device: device)
        defer { close(directory) }
        let fd = openat(directory, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard fd >= 0 else { throw NASError.unsafeFile }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        let before = try Self.attributes(fd)
        try require(before.st_dev == device && (before.st_mode & S_IFMT) == S_IFREG && before.st_nlink == 1, .unsafeFile)
        try require(before.st_size >= 0 && before.st_size <= maximumBytes, .budgetExceeded)
        try afterOpen?()
        let data = try file.read(upToCount: maximumBytes + 1) ?? Data()
        try require(data.count <= maximumBytes, .budgetExceeded)
        var current = stat()
        try require(fstatat(directory, name, &current, AT_SYMLINK_NOFOLLOW) == 0, .staleState)
        try require(Self.sameContentStamp(before, try Self.attributes(fd)) && Self.sameContentStamp(before, current)
                    && data.count == before.st_size, .staleState)
        try validateDirectory(directory, relative: parent)
        return data
    }
}

final class FixtureContentRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var readers: [String: (UUID, DescriptorLibrary)] = [:]
    func register(_ reader: DescriptorLibrary, permit: FixtureVolumePermit) {
        lock.lock(); defer { lock.unlock() }
        readers[permit.reference.libraryID] = (permit.approvalID, reader)
    }
    func reader(_ permit: FixtureVolumePermit) throws -> DescriptorLibrary {
        lock.lock(); defer { lock.unlock() }
        guard let value = readers[permit.reference.libraryID], value.0 == permit.approvalID else { throw NASError.denied }
        return value.1
    }
    func revoke(_ libraryID: String) {
        lock.lock(); defer { lock.unlock() }; readers.removeValue(forKey: libraryID)
    }
}
