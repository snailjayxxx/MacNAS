import Foundation

/// Trusted synthetic-host persistence only. These values confer no filesystem approval or execution capability.
struct FileEffectJournalScope: Sendable {
    let instanceID: UUID
    let generation: Int64
    let userID: Data
    let originScopeSHA256: String
}

enum FileEffectDirection: String, Codable, Sendable { case recycle, restore }
enum FileEffectPhase: String, Codable, Sendable { case prepared, armed, observed, completed, uncertain, cancelled }
enum FileEffectCharge: String, Codable, Sendable { case reserved, retained, released }

struct FileEffectIntent: Codable, Sendable {
    var intentVersion = 1
    var kind: FileEffectDirection
    var libraryID: String
    var sourcePath: String
    var targetParentPath: String
    var name: String

    func validate() throws {
        try require(intentVersion == 1, .invalidSchema)
        try FileEffectMetadata.text(libraryID, maximum: 128)
        try FileEffectMetadata.path(sourcePath)
        try FileEffectMetadata.path(targetParentPath, empty: true)
        try FileEffectMetadata.text(name, maximum: 255)
        try require(!name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && !name.contains("/") && !name.contains("\\") && !name.contains(":") && name != "." && name != "..", .unsafePath)
        try FileEffectMetadata.path(targetParentPath.isEmpty ? name : targetParentPath + "/" + name)
        if kind == .recycle {
            try require(targetParentPath.isEmpty && Data(name.utf8) == Data(sourcePath.split(separator: "/").last!.utf8), .invalidSchema)
        }
        try require(try FileEffectMetadata.encoded(self).count <= 4096, .budgetExceeded)
    }
}

struct FileEffectStamp: Codable, Equatable, Sendable {
    var device: String
    var inode: String
    var mode: Int64
    var uid: Int64
    var links: Int64
    var bytes: Int64
    var mtimeSeconds: String
    var mtimeNanos: Int64
    var ctimeSeconds: String
    var ctimeNanos: Int64

    func validate(directory: Bool) throws {
        try FileEffectMetadata.unsignedDecimal(device)
        try FileEffectMetadata.unsignedDecimal(inode)
        try FileEffectMetadata.signedDecimal(mtimeSeconds)
        try FileEffectMetadata.signedDecimal(ctimeSeconds)
        try require((0...65535).contains(mode) && (0...Int64(UInt32.max)).contains(uid) && (1...Int64(UInt32.max)).contains(links), .invalidSchema)
        try require((0...9_007_199_254_740_991).contains(bytes) && (0...999_999_999).contains(mtimeNanos) && (0...999_999_999).contains(ctimeNanos), .invalidSchema)
        try require(mode & 0o170000 == (directory ? 0o040000 : 0o100000), .unsafeFile)
        if !directory { try require(links == 1, .unsafeFile) }
    }
}

struct FileEffectEvidence: Codable, Sendable {
    var evidenceVersion = 1
    var object: FileEffectStamp
    var sourceParent: FileEffectStamp
    var targetParent: FileEffectStamp
    var sha256: String

    func validate(bytes: Int64) throws {
        try require(evidenceVersion == 1, .invalidSchema)
        try object.validate(directory: false); try sourceParent.validate(directory: true); try targetParent.validate(directory: true)
        try require(object.bytes == bytes && object.device == sourceParent.device && object.device == targetParent.device, .unsafeFile)
        try FileEffectMetadata.hash(sha256)
        try require(try FileEffectMetadata.encoded(self).count <= 2048, .budgetExceeded)
    }
}

enum FileEffectMetadata {
    static func encoded<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    /// Unlike ordinary Codable decoding this rejects unknown/missing keys, including nested stamp keys.
    static func decode<T: Codable>(_ type: T.Type, from bytes: Data) throws -> T {
        try require(bytes.count <= 8192 && String(data: bytes, encoding: .utf8) != nil, .invalidSchema)
        do {
            let value = try JSONDecoder().decode(type, from: bytes)
            let original = try JSONSerialization.jsonObject(with: bytes) as? NSObject
            let canonical = try JSONSerialization.jsonObject(with: encoded(value)) as? NSObject
            try require(original == canonical, .invalidSchema)
            return value
        } catch { throw NASError.invalidSchema }
    }
    static func text(_ value: String, maximum: Int, empty: Bool = false) throws {
        try require((empty || !value.isEmpty) && value.utf8.count <= maximum && !value.contains("\0") && !value.contains("\n") && !value.contains("\r"), .invalidSchema)
    }
    static func subject(_ value: Data) throws {
        guard let text = String(data: value, encoding: .utf8) else { throw NASError.invalidSchema }
        try Self.text(text, maximum: 128)
    }
    static func path(_ value: String, empty: Bool = false) throws {
        try text(value, maximum: 4096, empty: empty)
        if empty && value.isEmpty { return }
        try SafeFS.relative(value)
        let components = value.split(separator: "/")
        try require(components.count <= 128 && components.allSatisfy {
            $0.utf8.count <= 255 && !String($0).trimmingCharacters(in: CharacterSet(charactersIn: " ")).isEmpty
        }, .unsafePath)
    }
    static func hash(_ value: String) throws {
        try require(value.utf8.count == 64 && value.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }, .invalidSchema)
    }
    static func unsignedDecimal(_ value: String) throws {
        guard let number = UInt64(value), String(number) == value else { throw NASError.invalidSchema }
    }
    static func signedDecimal(_ value: String) throws {
        guard let number = Int64(value), String(number) == value else { throw NASError.invalidSchema }
    }
    static func hex(_ value: Data) -> String { value.map { String(format: "%02x", $0) }.joined() }
    static func bytesSQL(_ value: Data) -> String { "decode('\(hex(value))','hex')" }
    static func uuidSQL(_ value: UUID) -> String { "'\(value.uuidString.lowercased())'::uuid" }
    static func jsonSQL<T: Encodable>(_ value: T) throws -> String { try StateStore.quote(String(decoding: encoded(value), as: UTF8.self)) + "::jsonb" }
}

