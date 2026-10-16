import Foundation
import CryptoKit

public struct FixtureFileCopyIntent: Encodable, Equatable {
    public let sourceLibraryID: String
    public let sourcePath: String
    public let targetLibraryID: String
    public let parentPath: String
    public let name: String
    public init(sourceLibraryID: String, sourcePath: String, targetLibraryID: String, parentPath: String = "", name: String) throws {
        try require(!sourceLibraryID.isEmpty && sourceLibraryID.utf8.count <= 128 && !sourceLibraryID.contains("\0"), .invalidSchema)
        try SafeFS.relative(sourcePath)
        try require(sourcePath.utf8.count <= 4096 && sourcePath.split(separator: "/").count <= 128, .budgetExceeded)
        _ = try FixtureFileOperationIntent(libraryID: targetLibraryID, parentPath: parentPath, kind: .createDirectory, name: name)
        self.sourceLibraryID = sourceLibraryID; self.sourcePath = sourcePath; self.targetLibraryID = targetLibraryID; self.parentPath = parentPath; self.name = name
    }
    var targetPath: String { parentPath.isEmpty ? name : parentPath + "/" + name }
}

public struct FixtureFileCopyPreview: Encodable {
    public let copyVersion = 1
    public let copyID: String
    public let intent: FixtureFileCopyIntent
    public let state: String
    public let totalBytes: Int64
    public let chunkBytes = FixtureTransferLimits.chunkBytes
    public let expiresInSeconds: Int
}

public struct FixtureFileCopyStatus: Encodable {
    public let copyVersion = 1
    public let copyID: String
    public let state: String
    public let intent: FixtureFileCopyIntent?
    public let totalBytes: Int64?
    public let copiedBytes: Int64?
    public let chunkBytes = FixtureTransferLimits.chunkBytes
    public let sha256: String?
    public let error: String?
    enum CodingKeys: String, CodingKey { case copyVersion, copyID, state, intent, totalBytes, copiedBytes, chunkBytes, sha256, error }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(copyVersion, forKey: .copyVersion); try c.encode(copyID, forKey: .copyID); try c.encode(state, forKey: .state)
        try c.encode(intent, forKey: .intent); try c.encode(totalBytes, forKey: .totalBytes); try c.encode(copiedBytes, forKey: .copiedBytes)
        try c.encode(chunkBytes, forKey: .chunkBytes); try c.encode(sha256, forKey: .sha256); try c.encode(error, forKey: .error)
    }
}

struct FileCopyScope: Equatable {
    let source: DirectoryPageScope
    let target: DirectoryPageScope
    let generation: Int
    let copyApproval: UUID
}

