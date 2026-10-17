import Foundation
import Darwin

enum CapacityOrigin: String, Codable, Sendable { case initial, upload, copy }
enum CapacityAllocationState: String, Codable, Sendable { case reserved, armed, owned, cancelled }

struct CapacityAllocation: Codable, Equatable, Sendable {
    let allocationID: UUID
    let scopeID: UUID
    let origin: CapacityOrigin
    let intentSHA256: String
    let declaredBytes: Int64
    let state: CapacityAllocationState
    let revision: Int64
    let sha256: String?
}

struct CapacityTotals: Codable, Equatable {
    let reservedBytes: Int64
    let unresolvedBytes: Int64
    let ownedBytes: Int64
    let allocatedBytes: Int64
    let historyCount: Int
    let unresolvedCount: Int
}

/// C3A is a persistent, metadata-only admission ledger. It neither inventories nor opens
/// files, registers a physical namespace, or authorizes publication/recycle/restore.
/// The explicit metadata-only transitions cannot be called through a bridge or RPC.
final class DurableCapacityLedger {
    static let byteLimit: Int64 = 64 * 1024 * 1024
    static let fileLimit: Int64 = 16 * 1024 * 1024
    private let store: StateStore
    private let root: URL
    private let scope: FileEffectJournalScope
    private let libraryID: Data
    private let binding: HostBinding
    private let physicalPermit: PhysicalCapacityPermit?
    private let databaseVersion: Int
    let scopeID: UUID

