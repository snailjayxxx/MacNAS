import Foundation
import CryptoKit

public struct FixtureUploadIntent: Encodable, Equatable {
    public let libraryID: String
    public let parentPath: String
    public let name: String
    public let totalBytes: Int64
    public init(libraryID: String, parentPath: String = "", name: String, totalBytes: Int64) throws {
        _ = try FixtureFileOperationIntent(libraryID: libraryID, parentPath: parentPath, kind: .createDirectory, name: name)
        try require((0...FixtureTransferLimits.fileBytes).contains(totalBytes), .budgetExceeded)
        self.libraryID = libraryID; self.parentPath = parentPath; self.name = name; self.totalBytes = totalBytes
    }
    var path: String { parentPath.isEmpty ? name : parentPath + "/" + name }
}
public enum FixtureTransferLimits {
    public static let chunkBytes = 32768
    public static let fileBytes: Int64 = 16 * 1024 * 1024
    public static let reservedBytes: Int64 = 64 * 1024 * 1024
}
public struct FixtureUploadPreview: Encodable {
    public let transferVersion = 1
    public let transferID: String
    public let intent: FixtureUploadIntent
    public let state: String
    public let chunkBytes = FixtureTransferLimits.chunkBytes
    public let expiresInSeconds: Int
}
public struct FixtureTransferStatus: Encodable {
    public let transferVersion = 1
    public let transferID: String
    public let state: String
    public let direction: String?
    public let libraryID: String?
    public let relativePath: String?
    public let totalBytes: Int64?
    public let transferredBytes: Int64?
    public let chunkBytes = FixtureTransferLimits.chunkBytes
    public let sha256: String?
    public let lastChunkSHA256: String?
    public let error: String?
    enum CodingKeys: String, CodingKey { case transferVersion,transferID,state,direction,libraryID,relativePath,totalBytes,transferredBytes,chunkBytes,sha256,lastChunkSHA256,error }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(transferVersion,forKey:.transferVersion); try c.encode(transferID,forKey:.transferID); try c.encode(state,forKey:.state)
        try c.encode(direction,forKey:.direction); try c.encode(libraryID,forKey:.libraryID); try c.encode(relativePath,forKey:.relativePath)
        try c.encode(totalBytes,forKey:.totalBytes); try c.encode(transferredBytes,forKey:.transferredBytes); try c.encode(chunkBytes,forKey:.chunkBytes)
        try c.encode(sha256,forKey:.sha256); try c.encode(lastChunkSHA256,forKey:.lastChunkSHA256); try c.encode(error,forKey:.error)
    }
}
public struct FixtureDownloadChunk: Encodable {
    public let transferVersion = 1
    public let transferID: String
    public let offset: Int64
    public let nextOffset: Int64
    public let parts: [String]
    public let eof: Bool
    public let chunkSHA256: String
    public let sha256: String?
    enum CodingKeys: String, CodingKey { case transferVersion,transferID,offset,nextOffset,parts,eof,chunkSHA256,sha256 }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(transferVersion,forKey:.transferVersion);try c.encode(transferID,forKey:.transferID)
        try c.encode(offset,forKey:.offset);try c.encode(nextOffset,forKey:.nextOffset);try c.encode(parts,forKey:.parts)
        try c.encode(eof,forKey:.eof);try c.encode(chunkSHA256,forKey:.chunkSHA256);try c.encode(sha256,forKey:.sha256)
    }
}
struct FileTransferScope: Equatable {
    let directory: DirectoryPageScope
    let generation: Int
    let uploadApproval: UUID?
}
enum TransferEncoding {
    static func id(_ value: String) throws {
        try require(value.utf8.count == 36 && UUID(uuidString:value)?.uuidString.lowercased() == value, .invalidSchema)
    }
    static func digest(_ data: Data) -> String { SHA256.hash(data:data).map{String(format:"%02x",$0)}.joined() }
    static func digest(_ hash: SHA256) -> String { hash.finalize().map{String(format:"%02x",$0)}.joined() }
    static func hash(_ value: String) throws {
        try require(value.utf8.count == 64 && value.utf8.allSatisfy{(48...57).contains($0) || (97...102).contains($0)}, .invalidSchema)
    }
    static func parts(_ data: Data) -> [String] {
        stride(from:0,to:data.count,by:2048).map{data.subdata(in:$0..<min($0+2048,data.count)).base64EncodedString()}
    }
    static func data(_ parts: [String]) throws -> Data {
        try require((1...16).contains(parts.count), .invalidSchema)
        var data = Data()
        for (index,part) in parts.enumerated() {
            try require(part.utf8.count <= 2732, .budgetExceeded)
            guard let value = Data(base64Encoded:part), value.base64EncodedString() == part else { throw NASError.invalidSchema }
            try require(!value.isEmpty && value.count <= 2048 && (index == parts.count-1 || value.count == 2048), .invalidSchema)
            data.append(value)
        }
        return data
    }
}

