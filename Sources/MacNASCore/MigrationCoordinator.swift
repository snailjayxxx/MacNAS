import Foundation
import CryptoKit

public enum MigrationKind: String, Codable { case restore, schemaUpgrade }
public enum MigrationPhase: String, Codable, CaseIterable {
    case preflight, exported, copying, databasePlanned, imported, schemaMigrated, needsAuth, publishedReadOnly, readyForCutover, rolledBack
    var rank: Int { Self.allCases.firstIndex(of: self)! }
}
public enum MigrationCheckpoint: String { case afterDatabaseCreated, afterImportCommit, afterSchemaCommit, beforePublish, afterPublish }
public enum MigrationFault {
    case afterCopiedFiles(Int), at(MigrationCheckpoint), failSchemaSQL
}
public struct MigrationEvent: Codable {
    public var sequence: Int
    public var phase: MigrationPhase
    public var action: String
}
public struct MigrationTransaction: Codable {
    public var schemaVersion = 1
    public var kind: MigrationKind
    public var transactionID: UUID
    public var databaseID: UUID
    public var instanceID: UUID
    public var instanceGeneration: Int
    public var sourceDatabase: String?
    public var sourceVersion: Int
    public var targetVersion: Int
    public var hostID: String
    public var destinationName: String
    public var sourceExportID: UUID?
    public var sourceManifestSHA256: String?
    public var outputExportID: UUID
    public var phase: MigrationPhase = .preflight
    public var copiedFiles: [String] = []
    public var resumeCount = 0
    public var abandonedDatabases: [String]? = nil
    public var failureCode: String?
    public var history: [MigrationEvent] = []
    public var databaseName: String { StateStore.plannedName(databaseID) }
    public var stagingName: String { ".\(destinationName).partial-\(transactionID.uuidString.lowercased())" }
    public var backupName: String { ".\(destinationName).upgrade-backup-\(transactionID.uuidString.lowercased())" }
    var databaseAttestation: String { "macnas-n009:\(transactionID.uuidString):\(instanceID.uuidString)" }
    mutating func event(_ action: String) {
        history.append(MigrationEvent(sequence: history.count, phase: phase, action: action))
    }
    mutating func advance(_ next: MigrationPhase) throws {
        let allowed = next == .rolledBack || (next.rank == phase.rank + 1 && next != .readyForCutover)
        try require(phase != .rolledBack && allowed, .denied)
        phase = next; failureCode = nil; event("advance")
    }
}
private struct JournalEnvelope: Codable { var transaction: MigrationTransaction; var signature: String }

enum JournalStore {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    static func url(_ destination: URL) throws -> URL {
        try SafeFS.resolve(destination.deletingLastPathComponent(), ".\(destination.lastPathComponent).macnas-journal.json")
    }
    static func save(_ record: MigrationTransaction, to file: URL) throws {
        let signature = try PortableInstance.signingKey().signature(for: encoded(record)).base64EncodedString()
        try SafeFS.write(JournalEnvelope(transaction: record, signature: signature), to: file)
        let handle = try FileHandle(forWritingTo: file); try handle.synchronize(); try handle.close()
    }
    static func load(_ destination: URL) throws -> MigrationTransaction {
        try loadFile(url(destination), destination: destination)
    }
    static func loadFile(_ file: URL, destination: URL) throws -> MigrationTransaction {
        let envelope = try PortableInstance.strictRead(JournalEnvelope.self, file)
        guard let signature = Data(base64Encoded: envelope.signature) else { throw NASError.integrity }
        try require(try PortableInstance.trustedKey().isValidSignature(signature, for: encoded(envelope.transaction)), .integrity)
        let r = envelope.transaction
        try require(r.schemaVersion == 1 && r.destinationName == destination.lastPathComponent, .integrity)
        try require([1,2,3,4,5,6].contains(r.sourceVersion) && [1,2,3,4,5,6].contains(r.targetVersion) && r.targetVersion >= r.sourceVersion, .invalidSchema)
        try require(r.resumeCount <= 1000 && !r.history.isEmpty && r.history.count < 10000, .integrity)
        try require(r.history.enumerated().allSatisfy { $0.offset == $0.element.sequence } && r.history.last?.phase == r.phase, .integrity)
        try require(!r.history.contains { $0.phase == .readyForCutover } && r.phase != .readyForCutover, .denied)
        try require(Set(r.copiedFiles).isSubset(of: Set(PortableInstance.requiredFiles)) && Set(r.copiedFiles).count == r.copiedFiles.count, .integrity)
        try require((r.abandonedDatabases?.count ?? 0)<=8,.integrity)
        for name in r.abandonedDatabases ?? [] { try PostgreSQLTools.fixtureName(name);try require(name != r.databaseName,.integrity) }
        try SafeFS.relative(r.destinationName)
        return r
    }
}

