import Foundation
import Darwin
import CryptoKit

/// Host-local synthetic fixture metadata. Paths and grants are never supplied by desktop clients.
struct RecycleSlotRegistration: Codable, Equatable {
    let id: UUID
    let inode: String
}
struct RecycleVaultRegistration: Codable, Equatable {
    var version = 1
    let instanceID: UUID
    let generation: Int64
    let databaseName: String
    let hostID: String
    let ownerUserHex: String
    let libraryID: String
    let volumeID: UUID
    let vaultID: UUID
    let device: String
    let libraryInode: String
    let vaultInode: String
    let slots: [RecycleSlotRegistration]
}

/// A directory reached one component at a time, retaining both its FD and the approved absolute name.
/// Every operation reopens that name to reject renames/replacements of any ancestor.
final class RecycleDirectory {
    static let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK
    let fd: Int32
    let url: URL
    let identity: FileEffectStamp

    static func stamp(_ value: stat) -> FileEffectStamp {
        .init(device: String(UInt64(UInt32(bitPattern: value.st_dev))), inode: String(value.st_ino),
              mode: Int64(value.st_mode), uid: Int64(value.st_uid), links: Int64(value.st_nlink), bytes: Int64(value.st_size),
              mtimeSeconds: String(value.st_mtimespec.tv_sec), mtimeNanos: Int64(value.st_mtimespec.tv_nsec),
              ctimeSeconds: String(value.st_ctimespec.tv_sec), ctimeNanos: Int64(value.st_ctimespec.tv_nsec))
    }
    static func sameIdentity(_ a: FileEffectStamp, _ b: FileEffectStamp) -> Bool {
        a.device == b.device && a.inode == b.inode && a.mode == b.mode && a.uid == b.uid && a.links > 0 && b.links > 0
    }
    static func sameStamp(_ a: FileEffectStamp, _ b: FileEffectStamp, allowingRenameCTime: Bool = false) -> Bool {
        sameIdentity(a, b) && a.links == b.links && a.bytes == b.bytes && a.mtimeSeconds == b.mtimeSeconds
        && a.mtimeNanos == b.mtimeNanos && (allowingRenameCTime || (a.ctimeSeconds == b.ctimeSeconds && a.ctimeNanos == b.ctimeNanos))
    }
    static func openAbsolute(_ url: URL) throws -> Int32 {
        try require(url.isFileURL && url.query == nil && url.fragment == nil && url.path.hasPrefix("/"), .unsafePath)
        let path = String(url.path.dropFirst())
        if !path.isEmpty { try FileEffectMetadata.path(path) }
        var fd = open("/", flags)
        guard fd >= 0 else { throw NASError.unsafeFile }
        do {
            for part in path.split(separator: "/") {
                let next = openat(fd, String(part), flags)
                guard next >= 0 else { throw NASError.unsafeFile }
                close(fd); fd = next
            }
            return fd
        } catch { close(fd); throw error }
    }
    init(_ url: URL, privateMode: Bool = false) throws {
        let opened = try Self.openAbsolute(url)
        do {
            let stamp = Self.stamp(try TransferIO.attributes(opened)); try stamp.validate(directory: true)
            if privateMode { try require(stamp.mode & 0o7777 == 0o700 && stamp.uid == Int64(getuid()), .unsafeFile) }
            fd = opened; self.url = url; identity = stamp
        } catch { close(opened); throw error }
    }
    deinit { close(fd) }
    func validate(privateMode: Bool = false) throws {
        let named = try Self.openAbsolute(url); defer { close(named) }
        let current = Self.stamp(try TransferIO.attributes(fd)), path = Self.stamp(try TransferIO.attributes(named))
        try require(Self.sameIdentity(identity, current) && Self.sameIdentity(identity, path), .staleState)
        if privateMode { try require(current.mode & 0o7777 == 0o700 && current.uid == Int64(getuid()), .unsafeFile) }
    }
    func names(maximum: Int) throws -> [String] {
        try validate(); let fresh = openat(fd, ".", Self.flags)
        guard fresh >= 0 else { throw NASError.unsafeFile }
        guard let directory = fdopendir(fresh) else { close(fresh); throw NASError.unsafeFile }
        defer { closedir(directory) }
        var result: [String] = []
        errno = 0
        while let entry = readdir(directory) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(entry.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            try FixtureFileOperationIntent.component(name)
            result.append(name); try require(result.count <= maximum, .budgetExceeded); errno = 0
        }
        try require(errno == 0, .unsafeFile); try validate(); return result
    }
    func child(_ name: String, create: Bool = false, privateMode: Bool = false) throws -> RecycleDirectory {
        try FixtureFileOperationIntent.component(name); try validate()
        if create {
            let result = mkdirat(fd, name, 0o700)
            try require(result == 0, errno == EEXIST ? .collision : .unsafeFile)
        }
        let result = try RecycleDirectory(url.appendingPathComponent(name), privateMode: privateMode)
        try require(result.identity.device == identity.device, .unsupported)
        try validate(); return result
    }
    func parent(of path: String) throws -> (RecycleDirectory, String) {
        try FileEffectMetadata.path(path)
        let parts = path.split(separator: "/").map(String.init)
        var directory = self
        for part in parts.dropLast() { directory = try directory.child(part) }
        return (directory, parts.last!)
    }
    func named(_ name: String) throws -> FileEffectStamp? {
        try FixtureFileOperationIntent.component(name); try validate(); var info = stat()
        if fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) != 0 {
            if errno == ENOENT { return nil }; throw NASError.unsafeFile
        }
        return Self.stamp(info)
    }
    func synchronize() throws {
        try validate(); try require(fsync(fd) == 0, .unsafeFile); try validate()
    }
    func privateFile(_ name: String, maximum: Int) throws -> Data {
        try FixtureFileOperationIntent.component(name); try validate()
        let opened = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard opened >= 0 else { throw NASError.unsafeFile }; defer { close(opened) }
        let before = Self.stamp(try TransferIO.attributes(opened)); try before.validate(directory: false)
        try require(before.mode & 0o7777 == 0o600 && before.uid == Int64(getuid()) && before.bytes <= maximum, .unsafeFile)
        var bytes = Data(count: Int(before.bytes))
        try bytes.withUnsafeMutableBytes { buffer in
            var offset = 0
            while offset < buffer.count {
                let loaded = pread(opened, buffer.baseAddress!.advanced(by: offset), buffer.count - offset, off_t(offset))
                if loaded < 0 && errno == EINTR { continue }
                try require(loaded > 0, .unsafeFile); offset += loaded
            }
        }
        guard let named = try named(name) else { throw NASError.staleState }
        try require(Self.sameStamp(before, named) && Self.sameStamp(before, Self.stamp(try TransferIO.attributes(opened))), .staleState)
        try validate(); return bytes
    }
}