struct FileEffectJournalRecord: Codable, Equatable, Sendable {
    let operationID: UUID
    let entryID: UUID
    let kind: FileEffectDirection
    let phase: FileEffectPhase
    let revision: Int64
    let entryRevision: Int64
    let chargeState: FileEffectCharge
    let chargedBytes: Int64
    let ownerUserHex: String
    let intentSHA256: String
}

/// Persistent metadata only. Registered execution needs live permits and coordinator-only filesystem witnesses.
/// Unregistered A paths remain SQL-only; this class does not create vaults or move files.
final class DurableFileEffectJournal {
    static let fileBytes: Int64 = 16 * 1024 * 1024
    static let retainedBytes: Int64 = 64 * 1024 * 1024
    private let store: StateStore
    private let scope: FileEffectJournalScope
    private let root: URL
    private let databaseVersion: Int
    private let physicalAccess: PhysicalCapacityLegacyAccess?

    init(store: StateStore, scope: FileEffectJournalScope, physicalAccess: PhysicalCapacityLegacyAccess? = nil) throws {
        self.physicalAccess = physicalAccess
        databaseVersion = try store.schemaVersion()
        try require([4,5,6].contains(databaseVersion), .unsupported); try store.validate(expectedVersion: databaseVersion)
        try require(scope.generation >= 0, .invalidSchema); try FileEffectMetadata.subject(scope.userID); try FileEffectMetadata.hash(scope.originScopeSHA256)
        guard let root = store.instanceRoot else { throw NASError.denied }
        self.store = store; self.scope = scope; self.root = root
        try validateScope(write: false)
    }
    private func validateScope(write: Bool) throws {
        if let physicalAccess {
            try require(physicalAccess.root == root && physicalAccess.userID == scope.userID && databaseVersion == 6
                        && (!write || physicalAccess.purpose.writes), .denied)
            try physicalAccess.check()
        } else {
            try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(FixturePhysicalCapacityNamespace.markerPath).path), .unsupported)
            if databaseVersion >= 6 {
                try require(try store.rows("SELECT EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes);") == [["f"]], .unsupported)
            }
        }
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        try require(identity.schemaVersion == 1 && identity.instanceID == scope.instanceID && identity.generation == scope.generation && identity.kind == "synthetic-prototype", .denied)
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        guard let user = config.users.first(where: { Data($0.id.utf8) == scope.userID }) else { throw NASError.denied }
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        try require(binding.databaseName == store.databaseName && !binding.hostID.isEmpty && binding.hostID.utf8.count <= 256 && !binding.hostID.contains("\0"), .denied)
        try require(["administrator", "reader"].contains(user.role) && ["synthetic_development", "read_only_recovery", "rolled_back_recovery"].contains(binding.mode), .denied)
        try require(try PortableInstance.databaseDescriptor(root).version() == databaseVersion && store.schemaVersion() == databaseVersion, .invalidSchema)
        if write { try require(user.role == "administrator" && binding.mode == "synthetic_development", .denied) }
    }
    private var instanceSQL: String { FileEffectMetadata.uuidSQL(scope.instanceID) }
    private var actorSQL: String { FileEffectMetadata.bytesSQL(scope.userID) }
    private var ownerPredicate: String { "o.instance_id=\(instanceSQL) AND o.actor_user_utf8=\(actorSQL) AND e.owner_user_utf8=\(actorSQL)" }
    private static let resultSQL = "jsonb_build_object('operationID',o.operation_id,'entryID',o.entry_id,'kind',o.kind,'phase',o.phase,'revision',o.revision,'entryRevision',e.revision,'chargeState',e.charge_state,'chargedBytes',CASE WHEN e.charge_state='released' THEN 0 ELSE e.byte_count END,'ownerUserHex',encode(e.owner_user_utf8,'hex'),'intentSHA256',o.intent_sha256)"
    private struct Reply: Decodable { var record: FileEffectJournalRecord?; var error: NASError? }
    private func decode(_ output: String) throws -> FileEffectJournalRecord? {
        let reply = try JSONDecoder().decode(Reply.self, from: Data(output.utf8))
        if let error = reply.error { throw error }; return reply.record
    }
    private static func reject(_ error: NASError) -> String { "INSERT INTO effect_result VALUES(jsonb_build_object('error','\(error.rawValue)')); RETURN;" }
    private var capacityMetadataReserve: String {
        let base = databaseVersion >= 5 ? "+(SELECT count(*)*3072 FROM macnas.capacity_scopes)+(SELECT count(*)*2048 FROM macnas.capacity_allocations)" : ""
        return base + (databaseVersion >= 6 ? "+(SELECT count(*)*3072 FROM macnas.physical_capacity_scopes)+(SELECT count(*)*2048 FROM macnas.capacity_file_ownership)" : "")
    }
    private var budgetGuard: String {
        """
        IF (SELECT count(*) FROM macnas.recycle_entries)>64 OR (SELECT count(*) FROM macnas.file_effect_operations)>256 OR
          ((\(StateStore.legacyMetadataBytesSQL)) + (SELECT count(*)*4096 FROM macnas.recycle_entries) + (SELECT count(*)*8192 FROM macnas.file_effect_operations) + 4096\(capacityMetadataReserve))>4000000
        THEN \(Self.reject(.budgetExceeded)) END IF;
        """
    }
    private func mutation(_ body: String) throws -> FileEffectJournalRecord {
        try store.withMutation {
            try validateScope(write: true)
            let delimiter = "$effect_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "$"
            try require(!body.contains(delimiter), .invalidSchema)
            let sql = """
            BEGIN;
            SET LOCAL synchronous_commit='on';
            SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms';
            CREATE TEMP TABLE effect_result(value jsonb) ON COMMIT DROP;
            DO \(delimiter)
            DECLARE e macnas.recycle_entries%ROWTYPE; o macnas.file_effect_operations%ROWTYPE;
            BEGIN
              IF current_setting('synchronous_commit')<>'on' OR current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
              THEN \(Self.reject(.denied)) END IF;
              PERFORM pg_advisory_xact_lock(786029,4);
              \(body)
            END \(delimiter);
            SELECT value::text FROM effect_result;
            COMMIT;
            """
            guard let result = try decode(store.tools.sql(sql, database: store.databaseName)) else { throw NASError.integrity }
            // A failure here rejects the changed context; the transaction may already have committed. Never compensate or retry its effect.
            try validateScope(write: true)
            return result
        }
    }
    private func input(_ key: Data, _ intent: FileEffectIntent, _ evidence: FileEffectEvidence, bytes: Int64) throws -> (String, String, String) {
        try FileEffectMetadata.subject(key); try intent.validate()
        try require((0...Self.fileBytes).contains(bytes), .budgetExceeded); try evidence.validate(bytes: bytes)
        let intentSQL = try FileEffectMetadata.jsonSQL(intent)
        return (intentSQL, "encode(sha256(convert_to((\(intentSQL))::text,'UTF8')),'hex')", try FileEffectMetadata.jsonSQL(evidence))
    }
    @discardableResult
    func prepareRecycle(key: Data, intent: FileEffectIntent, volumeID: UUID, vaultID: UUID, byteCount: Int64,
                        evidence: FileEffectEvidence, operationID: UUID = UUID(), entryID: UUID = UUID(), payloadID: UUID = UUID(),
                        executorPermit: FileEffectExecutionPermit? = nil) throws -> FileEffectJournalRecord {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(RecycleVault.registrationPath).path) {
            guard let executorPermit else { throw NASError.unsupported }
            try requireExecutor(executorPermit, action: .recycle)
            try require(volumeID == executorPermit.registration.volumeID && vaultID == executorPermit.registration.vaultID
                        && Data(intent.libraryID.utf8) == Data(executorPermit.registration.libraryID.utf8)
                        && scope.originScopeSHA256 == executorPermit.originScopeSHA256
                        && executorPermit.registration.slots.contains { $0.id == payloadID }, .denied)
        }
        try physicalAccess?.checkIntent(intent)
        try require(intent.kind == .recycle, .invalidSchema)
        let (intentSQL, intentHash, evidenceSQL) = try input(key, intent, evidence, bytes: byteCount)
        let keySQL = FileEffectMetadata.bytesSQL(key), operationSQL = FileEffectMetadata.uuidSQL(operationID), entrySQL = FileEffectMetadata.uuidSQL(entryID)
        let body = """
        SELECT * INTO o FROM macnas.file_effect_operations WHERE instance_id=\(instanceSQL) AND actor_user_utf8=\(actorSQL) AND kind='recycle' AND idempotency_key_utf8=\(keySQL);
        IF FOUND THEN
          SELECT * INTO e FROM macnas.recycle_entries WHERE entry_id=o.entry_id;
          IF o.intent<>\(intentSQL) OR o.intent_sha256<>\(intentHash) OR o.pre_evidence<>\(evidenceSQL) OR e.byte_count<>\(byteCount) OR e.volume_id<>\(FileEffectMetadata.uuidSQL(volumeID)) OR e.vault_id<>\(FileEffectMetadata.uuidSQL(vaultID)) THEN \(Self.reject(.collision)) END IF;
          INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL))); RETURN;
        END IF;
        IF EXISTS(SELECT 1 FROM macnas.file_effect_operations WHERE operation_id=\(operationSQL)) OR EXISTS(SELECT 1 FROM macnas.recycle_entries WHERE entry_id=\(entrySQL)) THEN \(Self.reject(.collision)) END IF;
        IF EXISTS(SELECT 1 FROM macnas.recycle_entries WHERE instance_id=\(instanceSQL) AND volume_id=\(FileEffectMetadata.uuidSQL(volumeID)) AND vault_id=\(FileEffectMetadata.uuidSQL(vaultID)) AND payload_id=\(FileEffectMetadata.uuidSQL(payloadID))) THEN \(Self.reject(.collision)) END IF;
        IF (SELECT count(*) FROM macnas.recycle_entries)>=64 OR (SELECT count(*) FROM macnas.file_effect_operations)>=256 OR (SELECT count(*) FROM macnas.file_effect_operations WHERE phase NOT IN ('completed','cancelled'))>=8 OR
           (SELECT coalesce(sum(byte_count) FILTER(WHERE charge_state<>'released'),0) FROM macnas.recycle_entries)+\(byteCount)>\(Self.retainedBytes) THEN \(Self.reject(.budgetExceeded)) END IF;
        IF ((\(StateStore.legacyMetadataBytesSQL))+(SELECT count(*)*4096 FROM macnas.recycle_entries)+4096+(SELECT count(*)*8192 FROM macnas.file_effect_operations)+8192+4096\(capacityMetadataReserve))>4000000 THEN \(Self.reject(.budgetExceeded)) END IF;
        e.entry_id:=\(entrySQL); e.entry_version:=1; e.instance_id:=\(instanceSQL); e.origin_generation:=\(scope.generation); e.owner_user_utf8:=\(actorSQL);
        e.library_id_utf8:=\(FileEffectMetadata.bytesSQL(Data(intent.libraryID.utf8))); e.original_path_utf8:=\(FileEffectMetadata.bytesSQL(Data(intent.sourcePath.utf8)));
        e.volume_id:=\(FileEffectMetadata.uuidSQL(volumeID)); e.vault_id:=\(FileEffectMetadata.uuidSQL(vaultID)); e.payload_id:=\(FileEffectMetadata.uuidSQL(payloadID));
        e.byte_count:=\(byteCount); e.sha256:='\(evidence.sha256)'; e.charge_state:='reserved'; e.active_operation_id:=\(operationSQL); e.revision:=1; e.created_at:=clock_timestamp(); e.retain_until:=e.created_at+interval '30 days';
        \(newOperationSQL(operationID, entryID: entryID, keySQL: keySQL, intentSQL: intentSQL, intentHash: intentHash, evidenceSQL: evidenceSQL, kind: .recycle))
        IF octet_length(convert_to(to_jsonb(e)::text,'UTF8'))+32>4096 OR octet_length(convert_to(to_jsonb(o)::text,'UTF8'))+2048+1024>8192 THEN \(Self.reject(.budgetExceeded)) END IF;
        INSERT INTO macnas.recycle_entries SELECT e.*; INSERT INTO macnas.file_effect_operations SELECT o.*;
        INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL)));
        """
        let result = try mutation(body)
        if let executorPermit { try requireExecutor(executorPermit, action: .recycle) }
        return result
    }
    private func newOperationSQL(_ id: UUID, entryID: UUID, keySQL: String, intentSQL: String, intentHash: String, evidenceSQL: String, kind: FileEffectDirection) -> String {
        """
        o.operation_id:=\(FileEffectMetadata.uuidSQL(id)); o.operation_version:=1; o.entry_id:=\(FileEffectMetadata.uuidSQL(entryID)); o.instance_id:=\(instanceSQL); o.origin_generation:=\(scope.generation);
        o.actor_user_utf8:=\(actorSQL); o.idempotency_key_utf8:=\(keySQL); o.kind:='\(kind.rawValue)'; o.intent:=\(intentSQL); o.intent_sha256:=\(intentHash); o.origin_scope_sha256:='\(scope.originScopeSHA256)';
        o.pre_evidence:=\(evidenceSQL); o.phase:='prepared'; o.revision:=1; o.prepared_at:=clock_timestamp();
        """
    }
    @discardableResult
    func prepareRestore(entryID: UUID, expectedEntryRevision: Int64, key: Data, intent: FileEffectIntent, evidence: FileEffectEvidence,
                        operationID: UUID = UUID(), executorPermit: FileEffectExecutionPermit? = nil) throws -> FileEffectJournalRecord {
        if FileManager.default.fileExists(atPath: root.appendingPathComponent(RecycleVault.registrationPath).path) {
            guard let executorPermit else { throw NASError.unsupported }
            try requireExecutor(executorPermit, action: .restore)
            try require(Data(intent.libraryID.utf8) == Data(executorPermit.registration.libraryID.utf8)
                        && Data(intent.targetParentPath.utf8) == executorPermit.destinationParentPath
                        && scope.originScopeSHA256 == executorPermit.originScopeSHA256, .denied)
        }
        try physicalAccess?.checkIntent(intent, entryID: entryID)
        try require(intent.kind == .restore && expectedEntryRevision > 0, .invalidSchema)
        let (intentSQL, intentHash, evidenceSQL) = try input(key, intent, evidence, bytes: evidence.object.bytes)
        let entrySQL = FileEffectMetadata.uuidSQL(entryID), operationSQL = FileEffectMetadata.uuidSQL(operationID), keySQL = FileEffectMetadata.bytesSQL(key)
        let result = try mutation("""
        SELECT * INTO o FROM macnas.file_effect_operations WHERE instance_id=\(instanceSQL) AND actor_user_utf8=\(actorSQL) AND kind='restore' AND idempotency_key_utf8=\(keySQL);
        IF FOUND THEN
          IF o.entry_id<>\(entrySQL) OR o.intent<>\(intentSQL) OR o.intent_sha256<>\(intentHash) OR o.pre_evidence<>\(evidenceSQL) THEN \(Self.reject(.collision)) END IF;
          SELECT * INTO e FROM macnas.recycle_entries WHERE entry_id=o.entry_id;
          INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL))); RETURN;
        END IF;
        SELECT * INTO e FROM macnas.recycle_entries WHERE entry_id=\(entrySQL) AND instance_id=\(instanceSQL) AND owner_user_utf8=\(actorSQL) FOR UPDATE;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        \(executorPermit.map { p in "IF e.vault_id<>\(FileEffectMetadata.uuidSQL(p.registration.vaultID)) OR e.volume_id<>\(FileEffectMetadata.uuidSQL(p.registration.volumeID)) OR e.payload_id NOT IN (\(p.registration.slots.map { FileEffectMetadata.uuidSQL($0.id) }.joined(separator: ","))) THEN \(Self.reject(.denied)) END IF;" } ?? "")
        IF e.revision<>\(expectedEntryRevision) OR e.charge_state<>'retained' OR e.active_operation_id IS NOT NULL THEN \(Self.reject(.staleState)) END IF;
        IF e.origin_generation<>\(scope.generation) OR e.library_id_utf8<>\(FileEffectMetadata.bytesSQL(Data(intent.libraryID.utf8))) OR e.original_path_utf8<>\(FileEffectMetadata.bytesSQL(Data(intent.sourcePath.utf8))) OR e.byte_count<>\(evidence.object.bytes) OR e.sha256<>'\(evidence.sha256)' THEN \(Self.reject(.staleState)) END IF;
        IF EXISTS(SELECT 1 FROM macnas.file_effect_operations WHERE operation_id=\(operationSQL)) THEN \(Self.reject(.collision)) END IF;
        IF (SELECT count(*) FROM macnas.file_effect_operations)>=256 OR (SELECT count(*) FROM macnas.file_effect_operations WHERE phase NOT IN ('completed','cancelled'))>=8 THEN \(Self.reject(.budgetExceeded)) END IF;
        IF ((\(StateStore.legacyMetadataBytesSQL))+(SELECT count(*)*4096 FROM macnas.recycle_entries)+(SELECT count(*)*8192 FROM macnas.file_effect_operations)+8192+4096\(capacityMetadataReserve))>4000000 THEN \(Self.reject(.budgetExceeded)) END IF;
        \(newOperationSQL(operationID, entryID: entryID, keySQL: keySQL, intentSQL: intentSQL, intentHash: intentHash, evidenceSQL: evidenceSQL, kind: .restore))
        IF octet_length(convert_to(to_jsonb(o)::text,'UTF8'))+2048+1024>8192 OR e.revision=9223372036854775807 THEN \(Self.reject(.budgetExceeded)) END IF;
        e.active_operation_id:=\(operationSQL); e.revision:=e.revision+1;
        INSERT INTO macnas.file_effect_operations SELECT o.*; UPDATE macnas.recycle_entries SET active_operation_id=e.active_operation_id,revision=e.revision WHERE entry_id=e.entry_id;
        INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL)));
        """)
        if let executorPermit { try requireExecutor(executorPermit, action: .restore) }
        return result
    }
    func record(operationID: UUID) throws -> FileEffectJournalRecord? {
        try validateScope(write: false)
        let sql = "SELECT jsonb_build_object('record',(SELECT \(Self.resultSQL) FROM macnas.file_effect_operations o JOIN macnas.recycle_entries e USING(entry_id) WHERE o.operation_id=\(FileEffectMetadata.uuidSQL(operationID)) AND \(ownerPredicate)))::text;"
        let result = try decode(store.tools.sql(sql, database: store.databaseName)); try validateScope(write: false); return result
    }
    private func transition(operationID: UUID, expectedRevision: Int64, phase: FileEffectPhase, error: NASError? = nil) throws -> FileEffectJournalRecord {
        try require(expectedRevision > 0, .invalidSchema)
        let permitted: String
        switch phase {
        case .armed: permitted = "o.phase='prepared'"
        case .cancelled: permitted = "o.phase='prepared'"
        case .uncertain: permitted = "o.phase IN ('armed','observed','uncertain')"
        default: throw NASError.unsupported
        }
        let timestamp = phase == .armed ? ",armed_at=clock_timestamp()" : phase == .cancelled ? ",cancelled_at=clock_timestamp()" : ""
        let errorSQL = error.map { "'\($0.rawValue)'" } ?? "NULL"
        return try mutation("""
        SELECT * INTO o FROM macnas.file_effect_operations WHERE operation_id=\(FileEffectMetadata.uuidSQL(operationID)) AND instance_id=\(instanceSQL) AND actor_user_utf8=\(actorSQL) FOR UPDATE;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        SELECT * INTO e FROM macnas.recycle_entries WHERE entry_id=o.entry_id AND owner_user_utf8=\(actorSQL) FOR UPDATE;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        IF o.revision<>\(expectedRevision) OR NOT (\(permitted)) OR e.active_operation_id IS DISTINCT FROM o.operation_id OR o.origin_generation<>\(scope.generation) OR o.origin_scope_sha256<>'\(scope.originScopeSHA256)' THEN \(Self.reject(.staleState)) END IF;
        IF o.revision=9223372036854775807 OR e.revision=9223372036854775807 THEN \(Self.reject(.budgetExceeded)) END IF;
        \(budgetGuard)
        UPDATE macnas.file_effect_operations SET phase='\(phase.rawValue)',revision=revision+1,error_code=\(errorSQL)\(timestamp) WHERE operation_id=o.operation_id RETURNING * INTO o;
        \(phase == .cancelled ? "UPDATE macnas.recycle_entries SET charge_state=CASE WHEN o.kind='recycle' THEN 'released' ELSE charge_state END,active_operation_id=NULL,revision=revision+1 WHERE entry_id=e.entry_id RETURNING * INTO e;" : "")
        INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL)));
        """)
    }
    @discardableResult func arm(operationID: UUID, expectedRevision: Int64) throws -> FileEffectJournalRecord {
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(RecycleVault.registrationPath).path), .unsupported)
        return try transition(operationID: operationID, expectedRevision: expectedRevision, phase: .armed)
    }
    /// A-stage only: there is no executor. B must supply live approval, vault lock and positive no-effect proof before calling a cancellation path.
    @discardableResult func cancelPreparedWithoutExecutor(operationID: UUID, expectedRevision: Int64) throws -> FileEffectJournalRecord {
        try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(RecycleVault.registrationPath).path), .unsupported)
        return try transition(operationID: operationID, expectedRevision: expectedRevision, phase: .cancelled)
    }
    @discardableResult func markUncertain(operationID: UUID, expectedRevision: Int64, error: NASError) throws -> FileEffectJournalRecord {
        try require([NASError.unsafeFile,.staleState,.denied,.expired,.integrity,.database,.interrupted,.unsupported,.missingVolume,.timedOut,.collision,.budgetExceeded].contains(error), .invalidSchema)
        return try transition(operationID: operationID, expectedRevision: expectedRevision, phase: .uncertain, error: error)
    }
}

