import Foundation
import Darwin
import CryptoKit

// Host-only stamps/capabilities; no inode, descriptor or filesystem identity is sent to clients.
struct DirectoryStamp: Equatable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let links: nlink_t
    let modifiedSeconds: Int
    let modifiedNanos: Int
    let changedSeconds: Int
    let changedNanos: Int
    init(_ value: stat) {
        device=value.st_dev; inode=value.st_ino; mode=value.st_mode; size=value.st_size; links=value.st_nlink
        modifiedSeconds=value.st_mtimespec.tv_sec; modifiedNanos=value.st_mtimespec.tv_nsec
        changedSeconds=value.st_ctimespec.tv_sec; changedNanos=value.st_ctimespec.tv_nsec
    }
}
struct DirectoryScanBudget {
    let entries: Int
    let nameBytes: Int
    let seconds: TimeInterval
    init(entries: Int=8192, nameBytes: Int=1_048_576, seconds: TimeInterval=5) {
        self.entries=entries; self.nameBytes=nameBytes; self.seconds=seconds
    }
}
struct DirectoryNameBudget {
    private var keys: Set<Data> = []
    private var bytes=0
    mutating func add(_ name: String, budget: DirectoryScanBudget) throws {
        try require(keys.count < budget.entries && name.utf8.count <= budget.nameBytes-bytes, .budgetExceeded)
        try DescriptorLibrary.checkNames([name])
        let normalized=name.precomposedStringWithCanonicalMapping.lowercased()
        // A hash collision also fails closed; whole-directory file DTOs/names are not retained.
        try require(keys.insert(Data(SHA256.hash(data:Data(normalized.utf8)))).inserted, .collision)
        bytes += name.utf8.count
    }
}
struct DirectorySlice {
    let entries: [FixtureFileEntry]
    let stamp: DirectoryStamp
    let hasMore: Bool
}
public struct FixtureDirectoryPage: Sendable {
    public let libraryID: String
    public let relativePath: String
    public let pageSize: Int
    public let entries: [FixtureFileEntry]
    public let nextCursor: String?
}
struct DirectoryPageScope: Equatable {
    let caller: JobPageScope
    let libraryID: Data
    let relativePath: Data
    let volumeID: UUID
    let mediaID: UUID
    let mountID: UUID
    let approvalID: UUID
    let inventoryRevision: UInt64
    let readerID: UUID
}

final class DirectoryPageRegistry: @unchecked Sendable {
    private struct Entry {
        let scope: DirectoryPageScope
        let size: Int
        let after: String
        let stamp: DirectoryStamp
        let deadline: TimeInterval
    }
    private let lock=NSLock()
    private var pending: [UUID:Entry]=[:]
    private var consumed: [UUID:TimeInterval]=[:]
    private let capacity: Int
    private let lifetime: TimeInterval
    private let now: () -> TimeInterval
    init(capacity: Int=64, lifetime: TimeInterval=60, now: @escaping () -> TimeInterval={ProcessInfo.processInfo.systemUptime}) {
        self.capacity=capacity; self.lifetime=lifetime; self.now=now
    }
    func endSession(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; pending=pending.filter { $0.value.scope.caller.sessionID != id }
    }
    func page<T>(scope: DirectoryPageScope, size: Int, cursor: String?,
                 query: (String?,DirectoryStamp?) throws -> DirectorySlice,
                 validate: (DirectoryStamp) throws -> Void, render: (FixtureDirectoryPage) throws -> T) throws -> T {
        try require((1...100).contains(size), .invalidSchema)
        let token: UUID?
        if let cursor {
            try require(cursor.utf8.count==36 && UUID(uuidString:cursor)?.uuidString.lowercased()==cursor, .invalidSchema)
            token=UUID(uuidString:cursor)
        } else { token=nil }
        lock.lock(); defer { lock.unlock() }
        let time=now(); consumed=consumed.filter { $0.value>time }
        var previous: Entry?
        if let token {
            if consumed[token] != nil { throw NASError.replay }
            guard let entry=pending[token] else { throw NASError.denied }
            try require(entry.scope==scope && entry.size==size, .denied)
            if entry.deadline<=time { pending.removeValue(forKey:token); throw NASError.expired }
            previous=entry
        }
        pending=pending.filter { $0.value.deadline>time }
        let slice: DirectorySlice
        do { slice=try query(previous?.after,previous?.stamp) }
        catch NASError.staleState { if let token { pending.removeValue(forKey:token) }; throw NASError.staleState }
        let deadline=previous?.deadline ?? (time+lifetime)
        try require(now()<deadline, .expired)
        try validate(slice.stamp)
        let next=slice.hasMore ? UUID() : nil
        if next != nil { try require(pending.count-(token == nil ? 0:1)<capacity, .budgetExceeded) }
        let page=FixtureDirectoryPage(libraryID:String(decoding:scope.libraryID,as:UTF8.self), relativePath:String(decoding:scope.relativePath,as:UTF8.self), pageSize:size, entries:slice.entries, nextCursor:next?.uuidString.lowercased())
        // Encoding/budget and final authorization/path checks complete before old capability consumption.
        let result=try render(page)
        try validate(slice.stamp); try require(now()<deadline, .expired)
        if let token {
            pending.removeValue(forKey:token)
            if consumed.count>=capacity,let oldest=consumed.min(by:{$0.value<$1.value}) { consumed.removeValue(forKey:oldest.key) }
            consumed[token]=deadline
        }
        if let next,let last=slice.entries.last { pending[next]=Entry(scope:scope,size:size,after:last.name,stamp:slice.stamp,deadline:deadline) }
        return result
    }
}