/// This lock never deletes its file or any payload. Its named inode is checked before every effect.
final class RecycleVaultLock {
    private let file: Int32
    private let vault: RecycleDirectory
    private let stamp: FileEffectStamp
    init(vault: RecycleDirectory) throws {
        try vault.validate(privateMode: true)
        let opened = openat(vault.fd, "execution.lock", O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard opened >= 0 else { throw NASError.unsafeFile }
        do {
            let info = RecycleDirectory.stamp(try TransferIO.attributes(opened)); try info.validate(directory: false)
            try require(info.bytes == 0 && info.mode & 0o7777 == 0o600 && info.uid == Int64(getuid()), .unsafeFile)
            try require(flock(opened, LOCK_EX | LOCK_NB) == 0, .busy)
            file = opened; self.vault = vault; stamp = info
            try validate()
        } catch { close(opened); throw error }
    }
    deinit { flock(file, LOCK_UN); close(file) }
    func validate() throws {
        try vault.validate(privateMode: true)
        guard let named = try vault.named("execution.lock") else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(stamp, named)
                    && RecycleDirectory.sameStamp(stamp, RecycleDirectory.stamp(try TransferIO.attributes(file))), .staleState)
    }
}

/// Retains the original source FD. Destruction only closes FDs: it never unlinks an unknown or moved object.
final class RecyclePinnedFile {
    let file: Int32
    let source: RecycleDirectory
    let name: String
    let before: FileEffectStamp
    let sha256: String
    init(source: RecycleDirectory, name: String, validate: () throws -> Void) throws {
        try FixtureFileOperationIntent.component(name); try validate(); try source.validate()
        let opened = openat(source.fd, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        guard opened >= 0 else { throw NASError.unsafeFile }
        do {
            let stamp = RecycleDirectory.stamp(try TransferIO.attributes(opened)); try stamp.validate(directory: false)
            try require((0...DurableFileEffectJournal.fileBytes).contains(stamp.bytes), .budgetExceeded)
            try require(stamp.device == source.identity.device, .unsupported)
            let digest = try Self.digest(opened, bytes: stamp.bytes, validate: validate)
            guard let named = try source.named(name) else { throw NASError.staleState }
            try require(RecycleDirectory.sameStamp(stamp, named)
                        && RecycleDirectory.sameStamp(stamp, RecycleDirectory.stamp(try TransferIO.attributes(opened))), .staleState)
            file = opened; self.source = source; self.name = name; before = stamp; sha256 = digest
        } catch { close(opened); throw error }
    }
    deinit { close(file) }
    static func digest(_ fd: Int32, bytes: Int64, validate: () throws -> Void) throws -> String {
        try require((0...DurableFileEffectJournal.fileBytes).contains(bytes), .budgetExceeded)
        var hash = SHA256(), offset: Int64 = 0
        while offset < bytes {
            try validate(); var block = Data(count: Int(min(32768, bytes - offset)))
            try block.withUnsafeMutableBytes { buffer in
                var loaded = 0
                while loaded < buffer.count {
                    let count = pread(fd, buffer.baseAddress!.advanced(by: loaded), buffer.count - loaded, off_t(offset) + off_t(loaded))
                    if count < 0 && errno == EINTR { continue }
                    try require(count > 0 && count <= buffer.count - loaded, .unsafeFile); loaded += count
                }
            }
            hash.update(data: block); offset += Int64(block.count)
        }
        try validate(); return TransferEncoding.digest(hash)
    }
    func validateBefore(validate: () throws -> Void) throws {
        try validate(); try source.validate(); guard let named = try source.named(name) else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(before, named)
                    && RecycleDirectory.sameStamp(before, RecycleDirectory.stamp(try TransferIO.attributes(file))), .staleState)
    }
}