/// Bounded, host-lifetime streams and receipts. Staging files and handles never enter portable state.
final class FileTransferRegistry: @unchecked Sendable {
    private final class Entry {
        let id: String, scope: FileTransferScope, direction: String, library: String, path: String, total: Int64
        let absoluteDeadline: TimeInterval
        var deadline: TimeInterval, state: String, error: String?, digest: String?, finalExpected: String?
        var plan: DescriptorMutation?, reader: DescriptorLibrary?, staging: TransferStaging?, download: TransferDownload?
        var offset: Int64 = 0, hash = SHA256(), lastOffset: Int64?, lastData: Data?, lastSHA: String?, lastChunk: FixtureDownloadChunk?
        var reserved: Int64 = 0
        init(id: String, scope: FileTransferScope, direction: String, library: String, path: String, total: Int64, state: String, now: TimeInterval) {
            self.id=id;self.scope=scope;self.direction=direction;self.library=library;self.path=path;self.total=total;self.state=state
            absoluteDeadline=now+1800;deadline=now+(state == "ready" ? 30:60)
        }
        var terminal: Bool { ["completed","cancelled","failed","uncertain"].contains(state) }
        func status() -> FixtureTransferStatus {
            .init(transferID:id,state:state,direction:direction,libraryID:library,relativePath:path,totalBytes:total,transferredBytes:offset,sha256:digest,lastChunkSHA256:lastSHA,error:error)
        }
    }
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private let capacity: Int
    private let quota: Int64
    private var entries: [String:Entry] = [:]
    init(capacity: Int = 8, quota: Int64 = FixtureTransferLimits.reservedBytes, now: @escaping () -> TimeInterval = {ProcessInfo.processInfo.systemUptime}) {
        self.capacity=capacity;self.quota=quota;self.now=now
    }
    private func terminal(_ entry: Entry, state: String, error: NASError? = nil) {
        entry.state=state;entry.error=error?.rawValue;entry.deadline=now()+300
        entry.staging=nil;entry.download=nil;entry.plan=nil;entry.reader=nil;entry.reserved=0
        if state != "completed" { entry.lastData=nil;entry.lastChunk=nil }
    }
    private func reclaim() {
        let time=now()
        for entry in Array(entries.values) where time >= entry.deadline || (!entry.terminal && time >= entry.absoluteDeadline) {
            if entry.terminal { entries.removeValue(forKey:entry.id) }
            else { terminal(entry,state:"failed",error:.expired) }
        }
        let receipts=entries.values.filter{$0.terminal}.sorted{$0.deadline<$1.deadline}
        for entry in receipts.prefix(max(0,receipts.count-32)) { entries.removeValue(forKey:entry.id) }
    }
    private func available() throws { try require(entries.values.filter{!$0.terminal}.count<capacity,.budgetExceeded) }
    private func entry(_ id: String, caller: JobPageScope) throws -> Entry {
        try TransferEncoding.id(id);guard let entry=entries[id] else {throw NASError.replay}
        try require(entry.scope.directory.caller==caller,.denied);return entry
    }
    private func live(_ entry: Entry, validate: (FileTransferScope) throws -> Void) throws {
        try require(now()<entry.deadline && now()<entry.absoluteDeadline,.expired);try validate(entry.scope)
    }
    func endSession(_ id: UUID) {
        lock.lock();defer{lock.unlock()};entries=entries.filter{$0.value.scope.directory.caller.sessionID != id}
    }
    func preview<T>(intent: FixtureUploadIntent, scope: FileTransferScope, reader: DescriptorLibrary,
                    validate: () throws -> Void, render: (FixtureUploadPreview) throws -> T) throws -> T {
        lock.lock();defer{lock.unlock()};reclaim()
        let plan=try reader.prepareMutation(.init(libraryID:intent.libraryID,parentPath:intent.parentPath,kind:.createDirectory,name:intent.name))
        let id=UUID().uuidString.lowercased(),entry=Entry(id:id,scope:scope,direction:"upload",library:intent.libraryID,path:intent.path,total:intent.totalBytes,state:"ready",now:now())
        if plan.state == "ready" {try available()}
        try validate()
        let output=try render(.init(transferID:id,intent:intent,state:plan.state,expiresInSeconds:plan.state == "ready" ? 30:0))
        try validate();try reader.validateMutation(plan);try require(now()<entry.deadline,.expired)
        if plan.state == "ready" {entry.plan=plan;entry.reader=reader;entries[id]=entry}
        return output
    }
    func beginUpload(id: String, caller: JobPageScope, confirmed: Bool, validate: (FileTransferScope) throws -> Void,
                     staging: (DescriptorMutation) throws -> TransferStaging) throws -> FixtureTransferStatus {
        lock.lock();defer{lock.unlock()};reclaim();let entry=try entry(id,caller:caller)
        try require(confirmed && entry.direction == "upload",.denied);try validate(entry.scope)
        if entry.state != "ready" {return entry.status()}
        do {
            try live(entry,validate:validate)
            try require(entry.total<=quota-entries.values.reduce(0,{$0+$1.reserved}),.budgetExceeded)
            let plan=entry.plan!,reader=entry.reader!;try reader.validateMutation(plan)
            let file=try staging(plan);try live(entry,validate:validate);try reader.validateMutation(plan)
            entry.staging=file;entry.reserved=entry.total;entry.state="uploading";entry.deadline=now()+60
        } catch {terminal(entry,state:"failed",error:error as? NASError ?? .unsafeFile)}
        reclaim();return entry.status()
    }
    func append(id: String, offset: Int64, parts: [String], caller: JobPageScope,
                validate: (FileTransferScope) throws -> Void) throws -> FixtureTransferStatus {
        let data=try TransferEncoding.data(parts)
        lock.lock();defer{lock.unlock()};reclaim();let entry=try entry(id,caller:caller)
        try require(entry.direction == "upload",.denied);try validate(entry.scope)
        if let last=entry.lastOffset,offset==last {
            try require(entry.lastData==data,.collision)
            if !entry.terminal {
                try live(entry,validate:validate);try entry.reader!.validateMutation(entry.plan!);try entry.staging!.validate()
                try live(entry,validate:validate)
            }
            return entry.status()
        }
        try require(entry.state == "uploading" && offset==entry.offset,.replay)
        try require(Int64(data.count)==min(Int64(FixtureTransferLimits.chunkBytes),entry.total-offset) && !data.isEmpty,.invalidSchema)
        do {
            try live(entry,validate:validate);try entry.reader!.validateMutation(entry.plan!)
            try entry.staging!.append(data,offset:offset)
            try live(entry,validate:validate);try entry.reader!.validateMutation(entry.plan!)
            entry.hash.update(data:data);entry.lastOffset=offset;entry.lastData=data;entry.lastSHA=TransferEncoding.digest(data)
            entry.offset += Int64(data.count);entry.deadline=now()+60
        } catch {terminal(entry,state:"failed",error:error as? NASError ?? .unsafeFile)}
        reclaim();return entry.status()
    }
    func finishUpload(id: String, expected: String, caller: JobPageScope, validate: (FileTransferScope) throws -> Void,
                      afterPublication: () throws -> Void = {}) throws -> FixtureTransferStatus {
        try TransferEncoding.hash(expected)
        lock.lock();defer{lock.unlock()};reclaim();let entry=try entry(id,caller:caller)
        try require(entry.direction == "upload",.denied);try validate(entry.scope)
        if let captured=entry.finalExpected {try require(captured==expected,.collision)}
        if entry.terminal {return entry.status()}
        try require(entry.state == "uploading" && entry.offset==entry.total,.invalidSchema)
        entry.finalExpected=expected
        do {
            try live(entry,validate:validate);let digest=TransferEncoding.digest(entry.hash)
            try require(digest==expected,.integrity)
            let plan=entry.plan!,reader=entry.reader!,file=entry.staging!
            try require(try file.digest(bytes:entry.total,checkDeadline:{
                try require(self.now()<entry.deadline && self.now()<entry.absoluteDeadline,.expired)
            })==expected,.integrity)
            try file.publish(to:plan,validate:{try self.live(entry,validate:validate);try reader.validateMutation(plan)},afterPublication:{
                try afterPublication();try validate(entry.scope);try reader.validateTransferParent(plan)
            })
            try live(entry,validate:validate);try reader.validateTransferParent(plan)
            entry.digest=digest;terminal(entry,state:"completed")
        } catch {
            let applied=entry.staging?.published == true
            if applied {entry.digest=TransferEncoding.digest(entry.hash)}
            terminal(entry,state:applied ? "uncertain":"failed",error:error as? NASError ?? .unsafeFile)
        }
        reclaim();return entry.status()
    }
    func beginDownload<T>(library: String, path: String, scope: FileTransferScope, file: TransferDownload,
                          validate: () throws -> Void, render: (FixtureTransferStatus) throws -> T) throws -> T {
        lock.lock();defer{lock.unlock()};reclaim();try available()
        try require(file.bytes<=FixtureTransferLimits.fileBytes,.budgetExceeded)
        let id=UUID().uuidString.lowercased(),entry=Entry(id:id,scope:scope,direction:"download",library:library,path:path,total:file.bytes,state:"downloading",now:now())
        try file.validate();try validate();let output=try render(entry.status())
        try file.validate();try validate();try require(now()<entry.deadline,.expired)
        entry.download=file;entries[id]=entry;return output
    }
    func download<T>(id: String, offset: Int64, caller: JobPageScope, validate: (FileTransferScope) throws -> Void,
                     render: (FixtureDownloadChunk) throws -> T) throws -> T {
        lock.lock();defer{lock.unlock()};reclaim();let entry=try entry(id,caller:caller)
        try require(entry.direction == "download",.denied);try validate(entry.scope)
        if let chunk=entry.lastChunk,chunk.offset==offset {
            if !entry.terminal {try live(entry,validate:validate);try entry.download!.validate()}
            let output=try render(chunk)
            if !entry.terminal {try live(entry,validate:validate);try entry.download!.validate()}
            else {try validate(entry.scope)}
            return output
        }
        try require(entry.state == "downloading" && offset==entry.offset,.replay)
        let data: Data
        do {try live(entry,validate:validate);data=try entry.download!.read(offset:offset,maximum:FixtureTransferLimits.chunkBytes)}
        catch {terminal(entry,state:"failed",error:error as? NASError ?? .unsafeFile);throw error}
        var hash=entry.hash;hash.update(data:data)
        let next=offset+Int64(data.count),eof=next==entry.total
        let chunk=FixtureDownloadChunk(transferID:id,offset:offset,nextOffset:next,parts:TransferEncoding.parts(data),eof:eof,chunkSHA256:TransferEncoding.digest(data),sha256:eof ? TransferEncoding.digest(hash):nil)
        let output=try render(chunk)
        do {try live(entry,validate:validate);try entry.download!.validate()}
        catch {terminal(entry,state:"failed",error:error as? NASError ?? .unsafeFile);throw error}
        entry.hash=hash;entry.offset=next;entry.lastChunk=chunk;entry.lastSHA=chunk.chunkSHA256;entry.deadline=now()+60
        if eof {entry.digest=chunk.sha256;terminal(entry,state:"completed");reclaim()}
        return output
    }
    func status(id: String, caller: JobPageScope, validate: (FileTransferScope) throws -> Void) throws -> FixtureTransferStatus {
        try TransferEncoding.id(id);lock.lock();defer{lock.unlock()};reclaim()
        guard let entry=entries[id],entry.scope.directory.caller==caller else {
            return .init(transferID:id,state:"notVisible",direction:nil,libraryID:nil,relativePath:nil,totalBytes:nil,transferredBytes:nil,sha256:nil,lastChunkSHA256:nil,error:nil)
        }
        try validate(entry.scope);return entry.status()
    }
    /// Owner-only disposal of private staging/handles does not require still-visible library content.
    func cancel(id: String, caller: JobPageScope) throws -> FixtureTransferStatus {
        lock.lock();defer{lock.unlock()};reclaim();let entry=try entry(id,caller:caller)
        if !entry.terminal {terminal(entry,state:"cancelled")};reclaim();return entry.status()
    }
}
