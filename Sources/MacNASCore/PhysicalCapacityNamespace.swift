import Foundation
import Darwin

/// Host-only metadata. All paths are fixed by the synthetic implementation.
struct PhysicalCapacityRegistration: Codable, Equatable {
    var version = 1
    let scopeID: UUID
    let registrySHA256: String
    let originScopeSHA256: String
    let stagingDevice: String
    let stagingInode: String
}

enum PhysicalCapacityPurpose: String {
    case receive, copy, recycle, restore, inspect, cancelIncoming
    var writes: Bool { self != .inspect }
}

struct PhysicalCapacityDeclaration: Equatable {
    let origin: CapacityOrigin
    let key: Data
    let intentSHA256: String
    let bytes: Int64
    let sha256: String
    let sourceAllocationID: UUID?

    private struct Intent: Encodable {
        let version = 1
        let scopeID: UUID
        let origin: CapacityOrigin
        let businessKeyHex: String
        let bytes: Int64
        let sha256: String
        let sourceAllocationID: UUID?
    }
    static func make(scopeID: UUID, origin: CapacityOrigin, key: Data, bytes: Int64, sha256: String,
                     sourceAllocationID: UUID? = nil) throws -> Self {
        try FileEffectMetadata.subject(key); try FileEffectMetadata.hash(sha256)
        try require(origin != .initial && (0...DurableCapacityLedger.fileLimit).contains(bytes), .invalidSchema)
        try require((origin == .copy) == (sourceAllocationID != nil), .invalidSchema)
        let intent = Intent(scopeID: scopeID, origin: origin, businessKeyHex: FileEffectMetadata.hex(key),
            bytes: bytes, sha256: sha256, sourceAllocationID: sourceAllocationID)
        return .init(origin: origin, key: key, intentSHA256: try TransferEncoding.digest(FileEffectMetadata.encoded(intent)),
                     bytes: bytes, sha256: sha256, sourceAllocationID: sourceAllocationID)
    }
}

struct PhysicalCapacityGrant: Equatable {
    let id: UUID
    let host: UUID
    let epoch: UInt64
    let purpose: PhysicalCapacityPurpose
    let declaration: PhysicalCapacityDeclaration?
    let allocationID: UUID?
    let entryID: UUID?
}

/// Construction is confined to this file after fresh purpose approval and the actual
/// instance gate/vault flock. Never encode or rebuild this from scope/allocation IDs.
final class PhysicalCapacityPermit {
    let root: URL
    let store: StateStore
    let userID: Data
    let registration: PhysicalCapacityRegistration
    let registry: RecycleVaultRegistration
    let grant: PhysicalCapacityGrant
    let vault: RecycleVault
    let staging: RecycleDirectory
    private let retainedLocks: [AnyObject]
    private let registryBytes: Data
    private let validateLock: () throws -> Void
    private let validateContext: () throws -> Void
    private(set) var incoming: CapacityAllocation?

