import Foundation
import Darwin

public enum FixtureFileKind: String, Codable, Sendable { case directory, file }
public struct FixtureFileEntry: Codable, Equatable, Sendable {
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

/// Descriptor-relative fixture access. Mutation requires a separate explicit write approval and one-use plan.
final class DescriptorLibrary: @unchecked Sendable {
    let identity = UUID()
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
    func validatePage(_ stamp: DirectoryStamp, relative: String) throws {
        try validateRoot()
        let fd=try Self.descend(from:descriptor,relative:relative,device:device); defer { close(fd) }
        try require(DirectoryStamp(try Self.attributes(fd))==stamp, .staleState)
        try validateDirectory(fd,relative:relative)
    }
    /// Bounded full scan with only pageSize+1 candidate DTOs and bounded collision digests.
    /// Metadata is live; directory stamps detect membership changes, not file-content snapshots.
    func page(relative: String="", after: String?=nil, expected: DirectoryStamp?=nil, size: Int=50,
              budget: DirectoryScanBudget=DirectoryScanBudget(), now: () -> TimeInterval={ProcessInfo.processInfo.systemUptime},
              afterScan: (() throws -> Void)?=nil) throws -> DirectorySlice {
        try require((1...100).contains(size) && budget.entries>0 && budget.nameBytes>0 && budget.seconds>0, .invalidSchema)
        let deadline=now()+budget.seconds
        try validateRoot()
        let fd=try Self.descend(from:descriptor,relative:relative,device:device)
        guard let stream=fdopendir(fd) else { close(fd); throw NASError.unsafeFile }
        defer { closedir(stream) }
        let before=DirectoryStamp(try Self.attributes(fd))
        if let expected { try require(before==expected, .staleState) }
        var names=DirectoryNameBudget(), selected: [(entry:FixtureFileEntry,stamp:DirectoryStamp)]=[]
        while true {
            try require(now()<deadline, .timedOut)
            errno=0
            guard let record=readdir(stream) else { try require(errno==0, .unsafeFile); break }
            let count=Int(record.pointee.d_namlen)+1
            let name=withUnsafePointer(to:&record.pointee.d_name) { $0.withMemoryRebound(to:CChar.self,capacity:count) { String(validatingCString:$0) } }
            guard let name else { throw NASError.unsafeFile }
            if name=="." || name==".." { continue }
            try names.add(name,budget:budget)
            var info=stat()
            try require(fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0, .staleState)
            let kind=info.st_mode & S_IFMT
            try require(info.st_dev==device && (kind==S_IFDIR || (kind==S_IFREG && info.st_nlink==1)), .unsafeFile)
            let path=relative.isEmpty ? name:relative+"/"+name
            try require(path.utf8.count<=4096 && path.split(separator:"/").count<=128, .budgetExceeded)
            if let after, !after.utf8.lexicographicallyPrecedes(name.utf8) { continue }
            if selected.count==size+1,let last=selected.last, !name.utf8.lexicographicallyPrecedes(last.entry.name.utf8) { continue }
            let entry=FixtureFileEntry(name:name,relativePath:path,kind:kind==S_IFDIR ? .directory:.file,
                bytes:kind==S_IFREG ? Int64(info.st_size):nil,
                modifiedAt:Date(timeIntervalSince1970:Double(info.st_mtimespec.tv_sec)+Double(info.st_mtimespec.tv_nsec)/1_000_000_000))
            let index=selected.firstIndex { name.utf8.lexicographicallyPrecedes($0.entry.name.utf8) } ?? selected.endIndex
            selected.insert((entry,DirectoryStamp(info)),at:index)
            if selected.count>size+1 { selected.removeLast() }
        }
        try afterScan?()
        for candidate in selected {
            var current=stat()
            try require(fstatat(fd,candidate.entry.name,&current,AT_SYMLINK_NOFOLLOW)==0 && DirectoryStamp(current)==candidate.stamp, .staleState)
        }
        try require(DirectoryStamp(try Self.attributes(fd))==before, .staleState)
        try validateDirectory(fd,relative:relative)
        try require(now()<deadline, .timedOut)
        return DirectorySlice(entries:selected.prefix(size).map(\.entry),stamp:before,hasMore:selected.count>size)
    }
    func prepareMutation(_ intent:FixtureFileOperationIntent) throws ->DescriptorMutation {
        try validateRoot()
        let fd=try Self.descend(from:descriptor,relative:intent.parentPath,device:device)
        var retained=false;defer{if !retained {close(fd)}}
        let scan=openat(fd,".",Self.directoryFlags)
        guard scan>=0 else{throw NASError.unsafeFile}
        guard let stream=fdopendir(scan) else{close(scan);throw NASError.unsafeFile}
        defer{closedir(stream)}
        let before=DirectoryStamp(try Self.attributes(fd)),deadline=ProcessInfo.processInfo.systemUptime+5
        let key=intent.name.precomposedStringWithCanonicalMapping.lowercased()
        var names=DirectoryNameBudget(),conflict=false,source:DirectoryStamp?
        while true {
            try require(ProcessInfo.processInfo.systemUptime<deadline,.timedOut)
            errno=0;guard let record=readdir(stream) else{try require(errno==0,.unsafeFile);break}
            let count=Int(record.pointee.d_namlen)+1
            let raw=withUnsafePointer(to:&record.pointee.d_name){$0.withMemoryRebound(to:CChar.self,capacity:count){String(validatingCString:$0)}}
            guard let name=raw else{throw NASError.unsafeFile}
            if name=="." || name==".." {continue}
            try names.add(name,budget:DirectoryScanBudget())
            var info=stat();try require(fstatat(fd,name,&info,AT_SYMLINK_NOFOLLOW)==0,.staleState)
            let kind=info.st_mode & S_IFMT
            try require(info.st_dev==device && (kind==S_IFDIR || kind==S_IFREG && info.st_nlink==1),.unsafeFile)
            if name.precomposedStringWithCanonicalMapping.lowercased()==key {conflict=true}
            if let wanted=intent.sourceName,Data(name.utf8)==Data(wanted.utf8) {source=DirectoryStamp(info)}
        }
        if intent.kind == .rename {try require(source != nil,.staleState)}
        try require(DirectoryStamp(try Self.attributes(fd))==before,.staleState)
        try validateDirectory(fd,relative:intent.parentPath)
        let unchanged=intent.sourceName.map{Data($0.utf8)==Data(intent.name.utf8)} ?? false
        retained=true
        return DescriptorMutation(readerID:identity,descriptor:fd,parent:before,source:source,intent:intent,state:unchanged ? "unchanged":conflict ? "conflict":"ready")
    }
    func validateMutation(_ plan:DescriptorMutation) throws {
        try require(plan.readerID==identity,.denied)
        try validateDirectory(plan.descriptor,relative:plan.intent.parentPath)
        try require(DirectoryStamp(try Self.attributes(plan.descriptor))==plan.parent,.staleState)
        if let name=plan.intent.sourceName,let expected=plan.source {
            var info=stat();try require(fstatat(plan.descriptor,name,&info,AT_SYMLINK_NOFOLLOW)==0 && DirectoryStamp(info)==expected,.staleState)
        }
    }
    func applyMutation(_ plan:DescriptorMutation,beforeMutation:()throws->Void={},afterMutation:()throws->Void={}) throws {
        var applied=false
        do {
            try require(plan.state=="ready",.collision)
            try beforeMutation();try validateMutation(plan)
            let fd=plan.descriptor,intent=plan.intent
            let result:Int32
            if intent.kind == .createDirectory {result=mkdirat(fd,intent.name,0o700)}
            else {result=renameatx_np(fd,intent.sourceName!,fd,intent.name,UInt32(RENAME_EXCL))}
            if result != 0 {
                if errno==EEXIST || errno==ENOTEMPTY {throw NASError.collision}
                if errno==ENOTSUP {throw NASError.unsupported}
                throw NASError.unsafeFile
            }
            applied=true
            try afterMutation()
            try validateDirectory(fd,relative:intent.parentPath)
            var info=stat();try require(fstatat(fd,intent.name,&info,AT_SYMLINK_NOFOLLOW)==0,.staleState)
            if intent.kind == .createDirectory {try require(info.st_dev==device && (info.st_mode & S_IFMT)==S_IFDIR && (info.st_mode & 0o077)==0,.staleState)}
            else if let expected=plan.source {
                try require(info.st_dev==expected.device && info.st_ino==expected.inode && info.st_mode==expected.mode && info.st_nlink==expected.links,.staleState)
                var absent=stat();errno=0
                try require(fstatat(fd,intent.sourceName!,&absent,AT_SYMLINK_NOFOLLOW) != 0 && errno==ENOENT,.staleState)
            }
            try require(fsync(fd)==0,.unsafeFile)
        } catch {throw FileMutationFailure(code:error as? NASError ?? .unsafeFile,applied:applied)}
    }
    func transferDownload(relative: String) throws -> TransferDownload {
        let parts = try Self.components(relative, allowEmpty: false)
        let parentPath = parts.dropLast().joined(separator: "/"), name = parts.last!
        try validateRoot()
        let parent = try Self.descend(from: descriptor, relative: parentPath, device: device)
        var retained = false; var file: Int32 = -1
        defer { if !retained { if file >= 0 { close(file) }; close(parent) } }
        file = openat(parent, name, O_RDONLY | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK)
        try require(file >= 0, .unsafeFile)
        try require(try Self.attributes(file).st_dev == device, .unsafeFile)
        let value = try TransferDownload(file: file, parent: parent, name: name,
            validate: { try self.validateDirectory(parent, relative: parentPath) })
        retained = true; try value.validate(); return value
    }
    /// Called only for the instance's host-binding root, never a client-selected path.
    func transferStaging(id: String, targetDevice: dev_t, prefix: String = "upload") throws -> TransferStaging {
        try require(UUID(uuidString: id)?.uuidString.lowercased() == id, .invalidSchema)
        try require(["upload", "copy"].contains(prefix), .invalidSchema)
        try validateRoot(); try require(try Self.attributes(descriptor).st_dev == targetDevice, .unsupported)
        if mkdirat(descriptor, "transfer-staging", 0o700) != 0 { try require(errno == EEXIST, .unsafeFile) }
        let directory = openat(descriptor, "transfer-staging", Self.directoryFlags)
        try require(directory >= 0, .unsafeFile)
        var retained = false; var file: Int32 = -1
        defer { if !retained { if file >= 0 { close(file) }; close(directory) } }
        let info = try Self.attributes(directory)
        try require(info.st_dev == targetDevice && info.st_uid == geteuid() && (info.st_mode & 0o077) == 0, .unsafeFile)
        let name = prefix + "-" + id
        file = openat(directory, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        try require(file >= 0, .unsafeFile)
        let value = try TransferStaging(directory: directory, file: file, name: name, validate: {
            try self.validateRoot()
            let current = openat(self.descriptor, "transfer-staging", Self.directoryFlags)
            try require(current >= 0, .staleState); defer { close(current) }
            try require(Self.sameIdentity(info, try Self.attributes(current)), .staleState)
        })
        retained = true; try value.validate(); return value
    }
    func validateTransferParent(_ plan: DescriptorMutation) throws {
        try require(plan.readerID == identity, .denied)
        try validateDirectory(plan.descriptor, relative: plan.intent.parentPath)
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
    private var writers:[String:(UUID,UUID,UUID)]=[:]
    private var uploaders:[String:(UUID,UUID,UUID)]=[:]
    private var copiers:[String:(UUID,UUID,UUID)]=[:]
    func register(_ reader: DescriptorLibrary, permit: FixtureVolumePermit) {
        lock.lock(); defer { lock.unlock() }
        readers[permit.reference.libraryID] = (permit.approvalID, reader)
        writers.removeValue(forKey:permit.reference.libraryID)
        uploaders.removeValue(forKey:permit.reference.libraryID)
        copiers.removeValue(forKey:permit.reference.libraryID)
    }
    func reader(_ permit: FixtureVolumePermit) throws -> DescriptorLibrary {
        lock.lock(); defer { lock.unlock() }
        guard let value = readers[permit.reference.libraryID], value.0 == permit.approvalID else { throw NASError.denied }
        return value.1
    }
    func revoke(_ libraryID: String) {
        lock.lock(); defer { lock.unlock() }; readers.removeValue(forKey: libraryID);writers.removeValue(forKey:libraryID);uploaders.removeValue(forKey:libraryID);copiers.removeValue(forKey:libraryID)
    }
    func approveMutations(_ permit:FixtureVolumePermit) throws {
        lock.lock();defer{lock.unlock()}
        guard let value=readers[permit.reference.libraryID],value.0==permit.approvalID else{throw NASError.denied}
        writers[permit.reference.libraryID]=(permit.approvalID,value.1.identity,UUID())
    }
    func mutationReader(_ permit:FixtureVolumePermit) throws ->(UUID,DescriptorLibrary) {
        lock.lock();defer{lock.unlock()}
        guard let reader=readers[permit.reference.libraryID],let writer=writers[permit.reference.libraryID],
              reader.0==permit.approvalID && writer.0==permit.approvalID && writer.1==reader.1.identity else{throw NASError.denied}
        return (writer.2,reader.1)
    }
    func approveUploads(_ permit: FixtureVolumePermit) throws {
        lock.lock(); defer { lock.unlock() }
        guard let reader = readers[permit.reference.libraryID], reader.0 == permit.approvalID else { throw NASError.denied }
        uploaders[permit.reference.libraryID] = (permit.approvalID, reader.1.identity, UUID())
    }
    func uploadReader(_ permit: FixtureVolumePermit) throws -> (UUID, DescriptorLibrary) {
        lock.lock(); defer { lock.unlock() }
        guard let reader = readers[permit.reference.libraryID], let writer = uploaders[permit.reference.libraryID],
              reader.0 == permit.approvalID && writer.0 == permit.approvalID && writer.1 == reader.1.identity else { throw NASError.denied }
        return (writer.2, reader.1)
    }
    func approveCopies(_ permit: FixtureVolumePermit) throws {
        lock.lock(); defer { lock.unlock() }
        guard let reader = readers[permit.reference.libraryID], reader.0 == permit.approvalID else { throw NASError.denied }
        copiers[permit.reference.libraryID] = (permit.approvalID, reader.1.identity, UUID())
    }
    func copyReader(_ permit: FixtureVolumePermit) throws -> (UUID, DescriptorLibrary) {
        lock.lock(); defer { lock.unlock() }
        guard let reader = readers[permit.reference.libraryID], let copier = copiers[permit.reference.libraryID],
              reader.0 == permit.approvalID && copier.0 == permit.approvalID && copier.1 == reader.1.identity else { throw NASError.denied }
        return (copier.2, reader.1)
    }
}