/// Persistent, signed host-local recovery journal. Only trusted synthetic instances and quarantined test databases.
public enum MigrationCoordinator {
    static func validateDestination(_ dest: URL, source: URL) throws {
        try SafeFS.inspect(dest); try SafeFS.relative(dest.lastPathComponent)
        let d = dest.standardizedFileURL.path, s = source.standardizedFileURL.path
        try require(d != s && !d.hasPrefix(s + "/") && !s.hasPrefix(d + "/"), .unsafePath)
    }
    public static func status(destination: URL) throws -> MigrationTransaction { try JournalStore.load(destination) }
    @discardableResult public static func restore(from source: URL, to destination: URL, hostID: String, fault: MigrationFault? = nil, checkpoint: ((MigrationCheckpoint) -> Void)? = nil) throws -> MigrationTransaction {
        try perform(kind: .restore, source: source, destination: destination, hostID: hostID, targetVersion: PortableInstance.databaseDescriptor(source).version(), fault: fault, checkpoint: checkpoint)
    }
    @discardableResult public static func upgrade(from source: URL, to destination: URL, hostID: String, targetVersion: Int = 2, fault: MigrationFault? = nil, checkpoint: ((MigrationCheckpoint) -> Void)? = nil) throws -> MigrationTransaction {
        try require([2,3,4,5,6].contains(targetVersion), .unsupported)
        return try perform(kind: .schemaUpgrade, source: source, destination: destination, hostID: hostID, targetVersion: targetVersion, fault: fault, checkpoint: checkpoint)
    }
    static func perform(kind: MigrationKind, source: URL, destination: URL, hostID: String, targetVersion: Int, fault: MigrationFault?, checkpoint: ((MigrationCheckpoint) -> Void)?) throws -> MigrationTransaction {
        try validateDestination(destination, source: source)
        try require(!hostID.isEmpty && hostID.utf8.count <= 256 && !hostID.contains("\0"), .invalidSchema)
        let parent = destination.deletingLastPathComponent()
        let lock = try InstanceLock(file: SafeFS.resolve(parent, ".\(destination.lastPathComponent).macnas-migration.lock"))
        return try withExtendedLifetime(lock) {
            let identity: InstanceIdentity
            let sourceDatabase: String?
            if kind == .restore {
                _ = try PortableInstance.verify(source)
                identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(source, "instance.json")); sourceDatabase = nil
            } else {
                identity = try PortableInstance.validateLayout(source, exported: false)
                let sourceStore = try PortableInstance.store(source)
                try PortableInstance.requirePortableFileEffectsDisabled(source, store: sourceStore)
                sourceDatabase = sourceStore.databaseName
            }
            let sourceVersion = try PortableInstance.databaseDescriptor(source).version()
            try require([1,2,3,4,5,6].contains(sourceVersion) && targetVersion >= sourceVersion && targetVersion <= 6, .invalidSchema)
            let journalURL = try JournalStore.url(destination)
            var record: MigrationTransaction
            if FileManager.default.fileExists(atPath: journalURL.path) {
                record = try JournalStore.load(destination)
                try require(record.kind == kind && record.instanceID == identity.instanceID && record.instanceGeneration == identity.generation && record.sourceDatabase == sourceDatabase && record.sourceVersion == sourceVersion && record.targetVersion == targetVersion && record.hostID == hostID, .staleState)
                try require(record.phase != .rolledBack, .staleState)
                record.resumeCount += 1; record.failureCode = nil; record.event("resume"); try JournalStore.save(record, to: journalURL)
            } else {
                try require(!FileManager.default.fileExists(atPath: destination.path), .collision)
                let transaction = UUID()
                record = MigrationTransaction(kind: kind, transactionID: transaction, databaseID: UUID(), instanceID: identity.instanceID, instanceGeneration: identity.generation, sourceDatabase: sourceDatabase, sourceVersion: sourceVersion, targetVersion: targetVersion, hostID: hostID, destinationName: destination.lastPathComponent, outputExportID: UUID())
                record.event("created"); try JournalStore.save(record, to: journalURL)
            }
            func hit(_ point: MigrationCheckpoint) throws {
                checkpoint?(point)
                if case .at(let expected) = fault, point == expected { throw NASError.interrupted }
            }
            do {
                let package: URL
                if kind == .schemaUpgrade {
                    package = try SafeFS.resolve(parent, record.backupName)
                    if !FileManager.default.fileExists(atPath: package.path) { try PortableInstance.export(from: source, to: package) }
                } else { package = source }
                let manifest = try PortableInstance.verify(package)
                let descriptor = try PortableInstance.databaseDescriptor(package)
                try require(manifest.instanceID == record.instanceID && manifest.generation == record.instanceGeneration && descriptor.version() == record.sourceVersion, .staleState)
                let sourceHash = try SafeFS.digest(SafeFS.resolve(package, "manifest.json"))
                if record.phase == .preflight {
                    record.sourceExportID = manifest.exportID; record.sourceManifestSHA256 = sourceHash
                    if record.targetVersion == record.sourceVersion { record.outputExportID = manifest.exportID }
                    try record.advance(.exported); try JournalStore.save(record, to: journalURL)
                }
                try require(record.sourceExportID == manifest.exportID && record.sourceManifestSHA256 == sourceHash, .integrity)
                if FileManager.default.fileExists(atPath: destination.path) {
                    try validatePublished(destination, record: record)
                    if record.phase != .publishedReadOnly {
                        try require(record.phase == .needsAuth, .collision)
                        try record.advance(.publishedReadOnly); try JournalStore.save(record, to: journalURL)
                    }
                    try saveLocalReport(record, destination: destination)
                    return record
                }
                try require(record.phase != .publishedReadOnly, .staleState)
                let stage = try SafeFS.resolve(parent, record.stagingName)
                if !FileManager.default.fileExists(atPath: stage.path) {
                    try require(record.phase.rank <= MigrationPhase.copying.rank, .integrity)
                    try SafeFS.freshDirectory(stage)
                }
                if record.phase == .exported { try record.advance(.copying); try JournalStore.save(record, to: journalURL) }
                if record.phase == .copying {
                    for path in PortableInstance.requiredFiles.sorted() {
                        guard let expected = manifest.files.first(where: { $0.path == path }) else { throw NASError.integrity }
                        let from = try SafeFS.resolve(package, path), to = try SafeFS.resolve(stage, path)
                        try require(try SafeFS.digest(from) == expected.sha256, .integrity)
                        if try FileManager.default.fileExists(atPath: to.path) && SafeFS.digest(to) != expected.sha256 {
                            try FileManager.default.removeItem(at: to) // Only this transaction's known regular staging file.
                        }
                        if !FileManager.default.fileExists(atPath: to.path) {
                            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
                            try FileManager.default.copyItem(at: from, to: to)
                            let handle = try FileHandle(forWritingTo: to); try handle.synchronize(); try handle.close()
                        }
                        try require(try SafeFS.digest(to) == expected.sha256, .integrity)
                        if !record.copiedFiles.contains(path) { record.copiedFiles.append(path); record.event("copied"); try JournalStore.save(record, to: journalURL) }
                        if case .afterCopiedFiles(let count) = fault, record.copiedFiles.count == count { throw NASError.interrupted }
                    }
                    for name in ["manifest.json", "manifest.sig"] {
                        let to = try SafeFS.resolve(stage, name)
                        if FileManager.default.fileExists(atPath: to.path) { try FileManager.default.removeItem(at: to) }
                        try FileManager.default.copyItem(at: SafeFS.resolve(package,name), to: to)
                    }
                    _ = try PortableInstance.verify(stage)
                    try record.advance(.databasePlanned); try JournalStore.save(record, to: journalURL)
                }
                let planned = try StateStore(databaseName:record.databaseName)
                if record.phase == .databasePlanned, try planned.exists(), try planned.attestation().isEmpty,
                   try planned.ownerName() == "macnas_test_owner", try planned.tableCount() == 0 {
                    // A crash between CREATE DATABASE and COMMENT leaves no trustworthy ownership receipt.
                    // Keep that database untouched and persist a fresh allocation rather than adopting it.
                    try require((record.abandonedDatabases?.count ?? 0)<8,.collision)
                    record.abandonedDatabases=(record.abandonedDatabases ?? [])+[record.databaseName]
                    record.databaseID=UUID();record.event("skipped-unattested-empty-database")
                    try JournalStore.save(record,to:journalURL)
                }
                let candidate = try StateStore.createEmpty(name: record.databaseName, attestation: record.databaseAttestation)
                if record.phase == .databasePlanned {
                    try hit(.afterDatabaseCreated)
                    if try candidate.tableCount() == 0 { try candidate.importArchive(SafeFS.resolve(package, "state/platform.pgdump")) }
                    else {
                        // pg_restore may have committed before import ACL hardening or journal advance.
                        // Only this attested import phase may tighten its known restored function ACLs.
                        try candidate.hardenImportedSchema4FunctionPrivileges()
                    }
                    try candidate.requirePortableRecycleEmpty()
                    try candidate.validate(expectedVersion: record.sourceVersion)
                    if let digest = descriptor.contentSHA256 { try require(try candidate.contentDigest() == digest, .integrity) }
                    try hit(.afterImportCommit)
                    try record.advance(.imported); try JournalStore.save(record, to: journalURL)
                }
                if record.phase == .imported {
                    try candidate.requirePortableRecycleEmpty()
                    // The complete source projection includes Schema 3 jobs, events and cursors.
                    // Base labels/app values alone cannot attest the preserved source contents.
                    if let digest = descriptor.contentSHA256 { try require(try candidate.contentDigest(asVersion: record.sourceVersion) == digest, .integrity) }
                    if let digest = descriptor.baseDataSHA256 { try require(try candidate.baseDataDigest() == digest, .integrity) }
                    if record.targetVersion > record.sourceVersion {
                        let failure: Bool; if case .failSchemaSQL = fault { failure = true } else { failure = false }
                        try candidate.migrate(toVersion:record.targetVersion,injectFailure:failure)
                    }
                    try candidate.validate(expectedVersion: record.targetVersion)
                    try candidate.requirePortableRecycleEmpty()
                    if let digest = descriptor.contentSHA256 { try require(try candidate.contentDigest(asVersion: record.sourceVersion) == digest, .integrity) }
                    if record.targetVersion > record.sourceVersion { try candidate.validateUpgradeDefaults(from: record.sourceVersion) }
                    if let digest = descriptor.baseDataSHA256 { try require(try candidate.baseDataDigest() == digest, .integrity) }
                    try hit(.afterSchemaCommit)
                    try record.advance(.schemaMigrated); try JournalStore.save(record, to: journalURL)
                }
                let candidateBarrier = try DatabaseSnapshotBarrier(store: candidate)
                defer { withExtendedLifetime(candidateBarrier) {} }
                try candidate.requirePortableRecycleEmpty()
                _ = try PortableInstance.validateFileEffectHostBoundary(stage, version: candidate.schemaVersion(), store: candidate)
                if record.phase == .schemaMigrated {
                    try candidate.validate(expectedVersion:record.targetVersion)
                    if let digest=descriptor.baseDataSHA256 { try require(try candidate.baseDataDigest()==digest,.integrity) }
                    if record.sourceVersion == record.targetVersion, let digest=descriptor.contentSHA256 {
                        try require(try candidate.contentDigest()==digest,.integrity)
                    } else {
                        if let digest=descriptor.contentSHA256 { try require(try candidate.contentDigest(asVersion:record.sourceVersion)==digest,.integrity) }
                        try candidate.validateUpgradeDefaults(from:record.sourceVersion)
                    }
                    try candidate.installAppRoles()
                    if record.targetVersion != record.sourceVersion {
                        let dump = try SafeFS.resolve(stage, "state/platform.pgdump")
                        if FileManager.default.fileExists(atPath: dump.path) { try FileManager.default.removeItem(at: dump) }
                        try candidate.snapshot(to: dump)
                        try PortableInstance.writeDatabaseDescriptor(stage, store: candidate)
                        for app in SampleApp.allCases {
                            try SafeFS.write(PluginManifest.sample(app.rawValue, dataSchema: record.targetVersion), to: SafeFS.resolve(stage,"apps/\(app.rawValue)/manifest.json"))
                            try SafeFS.write(["dataSchema":String(record.targetVersion),"schema":app.schema],to:SafeFS.resolve(stage,"app-data/\(app.rawValue)/schema.json"))
                        }
                        try PortableInstance.seal(stage, exportID: record.outputExportID, parentExportID: manifest.exportID)
                    }
                    _ = try PortableInstance.verify(stage)
                    try candidate.setDefaultReadOnly()
                    for dir in ["host-binding", "restore"] {
                        try FileManager.default.createDirectory(at: SafeFS.resolve(stage,dir),withIntermediateDirectories:true)
                    }
                    var binding = HostBinding(hostID: hostID); binding.databaseName = candidate.databaseName; binding.migrationID = record.transactionID
                    try SafeFS.write(binding,to:SafeFS.resolve(stage,"host-binding/binding.json"))
                    try record.advance(.needsAuth); try JournalStore.save(record,to:journalURL)
                    try saveLocalReport(record,destination:stage)
                }
                try require(record.phase == .needsAuth, .staleState)
                try validatePublished(stage,record:record)
                try hit(.beforePublish)
                try candidateBarrier.check()
                try PortableInstance.requirePortableFileEffectsDisabled(stage, store: candidate)
                if kind == .schemaUpgrade { try PortableInstance.requirePortableFileEffectsDisabled(source, store: PortableInstance.store(source)) }
                try PortableInstance.publish(stage,destination)
                try hit(.afterPublish)
                try record.advance(.publishedReadOnly); try JournalStore.save(record,to:journalURL)
                try saveLocalReport(record,destination:destination)
                return record
            } catch {
                record.failureCode = (error as? NASError)?.rawValue ?? "invalidInputOrIO"; record.event("interrupted-or-failed")
                try? JournalStore.save(record,to:journalURL)
                throw error
            }
        }
    }
    static func validatePublished(_ root: URL, record: MigrationTransaction) throws {
        let manifest = try PortableInstance.verify(root)
        try require(manifest.exportID == record.outputExportID && manifest.instanceID == record.instanceID, .integrity)
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root,"host-binding/binding.json"))
        try require(binding.hostID == record.hostID && binding.mode == "read_only_recovery" && binding.databaseName == record.databaseName && binding.migrationID == record.transactionID, .integrity)
        let store = try StateStore(databaseName: record.databaseName)
        try require(try store.attestation() == record.databaseAttestation, .integrity)
        try store.validate(expectedVersion:record.targetVersion)
        let barrier = try DatabaseSnapshotBarrier(store: store)
        defer { withExtendedLifetime(barrier) {} }
        try PortableInstance.requirePortableFileEffectsDisabled(root, store: store)
        try require(try store.rows("SHOW default_transaction_read_only;") == [["on"]],.denied)
        let descriptor = try PortableInstance.databaseDescriptor(root)
        if let digest = descriptor.contentSHA256 { try require(try store.contentDigest() == digest,.integrity) }
    }
    static func saveLocalReport(_ record: MigrationTransaction, destination: URL) throws {
        try SafeFS.write(["phase":record.phase.rawValue,"exportID":record.outputExportID.uuidString,"mode":record.phase == .rolledBack ? "rolled_back_recovery" : "read_only_recovery"],to:SafeFS.resolve(destination,"restore/journal.json"))
        try JournalStore.save(record,to:SafeFS.resolve(destination,"restore/transaction.json"))
    }
    @discardableResult public static func rollback(destination: URL, confirm: Bool = false) throws -> MigrationTransaction {
        if !confirm { return try status(destination:destination) }
        let lock = try InstanceLock(file:SafeFS.resolve(destination.deletingLastPathComponent(),".\(destination.lastPathComponent).macnas-migration.lock"))
        return try withExtendedLifetime(lock) {
            var record = try JournalStore.load(destination)
            guard confirm else { return record }
            let candidate = try StateStore(databaseName:record.databaseName)
            var recycleBarrier: DatabaseSnapshotBarrier?
            defer { withExtendedLifetime(recycleBarrier) {} }
            if try candidate.exists() {
                try require(try candidate.attestation() == record.databaseAttestation,.integrity)
                if try candidate.tableCount() > 0 {
                    // Validate the actual complete schema before treating an older version
                    // marker as legacy; a damaged marker must not hide newer persistent tables.
                    try candidate.validate()
                    if try candidate.schemaVersion() >= 4 { recycleBarrier = try DatabaseSnapshotBarrier(store: candidate) }
                    try candidate.requirePortableRecycleEmpty()
                    let root = FileManager.default.fileExists(atPath: destination.path) ? destination : try SafeFS.resolve(destination.deletingLastPathComponent(), record.stagingName)
                    if FileManager.default.fileExists(atPath: root.path) { try PortableInstance.requirePortableFileEffectsDisabled(root, store: candidate) }
                }
                try candidate.setDefaultReadOnly()
            }
            if record.phase != .rolledBack { try record.advance(.rolledBack); try JournalStore.save(record,to:JournalStore.url(destination)) }
            if FileManager.default.fileExists(atPath:destination.path) {
                var binding = try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(destination,"host-binding/binding.json"))
                try require(binding.migrationID == record.transactionID && binding.databaseName == record.databaseName,.integrity)
                binding.mode = "rolled_back_recovery"
                try SafeFS.write(binding,to:SafeFS.resolve(destination,"host-binding/binding.json"))
                try saveLocalReport(record,destination:destination)
            }
            return record
        }
    }
}