    init(store: StateStore, scope: FileEffectJournalScope, scopeID: UUID, libraryID: Data,
         physicalPermit: PhysicalCapacityPermit? = nil) throws {
        guard let root = store.instanceRoot else { throw NASError.denied }
        try RecycleVault.requireLabRoot(root)
        try FileEffectMetadata.subject(scope.userID); try FileEffectMetadata.subject(libraryID)
        try require(libraryID.count <= 128 && (0...9_007_199_254_740_991).contains(scope.generation), .invalidSchema)
        try FileEffectMetadata.hash(scope.originScopeSHA256)
        self.store = store; self.root = root; self.scope = scope; self.scopeID = scopeID; self.libraryID = libraryID; self.physicalPermit = physicalPermit
        binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        databaseVersion = try PortableInstance.databaseDescriptor(root).version()
        try require([5,6].contains(databaseVersion) && (physicalPermit == nil || databaseVersion == 6), .unsupported)
        try store.validate(expectedVersion: databaseVersion)
        try checkContext(write: false)
    }
    private func checkContext(write: Bool) throws {
        // These setters model metadata only. A future physical registration must use
        // its separately sealed filesystem witnesses, never this unregistered path.
        let registration = try SafeFS.resolve(root, "host-binding/capacity-registration.json")
        if let physicalPermit {
            try physicalPermit.check(write: write)
            try require(physicalPermit.root == root && physicalPermit.store.databaseName == store.databaseName
                        && physicalPermit.userID == scope.userID && physicalPermit.registration.scopeID == scopeID
                        && physicalPermit.registration.originScopeSHA256 == scope.originScopeSHA256
                        && Data(physicalPermit.registry.libraryID.utf8) == libraryID, .denied)
        } else {
            try require(!FileManager.default.fileExists(atPath: registration.path), .unsupported)
            if databaseVersion >= 6 {
                try require(try store.rows("SELECT EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes);") == [["f"]], .unsupported)
            }
        }
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let current = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try FileEffectMetadata.text(current.hostID, maximum: 256)
        try require(identity.kind == "synthetic-prototype" && identity.schemaVersion == 1
                    && identity.instanceID == scope.instanceID && Int64(identity.generation) == scope.generation
                    && current.databaseName == store.databaseName && Data(current.hostID.utf8) == Data(binding.hostID.utf8)
                    && current.databaseName == binding.databaseName && !current.hostID.isEmpty
                    && config.schemaVersion == 1
                    && config.users.filter { Data($0.id.utf8) == scope.userID }.map(\.role) == ["administrator"], .denied)
        try require(["synthetic_development", "read_only_recovery", "rolled_back_recovery"].contains(current.mode), .denied)
        if write { try require(current.mode == "synthetic_development", .denied) }
        try require(try PortableInstance.databaseDescriptor(root).version() == databaseVersion && store.schemaVersion() == databaseVersion, .invalidSchema)
    }
    private static func reject(_ error: NASError) -> String {
        "INSERT INTO capacity_result VALUES(jsonb_build_object('error','\(error.rawValue)')); RETURN;"
    }
    private static let allocationJSON = "jsonb_build_object('allocationID',a.allocation_id,'scopeID',a.scope_id,'origin',a.origin_kind,'intentSHA256',a.intent_sha256,'declaredBytes',a.declared_bytes,'state',a.state,'revision',a.revision,'sha256',a.sha256)"
    private var scopePredicate: String {
        "s.scope_id=\(FileEffectMetadata.uuidSQL(scopeID)) AND s.instance_id=\(FileEffectMetadata.uuidSQL(scope.instanceID)) AND s.origin_generation=\(scope.generation) AND s.owner_user_utf8=\(FileEffectMetadata.bytesSQL(scope.userID)) AND s.library_id_utf8=\(FileEffectMetadata.bytesSQL(libraryID)) AND s.origin_scope_sha256='\(scope.originScopeSHA256)' AND s.database_name_utf8=\(FileEffectMetadata.bytesSQL(Data(store.databaseName.utf8))) AND s.host_id_utf8=\(FileEffectMetadata.bytesSQL(Data(binding.hostID.utf8))) AND s.mode='metadata_only'"
    }
    private var admissionBudget: String {
        let physical = databaseVersion >= 6 ? "+(SELECT count(*)*3072 FROM macnas.physical_capacity_scopes)+(SELECT count(*)*2048 FROM macnas.capacity_file_ownership)" : ""
        return """
        IF GREATEST((\(StateStore.metadataBytesExpression(includeSchema: true, version: databaseVersion))),
          (\(StateStore.legacyMetadataBytesSQL))+(SELECT count(*)*4096 FROM macnas.recycle_entries)
          +(SELECT count(*)*8192 FROM macnas.file_effect_operations)
          +(SELECT count(*)*3072 FROM macnas.capacity_scopes)+(SELECT count(*)*2048 FROM macnas.capacity_allocations)\(physical)+8192)>4000000
        THEN \(Self.reject(.budgetExceeded)) END IF;
        """
    }
    private func mutation<T: Decodable>(_ body: String, as: T.Type) throws -> T {
        try store.withMutation {
            try checkContext(write: true)
            let delimiter = "$capacity_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "$"
            let sql = """
            BEGIN;
            SET LOCAL synchronous_commit='on'; SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms';
            CREATE TEMP TABLE capacity_result(value jsonb) ON COMMIT DROP;
            DO \(delimiter)
            DECLARE s macnas.capacity_scopes%ROWTYPE; a macnas.capacity_allocations%ROWTYPE;
            BEGIN
              IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
              THEN \(Self.reject(.denied)) END IF;
              PERFORM pg_advisory_xact_lock(786029,4);
              \(body)
            END \(delimiter);
            SELECT value::text FROM capacity_result;
            COMMIT;
            """
            let output = try store.tools.sql(sql, database: store.databaseName)
            let object = try JSONSerialization.jsonObject(with: Data(output.utf8)) as? [String: Any]
            if let raw = object?["error"] as? String, let error = NASError(rawValue: raw) { throw error }
            let result = try JSONDecoder().decode(T.self, from: Data(output.utf8))
            // Context rejection after COMMIT never compensates or retries a committed transition.
            try checkContext(write: true)
            return result
        }
    }
    @discardableResult func createMetadataScope(confirmed: Bool) throws -> UUID {
        try require(physicalPermit == nil, .unsupported)
        try require(confirmed, .denied)
        struct Result: Decodable { let scopeID: UUID }
        let body = """
        SELECT * INTO s FROM macnas.capacity_scopes WHERE singleton;
        IF FOUND THEN
          IF NOT (\(scopePredicate)) THEN \(Self.reject(.collision)) END IF;
          INSERT INTO capacity_result VALUES(jsonb_build_object('scopeID',s.scope_id)); RETURN;
        END IF;
        \(admissionBudget)
        INSERT INTO macnas.capacity_scopes VALUES(true,\(FileEffectMetadata.uuidSQL(scopeID)),1,
          \(FileEffectMetadata.uuidSQL(scope.instanceID)),\(scope.generation),\(FileEffectMetadata.bytesSQL(scope.userID)),
          \(FileEffectMetadata.bytesSQL(libraryID)),\(FileEffectMetadata.bytesSQL(Data(store.databaseName.utf8))),\(FileEffectMetadata.bytesSQL(Data(binding.hostID.utf8))),\(try StateStore.quote(scope.originScopeSHA256)),67108864,'metadata_only',now());
        INSERT INTO capacity_result VALUES(jsonb_build_object('scopeID',\(FileEffectMetadata.uuidSQL(scopeID))));
        """
        return try mutation(body, as: Result.self).scopeID
    }
    private var requireScope: String {
        let physicalGate: String
        if physicalPermit != nil {
            physicalGate = "IF NOT EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes p WHERE p.scope_id=s.scope_id) THEN \(Self.reject(.denied)) END IF;"
        } else if databaseVersion >= 6 {
            physicalGate = "IF EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes) THEN \(Self.reject(.unsupported)) END IF;"
        } else { physicalGate = "" }
        return "SELECT * INTO s FROM macnas.capacity_scopes WHERE singleton; IF NOT FOUND OR NOT (\(scopePredicate)) THEN \(Self.reject(.denied)) END IF; \(physicalGate)"
    }
    @discardableResult func reserve(origin: CapacityOrigin, key: Data, intentSHA256: String, bytes: Int64,
                                    allocationID: UUID = UUID()) throws -> CapacityAllocation {
        try require(physicalPermit == nil, .unsupported)
        return try reserveCore(origin: origin, key: key, intentSHA256: intentSHA256, bytes: bytes, allocationID: allocationID)
    }
    private func reserveCore(origin: CapacityOrigin, key: Data, intentSHA256: String, bytes: Int64,
                             allocationID: UUID) throws -> CapacityAllocation {
        try FileEffectMetadata.subject(key); try FileEffectMetadata.hash(intentSHA256)
        try require((0...Self.fileLimit).contains(bytes), .budgetExceeded)
        let ownershipInsert = physicalPermit == nil ? "" : "INSERT INTO macnas.capacity_file_ownership VALUES(a.allocation_id,1,NULL,NULL,NULL);"
        let body = """
        \(requireScope)
        SELECT * INTO a FROM macnas.capacity_allocations WHERE scope_id=s.scope_id AND origin_kind=\(try StateStore.quote(origin.rawValue)) AND idempotency_key_utf8=\(FileEffectMetadata.bytesSQL(key));
        IF FOUND THEN
          IF a.intent_sha256<>\(try StateStore.quote(intentSHA256)) OR a.declared_bytes<>\(bytes) THEN \(Self.reject(.collision)) END IF;
          INSERT INTO capacity_result VALUES(\(Self.allocationJSON)); RETURN;
        END IF;
        IF EXISTS(SELECT 1 FROM macnas.capacity_allocations WHERE allocation_id=\(FileEffectMetadata.uuidSQL(allocationID))) THEN \(Self.reject(.collision)) END IF;
        \(admissionBudget)
        IF EXISTS(SELECT 1 FROM macnas.capacity_allocations WHERE state='armed') THEN \(Self.reject(.staleState)) END IF;
        IF (SELECT count(*) FROM macnas.capacity_allocations)>=64
          OR (SELECT count(*) FROM macnas.capacity_allocations WHERE state IN ('reserved','armed'))>=8
          OR (SELECT coalesce(sum(declared_bytes),0) FROM macnas.capacity_allocations WHERE state<>'cancelled')+\(bytes)>s.byte_limit
        THEN \(Self.reject(.budgetExceeded)) END IF;
        INSERT INTO macnas.capacity_allocations VALUES(\(FileEffectMetadata.uuidSQL(allocationID)),s.scope_id,1,
          \(try StateStore.quote(origin.rawValue)),\(FileEffectMetadata.bytesSQL(key)),\(try StateStore.quote(intentSHA256)),\(bytes),'reserved',1,NULL,now(),NULL,NULL,NULL) RETURNING * INTO a;
        \(ownershipInsert)
        INSERT INTO capacity_result VALUES(\(Self.allocationJSON));
        """
        return try mutation(body, as: CapacityAllocation.self)
    }
    private func transition(_ id: UUID, revision: Int64, from: String, updates: String) throws -> CapacityAllocation {
        try require((1...9_007_199_254_740_990).contains(revision), .invalidSchema)
        return try mutation("""
        \(requireScope)
        SELECT * INTO a FROM macnas.capacity_allocations WHERE allocation_id=\(FileEffectMetadata.uuidSQL(id)) AND scope_id=s.scope_id;
        IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
        IF a.revision<>\(revision) OR a.state<>\(try StateStore.quote(from)) THEN \(Self.reject(.staleState)) END IF;
        UPDATE macnas.capacity_allocations SET revision=revision+1,\(updates) WHERE allocation_id=a.allocation_id RETURNING * INTO a;
        INSERT INTO capacity_result VALUES(\(Self.allocationJSON));
        """, as: CapacityAllocation.self)
    }
    func armMetadataOnly(_ id: UUID, revision: Int64) throws -> CapacityAllocation {
        try require(physicalPermit == nil, .unsupported)
        return try transition(id, revision: revision, from: "reserved", updates: "state='armed',armed_at=now()")
    }
    func markOwnedMetadataOnly(_ id: UUID, revision: Int64, sha256: String) throws -> CapacityAllocation {
        try require(physicalPermit == nil, .unsupported)
        try FileEffectMetadata.hash(sha256)
        return try transition(id, revision: revision, from: "armed", updates: "state='owned',sha256=\(try StateStore.quote(sha256)),owned_at=now()")
    }
    func cancelUnarmedMetadataOnly(_ id: UUID, revision: Int64) throws -> CapacityAllocation {
        try require(physicalPermit == nil, .unsupported)
        return try transition(id, revision: revision, from: "reserved", updates: "state='cancelled',cancelled_at=now()")
    }
    func allocation(_ id: UUID) throws -> CapacityAllocation? {
        try checkContext(write: false)
        let output = try store.tools.sql("SELECT \(Self.allocationJSON)::text FROM macnas.capacity_allocations a JOIN macnas.capacity_scopes s ON a.scope_id=s.scope_id WHERE \(scopePredicate) AND a.allocation_id=\(FileEffectMetadata.uuidSQL(id));", database: store.databaseName)
        let value = output.isEmpty ? nil : try JSONDecoder().decode(CapacityAllocation.self, from: Data(output.utf8))
        try checkContext(write: false); return value
    }
    func totals() throws -> CapacityTotals {
        try checkContext(write: false)
        let output = try store.tools.sql("""
        SELECT jsonb_build_object('reservedBytes',coalesce(sum(a.declared_bytes) FILTER(WHERE a.state='reserved'),0),
          'unresolvedBytes',coalesce(sum(a.declared_bytes) FILTER(WHERE a.state='armed'),0),
          'ownedBytes',coalesce(sum(a.declared_bytes) FILTER(WHERE a.state='owned'),0),
          'allocatedBytes',coalesce(sum(a.declared_bytes) FILTER(WHERE a.state<>'cancelled'),0),
          'historyCount',count(a.allocation_id),'unresolvedCount',count(a.allocation_id) FILTER(WHERE a.state='armed'))::text
        FROM macnas.capacity_scopes s LEFT JOIN macnas.capacity_allocations a ON a.scope_id=s.scope_id WHERE \(scopePredicate) HAVING count(DISTINCT s.scope_id)=1;
        """, database: store.databaseName)
        try require(!output.isEmpty, .denied)
        let result = try JSONDecoder().decode(CapacityTotals.self, from: Data(output.utf8))
        try checkContext(write: false); return result
    }