    fileprivate init(root: URL, store: StateStore, userID: Data, registration: PhysicalCapacityRegistration,
                     registry: RecycleVaultRegistration, grant: PhysicalCapacityGrant,
                     vault: RecycleVault, staging: RecycleDirectory, retaining: [AnyObject], registryBytes: Data,
                     validateLock: @escaping () throws -> Void, validate: @escaping () throws -> Void) {
        self.root = root; self.store = store; self.userID = userID; self.registration = registration
        self.registry = registry; self.grant = grant; self.vault = vault; self.staging = staging
        retainedLocks = retaining; self.registryBytes = registryBytes
        self.validateLock = validateLock; validateContext = validate
    }
    func check(write: Bool = false) throws {
        try require(!write || grant.purpose.writes, .denied); try validateContext(); try validateLock()
        try vault.vault.validate(privateMode: true)
        try require(try vault.vault.privateFile("binding.json", maximum: 8192) == registryBytes, .staleState)
        try vault.library.validate(privateMode: true); try staging.validate(privateMode: true)
        try require(staging.identity.device == registration.stagingDevice
                    && staging.identity.inode == registration.stagingInode, .staleState)
    }
    func requireIncoming(origin: CapacityOrigin, key: Data, intentSHA256: String, bytes: Int64) throws {
        try check(write: true)
        guard let declaration = grant.declaration else { throw NASError.denied }
        try require((grant.purpose == .receive && origin == .upload) || (grant.purpose == .copy && origin == .copy), .denied)
        try require(declaration.origin == origin && declaration.key == key
                    && declaration.intentSHA256 == intentSHA256 && declaration.bytes == bytes, .denied)
    }
    func bindIncoming(_ record: CapacityAllocation) throws {
        guard let declaration = grant.declaration else { throw NASError.denied }
        try require(record.scopeID == registration.scopeID && record.origin == declaration.origin
                    && record.intentSHA256 == declaration.intentSHA256 && record.declaredBytes == declaration.bytes, .denied)
        if let incoming { try require(incoming.allocationID == record.allocationID, .denied) }
        incoming = record
    }
    func requireIncomingID(_ id: UUID) throws {
        try check(write: true)
        try require([PhysicalCapacityPurpose.receive, .copy].contains(grant.purpose)
                    && incoming?.allocationID == id, .denied)
    }
    func ledger() throws -> DurableCapacityLedger {
        try DurableCapacityLedger(store: store,
            scope: .init(instanceID: registry.instanceID, generation: registry.generation, userID: userID,
                         originScopeSHA256: registration.originScopeSHA256),
            scopeID: registration.scopeID, libraryID: Data(registry.libraryID.utf8), physicalPermit: self)
    }
}

/// A separate seal for the existing recycle executor. It carries approval/identity
/// only. The old executor obtains its own lock, then calls the locked audit exactly once.
final class PhysicalCapacityLegacyAccess {
    let root: URL
    let userID: Data
    let allocationID: UUID?
    let entryID: UUID?
    let purpose: PhysicalCapacityPurpose
    private let validateContext: () throws -> Void
    private let validateLocked: (FileEffectExecutionPermit) throws -> Void
    fileprivate init(root: URL, userID: Data, allocationID: UUID?, entryID: UUID?, purpose: PhysicalCapacityPurpose,
                     validate: @escaping () throws -> Void,
                     locked: @escaping (FileEffectExecutionPermit) throws -> Void) {
        self.root = root; self.userID = userID; self.allocationID = allocationID; self.entryID = entryID; self.purpose = purpose
        validateContext = validate; validateLocked = locked
    }
    func check() throws { try validateContext() }
    func check(_ action: RecycleHostAction) throws {
        try check()
        let allowed: Bool
        switch purpose {
        case .recycle: allowed = action == .recycle
        case .restore: allowed = [.restore, .restoreDestination].contains(action)
        case .inspect: allowed = action == .observe
        default: allowed = false
        }
        try require(allowed, .denied)
    }
    func checkDestination(_ path: String) throws {
        try check(.restoreDestination); try require(path.isEmpty, .denied)
    }
    func checkIntent(_ intent: FileEffectIntent, entryID actualEntry: UUID? = nil) throws {
        try check()
        guard let allocationID else { throw NASError.denied }
        let name = allocationID.uuidString.lowercased()
        try require(intent.sourcePath == name && intent.name == name && intent.targetParentPath.isEmpty, .denied)
        if purpose == .recycle { try require(intent.kind == .recycle && actualEntry == nil, .denied) }
        else { try require(purpose == .restore && intent.kind == .restore && actualEntry == entryID, .denied) }
    }
    func checkLocked(_ permit: FileEffectExecutionPermit) throws {
        try check(permit.action); try validateLocked(permit)
    }
}

/// No payload is opened on construction. Fresh grants are required after a restart.
final class FixturePhysicalCapacityNamespace {
    static let markerPath = "host-binding/capacity-registration.json"
    static let stagingPath = "host-binding/capacity-staging"
    let root: URL
    let store: StateStore
    let userID: Data
    let registration: PhysicalCapacityRegistration
    let registry: RecycleVaultRegistration
    private let marker: Data
    private let registryBytes: Data
    private let host = UUID()
    private let lock = NSLock()
    private var epoch: UInt64 = 0
    private struct Held { let grant: PhysicalCapacityGrant; let expires: TimeInterval }
    private var grants: [UUID: Held] = [:]
    private let now: () -> TimeInterval