/// Host-lifetime copy capabilities. Only the service reads source bytes and writes private staging.
final class FileCopyRegistry: @unchecked Sendable {
    private final class Entry {
        let id: String, scope: FileCopyScope, intent: FixtureFileCopyIntent, total: Int64, absoluteDeadline: TimeInterval
        var deadline: TimeInterval, state = "ready", error: String?, digest: String?, offset: Int64 = 0, lastOffset: Int64?
        var hash = SHA256(), reserved: Int64 = 0
        var source: TransferDownload?, target: DescriptorLibrary?, plan: DescriptorMutation?, staging: TransferStaging?
        init(id: String, scope: FileCopyScope, intent: FixtureFileCopyIntent, source: TransferDownload, target: DescriptorLibrary, plan: DescriptorMutation, now: TimeInterval) {
            self.id = id; self.scope = scope; self.intent = intent; total = source.bytes
            self.source = source; self.target = target; self.plan = plan; deadline = now + 30; absoluteDeadline = now + 1800
        }
        var terminal: Bool { ["completed", "cancelled", "failed", "uncertain"].contains(state) }
        func status() -> FixtureFileCopyStatus { .init(copyID: id, state: state, intent: intent, totalBytes: total, copiedBytes: offset, sha256: digest, error: error) }
    }
    private let lock = NSLock(), capacity: Int, quota: Int64
    private let now: () -> TimeInterval
    private var entries: [String: Entry] = [:]
    init(capacity: Int = 8, quota: Int64 = FixtureTransferLimits.reservedBytes, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.capacity = capacity; self.quota = quota; self.now = now
    }
    private func terminal(_ entry: Entry, state: String, error: NASError? = nil) {
        entry.state = state; entry.error = error?.rawValue; entry.deadline = now() + 300
        entry.source = nil; entry.target = nil; entry.plan = nil; entry.staging = nil; entry.reserved = 0
    }
    private func reclaim() {
        let time = now()
        for entry in Array(entries.values) where time >= entry.deadline || (!entry.terminal && time >= entry.absoluteDeadline) {
            if entry.terminal { entries.removeValue(forKey: entry.id) }
            else { terminal(entry, state: "failed", error: .expired) }
        }
        let receipts = entries.values.filter { $0.terminal }.sorted { $0.deadline < $1.deadline }
        for entry in receipts.prefix(max(0, receipts.count - 32)) { entries.removeValue(forKey: entry.id) }
    }
    private func entry(_ id: String, caller: JobPageScope) throws -> Entry {
        try TransferEncoding.id(id)
        guard let entry = entries[id] else { throw NASError.replay }
        try require(entry.scope.source.caller == caller, .denied); return entry
    }
    private func live(_ entry: Entry, validate: (FileCopyScope) throws -> Void) throws {
        try require(now() < entry.deadline && now() < entry.absoluteDeadline, .expired)
        try validate(entry.scope); try entry.source!.validate(); try entry.target!.validateMutation(entry.plan!)
    }
    private func authorize(_ entry: Entry, validate: (FileCopyScope) throws -> Void) throws {
        do { try validate(entry.scope) }
        catch { if !entry.terminal { terminal(entry, state: "failed", error: error as? NASError ?? .denied) }; throw error }
    }
    func endSession(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; entries = entries.filter { $0.value.scope.source.caller.sessionID != id }
    }
    func preview<T>(intent: FixtureFileCopyIntent, scope: FileCopyScope, source: TransferDownload, target: DescriptorLibrary,
                    validate: () throws -> Void, render: (FixtureFileCopyPreview) throws -> T) throws -> T {
        lock.lock(); defer { lock.unlock() }; reclaim()
        try require(source.bytes <= FixtureTransferLimits.fileBytes, .budgetExceeded)
        let plan = try target.prepareMutation(.init(libraryID: intent.targetLibraryID, parentPath: intent.parentPath, kind: .createDirectory, name: intent.name))
        try require(source.device == plan.parent.device, .unsupported)
        let unchanged = intent.sourceLibraryID.utf8.elementsEqual(intent.targetLibraryID.utf8) && intent.sourcePath.utf8.elementsEqual(intent.targetPath.utf8)
        let state = unchanged ? "unchanged" : plan.state
        if state == "ready" { try require(entries.values.filter { !$0.terminal }.count < capacity, .budgetExceeded) }
        let id = UUID().uuidString.lowercased(), entry = Entry(id: id, scope: scope, intent: intent, source: source, target: target, plan: plan, now: now())
        try source.validate(); try validate()
        let output = try render(.init(copyID: id, intent: intent, state: state, totalBytes: source.bytes, expiresInSeconds: state == "ready" ? 30 : 0))
        try source.validate(); try target.validateMutation(plan); try validate(); try require(now() < entry.deadline, .expired)
        if state == "ready" { entries[id] = entry }; return output
    }
    func begin(id: String, caller: JobPageScope, confirmed: Bool, validate: (FileCopyScope) throws -> Void,
               staging: (DescriptorMutation) throws -> TransferStaging) throws -> FixtureFileCopyStatus {
        lock.lock(); defer { lock.unlock() }; reclaim(); let entry = try entry(id, caller: caller)
        try require(confirmed, .denied); try authorize(entry, validate: validate)
        if entry.state != "ready" { return entry.status() }
        do {
            try live(entry, validate: validate)
            try require(entry.total <= quota - entries.values.reduce(0, { $0 + $1.reserved }), .budgetExceeded)
            let file = try staging(entry.plan!); try live(entry, validate: validate)
            entry.staging = file; entry.reserved = entry.total; entry.state = "copying"; entry.deadline = now() + 60
        } catch { terminal(entry, state: "failed", error: error as? NASError ?? .unsafeFile) }
        reclaim(); return entry.status()
    }
    func chunk(id: String, offset: Int64, caller: JobPageScope, validate: (FileCopyScope) throws -> Void,
               afterPublication: () throws -> Void = {}) throws -> FixtureFileCopyStatus {
        lock.lock(); defer { lock.unlock() }; reclaim(); let entry = try entry(id, caller: caller)
        try authorize(entry, validate: validate)
        if entry.lastOffset == offset {
            if !entry.terminal {
                do { try live(entry, validate: validate); try entry.staging!.validate() }
                catch { terminal(entry, state: "failed", error: error as? NASError ?? .unsafeFile) }
            }
            return entry.status()
        }
        try require(entry.state == "copying" && offset == entry.offset, .replay)
        do {
            try live(entry, validate: validate)
            let data = try entry.source!.read(offset: offset, maximum: FixtureTransferLimits.chunkBytes)
            try entry.staging!.append(data, offset: offset); try live(entry, validate: validate)
            entry.hash.update(data: data); entry.lastOffset = offset; entry.offset += Int64(data.count); entry.deadline = now() + 60
            if entry.offset == entry.total {
                let digest = TransferEncoding.digest(entry.hash), file = entry.staging!, target = entry.target!, plan = entry.plan!
                try require(try file.digest(bytes: entry.total, checkDeadline: { try self.live(entry, validate: validate) }) == digest, .integrity)
                try file.publish(to: plan, validate: { try self.live(entry, validate: validate) }, afterPublication: {
                    try afterPublication(); try require(self.now() < entry.deadline && self.now() < entry.absoluteDeadline, .expired)
                    try validate(entry.scope); try entry.source!.validate(); try target.validateTransferParent(plan)
                })
                try require(now() < entry.deadline && now() < entry.absoluteDeadline, .expired)
                try validate(entry.scope); try entry.source!.validate(); try target.validateTransferParent(plan)
                entry.digest = digest; terminal(entry, state: "completed")
            }
        } catch {
            let applied = entry.staging?.published == true
            if applied { entry.digest = TransferEncoding.digest(entry.hash) }
            terminal(entry, state: applied ? "uncertain" : "failed", error: error as? NASError ?? .unsafeFile)
        }
        reclaim(); return entry.status()
    }
    func status(id: String, caller: JobPageScope, validate: (FileCopyScope) throws -> Void) throws -> FixtureFileCopyStatus {
        try TransferEncoding.id(id); lock.lock(); defer { lock.unlock() }; reclaim()
        guard let entry = entries[id], entry.scope.source.caller == caller else {
            return .init(copyID: id, state: "notVisible", intent: nil, totalBytes: nil, copiedBytes: nil, sha256: nil, error: nil)
        }
        try authorize(entry, validate: validate); return entry.status()
    }
    /// Owner-only disposal can clean private staging even after library authorization is revoked.
    func cancel(id: String, caller: JobPageScope) throws -> FixtureFileCopyStatus {
        lock.lock(); defer { lock.unlock() }; reclaim(); let entry = try entry(id, caller: caller)
        if !entry.terminal { terminal(entry, state: "cancelled") }; reclaim(); return entry.status()
    }
}