    func reservePhysical(_ declaration: PhysicalCapacityDeclaration, allocationID: UUID = UUID()) throws -> CapacityAllocation {
        guard let physicalPermit else { throw NASError.denied }
        try physicalPermit.requireIncoming(origin: declaration.origin, key: declaration.key,
            intentSHA256: declaration.intentSHA256, bytes: declaration.bytes)
        let result = try reserveCore(origin: declaration.origin, key: declaration.key,
            intentSHA256: declaration.intentSHA256, bytes: declaration.bytes, allocationID: allocationID)
        try physicalPermit.bindIncoming(result); return result
    }
    func armPhysical(_ record: CapacityAllocation) throws -> CapacityAllocation {
        guard let physicalPermit else { throw NASError.denied }
        try physicalPermit.requireIncomingID(record.allocationID)
        let result = try transition(record.allocationID, revision: record.revision, from: "reserved", updates: "state='armed',armed_at=now()")
        try physicalPermit.bindIncoming(result); return result
    }
    func finishPhysical(_ witness: PhysicalCapacityWitness) throws -> CapacityAllocation {
        guard let physicalPermit else { throw NASError.denied }
        try require(witness.permit === physicalPermit && witness.record.scopeID == scopeID, .denied)
        try witness.check()
        let result: CapacityAllocation
        switch witness.target {
        case .owned:
            try physicalPermit.requireIncomingID(witness.record.allocationID)
            guard let sha256 = witness.sha256 else { throw NASError.integrity }
            try FileEffectMetadata.hash(sha256)
            guard let stamp = witness.baseline else { throw NASError.integrity }
            try stamp.validate(directory: false)
            let proof = try StateStore.quote(String(decoding: FileEffectMetadata.encoded(stamp), as: UTF8.self))
            // Lock and validate both rows before the first write. A SQL failure rolls the
            // entire transaction back; never RETURN an error after one half was updated.
            result = try mutation("""
            \(requireScope)
            SELECT * INTO a FROM macnas.capacity_allocations WHERE allocation_id=\(FileEffectMetadata.uuidSQL(witness.record.allocationID)) AND scope_id=s.scope_id FOR UPDATE;
            IF NOT FOUND THEN \(Self.reject(.denied)) END IF;
            IF a.revision<>\(witness.record.revision) OR a.state<>'armed' THEN \(Self.reject(.staleState)) END IF;
            PERFORM 1 FROM macnas.capacity_file_ownership o WHERE o.allocation_id=a.allocation_id
              AND o.baseline_stamp IS NULL AND o.sha256 IS NULL AND o.published_at IS NULL FOR UPDATE;
            IF NOT FOUND THEN \(Self.reject(.staleState)) END IF;
            UPDATE macnas.capacity_allocations SET revision=3,state='owned',sha256=\(try StateStore.quote(sha256)),owned_at=now()
              WHERE allocation_id=a.allocation_id RETURNING * INTO a;
            UPDATE macnas.capacity_file_ownership SET baseline_stamp=\(proof)::jsonb,sha256=a.sha256,published_at=a.owned_at
              WHERE allocation_id=a.allocation_id;
            INSERT INTO capacity_result VALUES(\(Self.allocationJSON));
            """, as: CapacityAllocation.self)
        case .cancelled:
            try require(physicalPermit.grant.purpose == .cancelIncoming
                        && physicalPermit.grant.allocationID == witness.record.allocationID, .denied)
            result = try transition(witness.record.allocationID, revision: witness.record.revision, from: "reserved",
                updates: "state='cancelled',cancelled_at=now()")
        default: throw NASError.denied
        }
        try witness.check(); return result
    }
    /// One bounded read-only snapshot; totals are derived from these exact rows.
    /// This does not consult ownership payloads or adopt/release any allocation.
    func completeReadOnlyList(sourceID: String) throws -> CapacityLedgerListView {
        guard let physicalPermit, physicalPermit.grant.purpose == .ledgerRead else { throw NASError.denied }
        try checkContext(write: false)
        let r = physicalPermit.registry, p = physicalPermit.registration
        let output = try store.tools.sql("""
        BEGIN TRANSACTION ISOLATION LEVEL REPEATABLE READ READ ONLY;
        SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms';
        WITH bound AS (SELECT s.scope_id FROM macnas.capacity_scopes s WHERE \(scopePredicate) AND s.byte_limit=67108864
          AND EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes p WHERE p.scope_id=s.scope_id
            AND p.binding_version=1 AND p.registry_sha256='\(p.registrySHA256)' AND p.device='\(r.device)'
            AND p.library_inode='\(r.libraryInode)' AND p.vault_inode='\(r.vaultInode)'
            AND p.staging_inode='\(p.stagingInode)' AND p.owner_uid=\(getuid()))),
        bounded AS (SELECT a.* FROM macnas.capacity_allocations a JOIN bound b ON a.scope_id=b.scope_id
          ORDER BY a.allocation_id LIMIT 65)
        SELECT jsonb_build_object('scopeCount',(SELECT count(*) FROM bound),
          'records',coalesce((SELECT jsonb_agg(\(Self.allocationJSON) ORDER BY a.allocation_id) FROM bounded a),'[]'::jsonb))::text;
        COMMIT;
        """, database: store.databaseName)
        struct Snapshot: Decodable { let scopeCount: Int; let records: [CapacityAllocation] }
        let snapshot = try JSONDecoder().decode(Snapshot.self, from: Data(output.utf8))
        try require(snapshot.scopeCount == 1, .denied)
        let view = try CapacityLedgerListView(scopeID: scopeID, ownerUserID: scope.userID, sourceID: sourceID, records: snapshot.records)
        try checkContext(write: false)
        return view
    }
    func allocations() throws -> [CapacityAllocation] {
        try checkContext(write: false); _ = try totals()
        let sql = "SELECT \(Self.allocationJSON)::text FROM macnas.capacity_allocations a JOIN macnas.capacity_scopes s ON a.scope_id=s.scope_id WHERE \(scopePredicate) ORDER BY a.allocation_id LIMIT 65;"
        let text = try store.tools.sql(sql, database: store.databaseName), lines = text.isEmpty ? [] : text.split(separator: "\n")
        try require(lines.count <= 64, .budgetExceeded)
        let records = try lines.map { try JSONDecoder().decode(CapacityAllocation.self, from: Data($0.utf8)) }
        try checkContext(write: false); return records
    }
}