/// A fixed synthetic layout outside the browsable library. The registration binds both roots to one DB/instance.
final class RecycleVault {
    static let registrationPath = "host-binding/recycle-registration.json"
    static let fixturePath = "host-binding/recycle-fixture"
    let registration: RecycleVaultRegistration
    let library: RecycleDirectory
    let vault: RecycleDirectory
    let entries: RecycleDirectory
    private let marker: Data

    static func requireLabRoot(_ root: URL) throws {
        guard let path = ProcessInfo.processInfo.environment["MACNAS_TESTLAB"] else { throw NASError.denied }
        let lab = URL(fileURLWithPath: path).standardizedFileURL
        try require(lab.path.hasPrefix("/Volumes/MacNAS-Dev/MacNAS-Workspace/TestLab/")
                    && root.standardizedFileURL == root && root.path.hasPrefix(lab.path + "/"), .denied)
        // Descriptor traversal also rejects a substituted TestLab/instance ancestor.
        _ = try RecycleDirectory(root)
    }
    static func create(root: URL, store: StateStore, userID: Data, libraryID: String = "recycle-fixture") throws -> RecycleVaultRegistration {
        try requireLabRoot(root); try FileEffectMetadata.subject(userID); try FileEffectMetadata.text(libraryID, maximum: 128)
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try FileEffectMetadata.text(binding.hostID, maximum: 256)
        try require(config.schemaVersion == 1 && identity.kind == "synthetic-prototype" && identity.schemaVersion == 1 && identity.generation >= 0
                    && binding.databaseName == store.databaseName && binding.mode == "synthetic_development"
                    && config.users.filter({ Data($0.id.utf8) == userID }).map(\.role) == ["administrator"], .denied)
        try store.validate(expectedVersion: 4)
        try require(try !store.hasRecycleHistory(), .unsupported)
        let host = try RecycleDirectory(root.appendingPathComponent("host-binding"))
        try require(try host.named("recycle-registration.json") == nil, .collision)
        let fixture = try host.child("recycle-fixture", create: true, privateMode: true)
        let library = try fixture.child("library", create: true, privateMode: true)
        let vault = try fixture.child("vault", create: true, privateMode: true)
        let entries = try vault.child("entries", create: true, privateMode: true)
        var slots: [RecycleSlotRegistration] = []
        for _ in 0..<64 {
            let id = UUID(), slot = try entries.child(id.uuidString.lowercased(), create: true, privateMode: true)
            try slot.synchronize(); slots.append(.init(id: id, inode: slot.identity.inode))
        }
        let value = RecycleVaultRegistration(instanceID: identity.instanceID, generation: Int64(identity.generation), databaseName: store.databaseName,
            hostID: binding.hostID, ownerUserHex: FileEffectMetadata.hex(userID), libraryID: libraryID, volumeID: UUID(), vaultID: UUID(), device: vault.identity.device,
            libraryInode: library.identity.inode, vaultInode: vault.identity.inode, slots: slots)
        let marker = try FileEffectMetadata.encoded(value)
        try require(marker.count <= 8192, .budgetExceeded)
        try writeNew(marker, directory: vault, name: "binding.json")
        try writeNew(Data(), directory: vault, name: "execution.lock")
        try entries.synchronize(); try vault.synchronize(); try library.synchronize(); try fixture.synchronize()
        try writeNew(marker, directory: host, name: "recycle-registration.json"); try host.synchronize()
        return value
    }
    private static func writeNew(_ data: Data, directory: RecycleDirectory, name: String) throws {
        let fd = openat(directory.fd, name, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NASError.collision }; defer { close(fd) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let n = write(fd, bytes.baseAddress!.advanced(by: offset), data.count - offset)
                if n < 0 && errno == EINTR { continue }
                try require(n > 0, .unsafeFile); offset += n
            }
        }
        try require(fsync(fd) == 0, .unsafeFile)
    }
    /// Caller must validate a new live grant before constructing this object, including after restart.
    init(root: URL, registration: RecycleVaultRegistration) throws {
        try Self.requireLabRoot(root)
        let fixture = root.appendingPathComponent(Self.fixturePath)
        library = try RecycleDirectory(fixture.appendingPathComponent("library"), privateMode: true)
        vault = try RecycleDirectory(fixture.appendingPathComponent("vault"), privateMode: true)
        entries = try vault.child("entries", privateMode: true)
        self.registration = registration; marker = try FileEffectMetadata.encoded(registration)
        try validate()
    }
    func validate() throws {
        try library.validate(privateMode: true); try vault.validate(privateMode: true); try entries.validate(privateMode: true)
        try require(registration.version == 1 && registration.device == library.identity.device && registration.device == vault.identity.device
                    && registration.libraryInode == library.identity.inode && registration.vaultInode == vault.identity.inode, .staleState)
        try require(Set(try vault.names(maximum: 3)) == ["binding.json", "execution.lock", "entries"], .unsupported)
        try require(registration.slots.count == 64 && Set(registration.slots.map(\.id)).count == 64, .invalidSchema)
        try require(Set(try entries.names(maximum: 64)) == Set(registration.slots.map { $0.id.uuidString.lowercased() }), .unsupported)
        try require(try vault.privateFile("binding.json", maximum: 8192) == marker, .staleState)
    }
    func lock() throws -> RecycleVaultLock { try validate(); return try RecycleVaultLock(vault: vault) }
    func slot(_ payloadID: UUID) throws -> RecycleDirectory {
        try validate()
        guard let expected = registration.slots.first(where: { $0.id == payloadID }) else { throw NASError.denied }
        let directory = try entries.child(payloadID.uuidString.lowercased(), privateMode: true)
        try require(directory.identity.inode == expected.inode, .staleState); return directory
    }
}