/// B's bounded, owner-scoped execution read; no path access or authority is obtained from this row.
struct FileEffectExecutionSnapshot: Codable {
    let record: FileEffectJournalRecord
    let intent: FileEffectIntent
    let preEvidence: FileEffectEvidence
    let postEvidence: FileEffectEvidence?
    let volumeID: UUID
    let vaultID: UUID
    let payloadID: UUID
    let originScopeSHA256: String
    let activeOperationID: UUID?
}

/// Read evidence only. Construction is confined to this file after one consistent
/// PostgreSQL canonical-json digest check; it authorizes no mutation or execution.
struct ManagedRecycleIntentDigest {
    let operationID: UUID
    let sha256: String
    fileprivate init(operationID: UUID, sha256: String) { self.operationID = operationID; self.sha256 = sha256 }
}

extension DurableFileEffectJournal {
    func managedExecutionSnapshot(operationID: UUID) throws -> (FileEffectExecutionSnapshot?, ManagedRecycleIntentDigest?) {
        try require(physicalAccess?.purpose == .managedObserve, .denied)
        try validateScope(write: false)
        let sql = """
        BEGIN READ ONLY; SET LOCAL statement_timeout='10000ms';
        SELECT coalesce((SELECT jsonb_build_object('snapshot',jsonb_build_object('record',\(Self.resultSQL),
          'intent',o.intent,'preEvidence',o.pre_evidence,'postEvidence',o.post_evidence,
          'volumeID',e.volume_id,'vaultID',e.vault_id,'payloadID',e.payload_id,
          'originScopeSHA256',o.origin_scope_sha256,'activeOperationID',e.active_operation_id),
          'intentVerified',o.intent_sha256=encode(sha256(convert_to(o.intent::text,'UTF8')),'hex'))
          FROM macnas.file_effect_operations o JOIN macnas.recycle_entries e USING(entry_id)
          WHERE o.operation_id=\(FileEffectMetadata.uuidSQL(operationID)) AND \(ownerPredicate)),
          jsonb_build_object('snapshot',NULL,'intentVerified',true))::text; COMMIT;
        """
        let output = try store.tools.sql(sql, database: store.databaseName)
        try require(output.utf8.count <= 16384, .budgetExceeded)
        struct Reply: Decodable { let snapshot: FileEffectExecutionSnapshot?; let intentVerified: Bool }
        let reply = try JSONDecoder().decode(Reply.self, from: Data(output.utf8))
        try require(reply.intentVerified, .integrity)
        let proof: ManagedRecycleIntentDigest?
        if let snapshot = reply.snapshot {
            try snapshot.intent.validate(); try snapshot.preEvidence.validate(bytes: snapshot.preEvidence.object.bytes)
            try snapshot.postEvidence?.validate(bytes: snapshot.preEvidence.object.bytes)
            try FileEffectMetadata.hash(snapshot.originScopeSHA256); try FileEffectMetadata.hash(snapshot.record.intentSHA256)
            try require(snapshot.record.operationID == operationID && snapshot.intent.kind == snapshot.record.kind
                        && snapshot.record.ownerUserHex == FileEffectMetadata.hex(scope.userID), .denied)
            proof = .init(operationID: operationID, sha256: snapshot.record.intentSHA256)
        } else { proof = nil }
        try validateScope(write: false); return (reply.snapshot, proof)
    }
    func executionSnapshot(operationID: UUID) throws -> FileEffectExecutionSnapshot? {
        try validateScope(write: false)
        let sql = """
        BEGIN READ ONLY; SET LOCAL statement_timeout='10000ms';
        SELECT jsonb_build_object('snapshot',(SELECT jsonb_build_object('record',\(Self.resultSQL),
          'intent',o.intent,'preEvidence',o.pre_evidence,'postEvidence',o.post_evidence,
          'volumeID',e.volume_id,'vaultID',e.vault_id,'payloadID',e.payload_id,'originScopeSHA256',o.origin_scope_sha256,'activeOperationID',e.active_operation_id)
          FROM macnas.file_effect_operations o JOIN macnas.recycle_entries e USING(entry_id)
          WHERE o.operation_id=\(FileEffectMetadata.uuidSQL(operationID)) AND \(ownerPredicate)))::text; COMMIT;
        """
        let output = try store.tools.sql(sql, database: store.databaseName)
        try require(output.utf8.count <= 16384, .budgetExceeded)
        struct Reply: Decodable { var snapshot: FileEffectExecutionSnapshot? }
        let snapshot = try JSONDecoder().decode(Reply.self, from: Data(output.utf8)).snapshot
        if let snapshot {
            try snapshot.intent.validate(); try snapshot.preEvidence.validate(bytes: snapshot.preEvidence.object.bytes)
            try require(snapshot.intent.kind == snapshot.record.kind, .invalidSchema)
            try snapshot.postEvidence?.validate(bytes: snapshot.preEvidence.object.bytes)
            try FileEffectMetadata.hash(snapshot.originScopeSHA256)
            try require(snapshot.record.ownerUserHex == FileEffectMetadata.hex(scope.userID), .denied)
        }
        try validateScope(write: false); return snapshot
    }
    func retainedEntry(entryID: UUID) throws -> FileEffectExecutionSnapshot? {
        try validateScope(write: false)
        let rows = try store.rows("SELECT o.operation_id::text FROM macnas.file_effect_operations o JOIN macnas.recycle_entries e USING(entry_id) WHERE e.entry_id=\(FileEffectMetadata.uuidSQL(entryID)) AND \(ownerPredicate) AND e.charge_state='retained' AND e.active_operation_id IS NULL AND o.kind='recycle' AND o.phase='completed' LIMIT 2;")
        try require(rows.count <= 1, .integrity)
        guard let id = rows.first?.first.flatMap(UUID.init(uuidString:)) else { return nil }
        let result = try executionSnapshot(operationID: id)
        try require(result?.record.chargeState == .retained && result?.activeOperationID == nil, .staleState)
        return result
    }
    private func requireExecutor(_ permit: FileEffectExecutionPermit, action: RecycleHostAction,
                                 snapshot: FileEffectExecutionSnapshot? = nil) throws {
        try permit.check(action)
        let registered = permit.registration
        try require(registered.instanceID == scope.instanceID && registered.generation == scope.generation
                    && registered.databaseName == store.databaseName && permit.userID == scope.userID, .denied)
        if let snapshot {
            let direction: RecycleHostAction = snapshot.record.kind == .recycle ? .recycle : .restore
            if action == .recycle || action == .restore { try require(action == direction, .denied) }
            if snapshot.record.kind == .restore && [RecycleHostAction.restore, .settle].contains(action) {
                try require(Data(snapshot.intent.targetParentPath.utf8) == permit.destinationParentPath, .denied)
                guard let target = permit.destinationParentStamp else { throw NASError.denied }
                try require(RecycleDirectory.sameIdentity(target, snapshot.preEvidence.targetParent), .staleState)
            }
            try require(snapshot.vaultID == registered.vaultID
                        && snapshot.volumeID == registered.volumeID
                        && Data(snapshot.intent.libraryID.utf8) == Data(registered.libraryID.utf8), .denied)
        }
    }
    func armForExecutor(_ permit: FileEffectExecutionPermit, snapshot: FileEffectExecutionSnapshot) throws -> FileEffectJournalRecord {
        let action: RecycleHostAction = snapshot.record.kind == .recycle ? .recycle : .restore
        try requireExecutor(permit, action: action, snapshot: snapshot)
        try require(snapshot.originScopeSHA256 == permit.originScopeSHA256, .staleState)
        let result = try transition(operationID: snapshot.record.operationID, expectedRevision: snapshot.record.revision, phase: .armed)
        try requireExecutor(permit, action: action, snapshot: snapshot); return result
    }
    /// Unlike new admission, these bounded writes do not aggregate growing legacy metadata.
    /// prepared reserved3072 bytes for evidence/timestamps/reconciler; the exact final rows are rechecked here.
    /// This preserves an already-admitted effect's record, not a promise that future whole-DB digests fit4MB.
    private func executorTransition(_ permit: FileEffectExecutionPermit, snapshot: FileEffectExecutionSnapshot,
                                    target: FileEffectPhase, post: FileEffectEvidence? = nil, error: NASError? = nil) throws -> FileEffectJournalRecord {
        let action = permit.action
        try require([RecycleHostAction.recycle, .restore, .settle, .cancelPrepared].contains(action), .denied)
        try requireExecutor(permit, action: action, snapshot: snapshot)
        let allowed: String, change: String, entryChange: String
        switch target {
        case .observed:
            try require(action == (snapshot.record.kind == .recycle ? .recycle : .restore) && snapshot.originScopeSHA256 == permit.originScopeSHA256, .denied)
            guard let post else { throw NASError.invalidSchema }; try post.validate(bytes: snapshot.preEvidence.object.bytes)
            try require(post.sha256 == snapshot.preEvidence.sha256
                        && RecycleDirectory.sameStamp(post.object, snapshot.preEvidence.object, allowingRenameCTime: true)
                        && RecycleDirectory.sameIdentity(post.sourceParent, snapshot.preEvidence.sourceParent)
                        && RecycleDirectory.sameIdentity(post.targetParent, snapshot.preEvidence.targetParent), .integrity)
            allowed = "o.phase='armed' AND o.post_evidence IS NULL"
            change = "o.phase:='observed'; o.post_evidence:=\(try FileEffectMetadata.jsonSQL(post)); o.observed_at:=clock_timestamp(); o.error_code:=NULL;"
            entryChange = ""
        case .completed:
            try require(action == .recycle || action == .restore || action == .settle, .denied)
            guard let evidence = snapshot.postEvidence else { throw NASError.staleState }
            allowed = "o.phase IN ('observed','uncertain') AND o.post_evidence=\(try FileEffectMetadata.jsonSQL(evidence))"
            change = "o.phase:='completed'; o.source_parent_synced_at:=clock_timestamp(); o.target_parent_synced_at:=o.source_parent_synced_at; o.completed_at:=o.source_parent_synced_at; o.error_code:=NULL;"
                + (action == .settle ? "o.reconciler_user_utf8:=\(actorSQL); o.reconciled_at:=o.completed_at;" : "")
            entryChange = "e.charge_state:=CASE WHEN o.kind='recycle' THEN 'retained' ELSE 'released' END; e.active_operation_id:=NULL; e.revision:=e.revision+1;"
        case .cancelled:
            try require(action == .cancelPrepared, .denied)
            allowed = "o.phase='prepared' AND o.post_evidence IS NULL"
            change = "o.phase:='cancelled'; o.cancelled_at:=clock_timestamp(); o.error_code:=NULL;"
            entryChange = "e.charge_state:=CASE WHEN o.kind='recycle' THEN 'released' ELSE 'retained' END; e.active_operation_id:=NULL; e.revision:=e.revision+1;"
        case .uncertain:
            try require(action == .recycle || action == .restore || action == .settle, .denied)
            guard let error, [NASError.unsafeFile,.staleState,.denied,.expired,.integrity,.database,.interrupted,.unsupported,.missingVolume,.timedOut,.collision,.budgetExceeded].contains(error) else { throw NASError.invalidSchema }
            allowed = "o.phase IN ('armed','observed','uncertain')"
            change = "o.phase:='uncertain'; o.error_code:='\(error.rawValue)';"
            entryChange = ""
        default: throw NASError.unsupported
        }
        let output = try mutation("""
        SELECT * INTO o FROM macnas.file_effect_operations WHERE operation_id=\(FileEffectMetadata.uuidSQL(snapshot.record.operationID)) AND instance_id=\(instanceSQL) AND actor_user_utf8=\(actorSQL) FOR UPDATE;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        SELECT * INTO e FROM macnas.recycle_entries WHERE entry_id=o.entry_id AND owner_user_utf8=\(actorSQL) FOR UPDATE;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        IF o.revision<>\(snapshot.record.revision) OR e.revision<>\(snapshot.record.entryRevision) OR NOT (\(allowed)) OR e.active_operation_id IS DISTINCT FROM o.operation_id
          OR o.kind<>'\(snapshot.record.kind.rawValue)' OR o.origin_generation<>\(scope.generation) OR o.origin_scope_sha256<>'\(snapshot.originScopeSHA256)'
          OR e.vault_id<>\(FileEffectMetadata.uuidSQL(snapshot.vaultID)) OR e.volume_id<>\(FileEffectMetadata.uuidSQL(snapshot.volumeID)) OR e.payload_id<>\(FileEffectMetadata.uuidSQL(snapshot.payloadID))
          OR o.pre_evidence<>\(try FileEffectMetadata.jsonSQL(snapshot.preEvidence)) OR o.intent<>\(try FileEffectMetadata.jsonSQL(snapshot.intent)) THEN \(Self.reject(.staleState)) END IF;
        IF o.revision=9223372036854775807 OR e.revision=9223372036854775807 THEN \(Self.reject(.budgetExceeded)) END IF;
        \(change) \(entryChange) o.revision:=o.revision+1;
        IF macnas.valid_file_effect_operation(o) IS NOT TRUE OR macnas.valid_recycle_entry(e) IS NOT TRUE THEN \(Self.reject(.budgetExceeded)) END IF;
        UPDATE macnas.file_effect_operations SET phase=o.phase,revision=o.revision,post_evidence=o.post_evidence,observed_at=o.observed_at,
          completed_at=o.completed_at,cancelled_at=o.cancelled_at,source_parent_synced_at=o.source_parent_synced_at,target_parent_synced_at=o.target_parent_synced_at,
          error_code=o.error_code,reconciler_user_utf8=o.reconciler_user_utf8,reconciled_at=o.reconciled_at WHERE operation_id=o.operation_id;
        UPDATE macnas.recycle_entries SET charge_state=e.charge_state,active_operation_id=e.active_operation_id,revision=e.revision WHERE entry_id=e.entry_id;
        INSERT INTO effect_result VALUES(jsonb_build_object('record',\(Self.resultSQL)));
        """)
        try requireExecutor(permit, action: action, snapshot: snapshot); return output
    }
    func observedForExecutor(_ witness: FileEffectExecutionWitness) throws -> FileEffectJournalRecord {
        try witness.check(.observed)
        let result = try executorTransition(witness.permit, snapshot: witness.snapshot, target: .observed, post: witness.evidence)
        try witness.check(.observed); return result
    }
    func completedForExecutor(_ witness: FileEffectExecutionWitness) throws -> FileEffectJournalRecord {
        try witness.check(.completed)
        let result = try executorTransition(witness.permit, snapshot: witness.snapshot, target: .completed)
        try witness.check(.completed); return result
    }
    func uncertainForExecutor(_ permit: FileEffectExecutionPermit, snapshot: FileEffectExecutionSnapshot, error: NASError) throws -> FileEffectJournalRecord {
        try executorTransition(permit, snapshot: snapshot, target: .uncertain, error: error)
    }
    func cancelledForExecutor(_ witness: FileEffectExecutionWitness) throws -> FileEffectJournalRecord {
        try witness.check(.cancelled)
        let result = try executorTransition(witness.permit, snapshot: witness.snapshot, target: .cancelled)
        try witness.check(.cancelled); return result
    }
}