    init(root: URL, userID: Data, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        try RecycleVault.requireLabRoot(root); try FileEffectMetadata.subject(userID)
        self.root = root; self.userID = userID; self.now = now
        store = try PortableInstance.store(root)
        registry = try FileEffectMetadata.decode(RecycleVaultRegistration.self,
            from: SafeFS.readData(SafeFS.resolve(root, RecycleVault.registrationPath), maximumBytes: 8192))
        try registry.validateMetadata()
        registryBytes = try FileEffectMetadata.encoded(registry)
        registration = try FileEffectMetadata.decode(PhysicalCapacityRegistration.self,
            from: SafeFS.readData(SafeFS.resolve(root, Self.markerPath), maximumBytes: 8192))
        marker = try FileEffectMetadata.encoded(registration)
        try require(registration.version == 1 && registry.version == 1, .invalidSchema)
        try FileEffectMetadata.hash(registration.registrySHA256); try FileEffectMetadata.hash(registration.originScopeSHA256)
        try FileEffectMetadata.unsignedDecimal(registration.stagingDevice)
        try FileEffectMetadata.unsignedDecimal(registration.stagingInode)
        try require(try TransferEncoding.digest(FileEffectMetadata.encoded(registry)) == registration.registrySHA256
                    && Self.scopeHash(registration: registration) == registration.originScopeSHA256, .integrity)
        try require(registration.stagingDevice == registry.device, .unsupported)
        try checkContext(write: false); try store.validate(expectedVersion: 6); try checkDatabaseScope()
    }
    private struct ScopeMaterial: Encodable {
        let domain = "macnas-physical-capacity-scope-v1"
        let scopeID: UUID
        let registrySHA256: String
        let stagingDevice: String
        let stagingInode: String
    }
    static func scopeHash(registration: PhysicalCapacityRegistration) throws -> String {
        try TransferEncoding.digest(FileEffectMetadata.encoded(ScopeMaterial(scopeID: registration.scopeID,
            registrySHA256: registration.registrySHA256, stagingDevice: registration.stagingDevice,
            stagingInode: registration.stagingInode)))
    }
    private func checkContext(write: Bool) throws {
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try FileEffectMetadata.text(binding.hostID, maximum: 256)
        try require(identity.schemaVersion == 1 && identity.kind == "synthetic-prototype"
                    && identity.instanceID == registry.instanceID && Int64(identity.generation) == registry.generation
                    && binding.databaseName == store.databaseName && binding.databaseName == registry.databaseName
                    && Data(binding.hostID.utf8) == Data(registry.hostID.utf8)
                    && registry.ownerUserHex == FileEffectMetadata.hex(userID)
                    && config.schemaVersion == 1
                    && config.users.filter { Data($0.id.utf8) == userID }.map(\.role) == ["administrator"], .denied)
        try require(["synthetic_development","read_only_recovery","rolled_back_recovery"].contains(binding.mode), .denied)
        if write { try require(binding.mode == "synthetic_development", .denied) }
        try require(try PortableInstance.databaseDescriptor(root).version() == 6, .invalidSchema)
        let current = try FileEffectMetadata.decode(PhysicalCapacityRegistration.self,
            from: SafeFS.readData(SafeFS.resolve(root, Self.markerPath), maximumBytes: 8192))
        let currentRegistry = try FileEffectMetadata.decode(RecycleVaultRegistration.self,
            from: SafeFS.readData(SafeFS.resolve(root, RecycleVault.registrationPath), maximumBytes: 8192))
        try require(try FileEffectMetadata.encoded(current) == marker
                    && FileEffectMetadata.encoded(currentRegistry) == registryBytes, .staleState)
    }
    private func checkDatabaseScope() throws {
        let s = registration, r = registry
        let sql = """
        SELECT count(*) FROM macnas.capacity_scopes WHERE singleton AND scope_id=\(FileEffectMetadata.uuidSQL(s.scopeID))
          AND instance_id=\(FileEffectMetadata.uuidSQL(r.instanceID)) AND origin_generation=\(r.generation)
          AND owner_user_utf8=\(FileEffectMetadata.bytesSQL(userID))
          AND library_id_utf8=\(FileEffectMetadata.bytesSQL(Data(r.libraryID.utf8)))
          AND database_name_utf8=\(FileEffectMetadata.bytesSQL(Data(r.databaseName.utf8)))
          AND host_id_utf8=\(FileEffectMetadata.bytesSQL(Data(r.hostID.utf8)))
          AND origin_scope_sha256='\(s.originScopeSHA256)' AND byte_limit=67108864 AND mode='metadata_only'
          AND EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes p WHERE p.scope_id=\(FileEffectMetadata.uuidSQL(s.scopeID))
            AND p.binding_version=1 AND p.registry_sha256='\(s.registrySHA256)'
            AND p.device='\(r.device)' AND p.library_inode='\(r.libraryInode)' AND p.vault_inode='\(r.vaultInode)'
            AND p.staging_inode='\(s.stagingInode)' AND p.owner_uid=\(getuid()));
        """
        try require(try store.rows(sql) == [["1"]], .denied)
    }
    private func issue(_ purpose: PhysicalCapacityPurpose, declaration: PhysicalCapacityDeclaration? = nil,
                       allocationID: UUID? = nil, entryID: UUID? = nil, confirmed: Bool) throws -> PhysicalCapacityGrant {
        try require(confirmed, .denied); try checkContext(write: purpose.writes); try checkDatabaseScope()
        lock.lock(); defer { lock.unlock() }
        grants = grants.filter { $0.value.expires > now() }
        try require(grants.count < 8 && epoch < UInt64.max, .budgetExceeded)
        let grant = PhysicalCapacityGrant(id: UUID(), host: host, epoch: epoch, purpose: purpose,
            declaration: declaration, allocationID: allocationID, entryID: entryID)
        grants[grant.id] = Held(grant: grant, expires: now()+1800)
        return grant
    }
    private func discard(_ grant: PhysicalCapacityGrant) {
        lock.lock(); defer { lock.unlock() }; grants.removeValue(forKey: grant.id)
    }
    func revokeAll() {
        lock.lock(); defer { lock.unlock() }; grants.removeAll()
        if epoch < UInt64.max { epoch += 1 }
    }
    func validate(_ grant: PhysicalCapacityGrant) throws {
        lock.lock(); let held = grants[grant.id], currentEpoch = epoch; lock.unlock()
        try require(grant.host == host && grant.epoch == currentEpoch && held?.grant == grant, .denied)
        guard let held else { throw NASError.denied }
        try require(held.expires > now(), .expired); try checkContext(write: grant.purpose.writes)
    }
    func approveReceive(key: Data, bytes: Int64, sha256: String, confirmed: Bool) throws -> PhysicalCapacityGrant {
        try require(confirmed, .denied)
        let declaration = try PhysicalCapacityDeclaration.make(scopeID: registration.scopeID, origin: .upload,
            key: key, bytes: bytes, sha256: sha256)
        return try issue(.receive, declaration: declaration, confirmed: true)
    }
    func approveInspect(confirmed: Bool) throws -> PhysicalCapacityGrant { try issue(.inspect, confirmed: confirmed) }
    func approveRecycle(allocationID: UUID, confirmed: Bool) throws -> PhysicalCapacityGrant {
        try issue(.recycle, allocationID: allocationID, confirmed: confirmed)
    }
    func approveCancelIncoming(allocationID: UUID, confirmed: Bool) throws -> PhysicalCapacityGrant {
        try issue(.cancelIncoming, allocationID: allocationID, confirmed: confirmed)
    }
    func inspect(_ grant: PhysicalCapacityGrant) throws -> PhysicalCapacityInventory {
        try require(grant.purpose == .inspect, .denied)
        return try withPermit(grant) { try PhysicalCapacityFiles.audit($0, requireClean: false) }
    }
    func receive(_ data: Data, grant: PhysicalCapacityGrant,
                 checkpoint: (PhysicalCapacityCheckpoint) throws -> Void = { _ in }) throws -> PhysicalCapacityResult {
        try require(grant.purpose == .receive, .denied)
        return try withPermit(grant) { try PhysicalCapacityFiles.receive(data, permit: $0, checkpoint: checkpoint) }
    }
    func copy(grant: PhysicalCapacityGrant,
              checkpoint: (PhysicalCapacityCheckpoint) throws -> Void = { _ in }) throws -> PhysicalCapacityResult {
        try require(grant.purpose == .copy, .denied)
        return try withPermit(grant) { try PhysicalCapacityFiles.copy(permit: $0, checkpoint: checkpoint) }
    }
    func cancelUnarmed(grant: PhysicalCapacityGrant) throws -> CapacityAllocation {
        try require(grant.purpose == .cancelIncoming, .denied)
        return try withPermit(grant) { try PhysicalCapacityFiles.cancelUnarmed(permit: $0) }
    }
    func recycle(grant: PhysicalCapacityGrant, key: Data,
                 checkpoint: (RecycleCheckpoint) throws -> Void = { _ in }) throws -> RecycleExecutionResult {
        guard grant.purpose == .recycle, let id = grant.allocationID else { throw NASError.denied }
        let access = try legacyAccess(grant)
        let authority = try FixtureRecycleAuthority(root: root, userID: userID, physicalAccess: access)
        let native = try authority.approve(.recycle, confirmed: true)
        let executor = FixtureRecycleCoordinator(authority: authority)
        let plan = try executor.preview(path: id.uuidString.lowercased(), grant: native)
        return try executor.commit(previewID: plan.previewID, grant: native, confirmed: true, key: key, checkpoint: checkpoint)
    }
    func restore(grant: PhysicalCapacityGrant, key: Data,
                 checkpoint: (RecycleCheckpoint) throws -> Void = { _ in }) throws -> RecycleExecutionResult {
        guard grant.purpose == .restore, let id = grant.allocationID, let entry = grant.entryID else { throw NASError.denied }
        let access = try legacyAccess(grant)
        let authority = try FixtureRecycleAuthority(root: root, userID: userID, physicalAccess: access)
        let native = try authority.approve(.restore, confirmed: true)
        let target = try authority.approveRestoreDestination(parentPath: "", confirmed: true)
        let executor = FixtureRecycleCoordinator(authority: authority)
        let plan = try executor.previewRestore(entryID: entry, parentPath: "", name: id.uuidString.lowercased(),
                                               grant: native, destinationGrant: target)
        return try executor.commit(previewID: plan.previewID, grant: native, confirmed: true, key: key,
                                   destinationGrant: target, checkpoint: checkpoint)
    }
    func approveCopy(source: UUID, key: Data, confirmed: Bool) throws -> PhysicalCapacityGrant {
        let provisional = try issue(.copy, allocationID: source, confirmed: confirmed)
        defer { discard(provisional) }
        let declaration = try withPermit(provisional) { permit in
            guard let record = try permit.ledger().allocation(source), record.state == .owned,
                  let sha256 = record.sha256 else { throw NASError.denied }
            return try PhysicalCapacityDeclaration.make(scopeID: registration.scopeID, origin: .copy, key: key,
                bytes: record.declaredBytes, sha256: sha256, sourceAllocationID: source)
        }
        discard(provisional)
        return try issue(.copy, declaration: declaration, allocationID: source, confirmed: true)
    }
    func withPermit<T>(_ grant: PhysicalCapacityGrant, _ body: (PhysicalCapacityPermit) throws -> T) throws -> T {
        try validate(grant); try checkDatabaseScope()
        let gate = try InstanceLock(root, mode: .shared, timeout: 1)
        try validate(grant)
        let vault = try RecycleVault(root: root, registration: registry), serial = try vault.lock()
        let staging = try RecycleDirectory(root.appendingPathComponent(Self.stagingPath), privateMode: true)
        let permit = makePermit(grant, vault: vault, staging: staging, retaining: [gate,serial], lockCheck: { try serial.validate() })
        try permit.check()
        _ = try PhysicalCapacityFiles.audit(permit, requireClean: grant.purpose != .inspect)
        let result = try body(permit); try permit.check(); return result
    }
    private func makePermit(_ grant: PhysicalCapacityGrant, vault: RecycleVault, staging: RecycleDirectory,
                            retaining: [AnyObject], lockCheck: @escaping () throws -> Void) -> PhysicalCapacityPermit {
        PhysicalCapacityPermit(root: root, store: store, userID: userID, registration: registration, registry: registry,
            grant: grant, vault: vault, staging: staging, retaining: retaining, registryBytes: registryBytes,
            validateLock: lockCheck, validate: { try self.validate(grant) })
    }
    func approveRestore(entryID: UUID, confirmed: Bool) throws -> PhysicalCapacityGrant {
        let provisional = try issue(.restore, entryID: entryID, confirmed: confirmed)
        defer { discard(provisional) }
        let allocationID = try withPermit(provisional) { permit in
            let rows = try store.rows("""
            SELECT convert_from(original_path_utf8,'UTF8'),byte_count,sha256,charge_state,
              coalesce(active_operation_id::text,'none') FROM macnas.recycle_entries
            WHERE entry_id=\(FileEffectMetadata.uuidSQL(entryID)) AND instance_id=\(FileEffectMetadata.uuidSQL(registry.instanceID))
              AND owner_user_utf8=\(FileEffectMetadata.bytesSQL(userID))
              AND library_id_utf8=\(FileEffectMetadata.bytesSQL(Data(registry.libraryID.utf8)))
              AND volume_id=\(FileEffectMetadata.uuidSQL(registry.volumeID))
              AND vault_id=\(FileEffectMetadata.uuidSQL(registry.vaultID));
            """)
            guard rows.count == 1, rows[0].count == 5, let id = UUID(uuidString: rows[0][0]),
                  id.uuidString.lowercased() == rows[0][0], let count = Int64(rows[0][1]),
                  rows[0][3] == "retained", rows[0][4] == "none",
                  let allocation = try permit.ledger().allocation(id), allocation.state == .owned,
                  allocation.declaredBytes == count, allocation.sha256 == rows[0][2] else { throw NASError.denied }
            return id
        }
        discard(provisional)
        return try issue(.restore, allocationID: allocationID, entryID: entryID, confirmed: true)
    }
    func legacyAccess(_ grant: PhysicalCapacityGrant) throws -> PhysicalCapacityLegacyAccess {
        try validate(grant); try checkDatabaseScope()
        try require([PhysicalCapacityPurpose.recycle,.restore,.inspect].contains(grant.purpose), .denied)
        return PhysicalCapacityLegacyAccess(root: root, userID: userID, allocationID: grant.allocationID, entryID: grant.entryID,
            purpose: grant.purpose, validate: { try self.validate(grant) },
            locked: { nativePermit in
                try self.validate(grant)
                try require(nativePermit.userID == self.userID
                            && nativePermit.registration == self.registry, .denied)
                let staging = try RecycleDirectory(self.root.appendingPathComponent(Self.stagingPath), privateMode: true)
                let permit = self.makePermit(grant, vault: nativePermit.vault, staging: staging, retaining: [nativePermit],
                    lockCheck: { try nativePermit.validateHeldLock() })
                _ = try PhysicalCapacityFiles.audit(permit, requireClean: grant.purpose != .inspect)
                if grant.purpose == .recycle {
                    guard let id = grant.allocationID, let row = try permit.ledger().allocation(id),
                          row.state == .owned else { throw NASError.denied }
                    _ = try PhysicalCapacityFiles.visibleFile(permit, record: row)
                }
            })
    }
    /// Fresh registration only. Any partial/previous layout is preserved and rejected.
    /// This does not adopt an existing metadata scope or issue an execution grant.
    static func createFresh(root: URL, userID: Data, confirmed: Bool) throws -> PhysicalCapacityRegistration {
        try require(confirmed, .denied); try RecycleVault.requireLabRoot(root)
        let store = try PortableInstance.store(root); try store.validate(expectedVersion: 6)
        try require(try !store.hasCapacityHistory() && !store.hasRecycleHistory(), .unsupported)
        let authority = try FixtureRecycleAuthority(root: root, userID: userID)
        let registry = try authority.createFreshFixture(confirmed: true)
        let gate = try InstanceLock(root, mode: .shared, timeout: 1)
        let vault = try RecycleVault(root: root, registration: registry), serial = try vault.lock()
        return try withExtendedLifetime([gate,serial] as [AnyObject]) {
            try require(try vault.library.names(maximum: 0).isEmpty, .unsupported)
            let host = try RecycleDirectory(root.appendingPathComponent("host-binding"))
            try require(try host.named("capacity-staging") == nil && host.named("capacity-registration.json") == nil, .collision)
            let staging = try host.child("capacity-staging", create: true, privateMode: true)
            try require(staging.identity.device == registry.device, .unsupported)
            let id = UUID(), registrySHA = try TransferEncoding.digest(FileEffectMetadata.encoded(registry))
            let unsigned = PhysicalCapacityRegistration(scopeID: id, registrySHA256: registrySHA,
                originScopeSHA256: String(repeating: "0", count: 64),
                stagingDevice: staging.identity.device, stagingInode: staging.identity.inode)
            let registration = PhysicalCapacityRegistration(scopeID: id, registrySHA256: registrySHA,
                originScopeSHA256: try scopeHash(registration: unsigned),
                stagingDevice: staging.identity.device, stagingInode: staging.identity.inode)
            let ledger = try DurableCapacityLedger(store: store,
                scope: .init(instanceID: registry.instanceID, generation: registry.generation, userID: userID,
                             originScopeSHA256: registration.originScopeSHA256),
                scopeID: id, libraryID: Data(registry.libraryID.utf8))
            _ = try ledger.createMetadataScope(confirmed: true)
            try require(try ledger.totals().historyCount == 0, .collision)
            // Register the physical binding while the fresh roots and actual vault lock
            // remain held. Any partial DB/marker failure stays visible and is never adopted.
            try store.withMutation {
                _ = try authority.registration(); try vault.validate(); try staging.validate(privateMode: true)
                let delimiter = "$physical_" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + "$"
                try store.execute("""
                BEGIN; SET LOCAL synchronous_commit='on'; SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms';
                DO \(delimiter) BEGIN
                  PERFORM pg_advisory_xact_lock(786029,4);
                  IF current_setting('fsync')<>'on' OR current_setting('full_page_writes')<>'on'
                    OR EXISTS(SELECT 1 FROM macnas.capacity_allocations)
                    OR EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes)
                    OR EXISTS(SELECT 1 FROM macnas.capacity_file_ownership)
                    OR NOT EXISTS(SELECT 1 FROM macnas.capacity_scopes WHERE singleton AND scope_id=\(FileEffectMetadata.uuidSQL(id))
                      AND origin_scope_sha256='\(registration.originScopeSHA256)')
                    OR (\(StateStore.metadataBytesExpression(includeSchema: true, version: 6)))+8192>4000000
                  THEN RAISE EXCEPTION 'physical capacity registration rejected'; END IF;
                  INSERT INTO macnas.physical_capacity_scopes VALUES(\(FileEffectMetadata.uuidSQL(id)),1,
                    '\(registrySHA)','\(registry.device)','\(registry.libraryInode)','\(registry.vaultInode)',
                    '\(staging.identity.inode)',\(getuid()),now());
                END \(delimiter); COMMIT;
                """)
                _ = try authority.registration(); try vault.validate(); try staging.validate(privateMode: true)
            }
            try writeNewPrivateFile(parent: host, name: "capacity-registration.json",
                                    data: FileEffectMetadata.encoded(registration))
            try staging.synchronize(); try host.synchronize()
            _ = try FixturePhysicalCapacityNamespace(root: root, userID: userID)
            return registration
        }
    }
    private static func writeNewPrivateFile(parent: RecycleDirectory, name: String, data: Data) throws {
        try require(data.count <= 8192, .budgetExceeded); try parent.validate()
        let fd = openat(parent.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw NASError.collision }
        defer { close(fd) } // Preserve a partial marker; never remove/adopt it after failure.
        try require(fchmod(fd, 0o600) == 0, .unsafeFile)
        try data.withUnsafeBytes { block in
            var offset = 0
            while offset < block.count {
                let written = write(fd, block.baseAddress!.advanced(by: offset), block.count-offset)
                if written < 0 && errno == EINTR { continue }
                try require(written > 0 && written <= block.count-offset, .unsafeFile); offset += written
            }
        }
        try require(fsync(fd) == 0, .unsafeFile); try parent.validate()
    }
}
