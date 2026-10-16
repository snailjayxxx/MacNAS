import Foundation
import CryptoKit

enum RecycleHostAction: String, Codable { case recycle, observe, settle, cancelPrepared }

struct RecycleHostGrant: Equatable {
    let id: UUID
    let host: UUID
    let action: RecycleHostAction
    let revision: UInt64
}

/// Construction is confined to this file after fresh approval, instance gate and vault flock.
/// The grant is not serializable and cannot be recreated from an operation/entry ID.
final class FileEffectExecutionPermit {
    let action: RecycleHostAction
    let registration: RecycleVaultRegistration
    let userID: Data
    let originScopeSHA256: String
    let vault: RecycleVault
    private let instanceGate: InstanceLock
    private let vaultLock: RecycleVaultLock
    private let validateGrant: () throws -> Void
    fileprivate init(action: RecycleHostAction, registration: RecycleVaultRegistration, userID: Data,
                     originScopeSHA256: String, vault: RecycleVault, instanceGate: InstanceLock,
                     vaultLock: RecycleVaultLock, validate: @escaping () throws -> Void) {
        self.action = action; self.registration = registration; self.userID = userID; self.originScopeSHA256 = originScopeSHA256
        self.vault = vault; self.instanceGate = instanceGate; self.vaultLock = vaultLock; validateGrant = validate
    }
    func check(_ expected: RecycleHostAction) throws {
        try require(action == expected, .denied); try validateGrant(); try vault.validate(); try vaultLock.validate()
    }
}

/// Explicit host-only fixture approvals, separate from browse/upload/copy/mkdir permissions.
/// Initializing a host reads known instance metadata only; it never opens a prior library or vault.
final class FixtureRecycleAuthority {
    let root: URL
    let store: StateStore
    let userID: Data
    private let host = UUID()
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var grants: [UUID: (RecycleHostGrant, TimeInterval, Data)] = [:]
    private let now: () -> TimeInterval

    init(root: URL, userID: Data, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) throws {
        try RecycleVault.requireLabRoot(root); try FileEffectMetadata.subject(userID)
        self.root = root; self.userID = userID; self.now = now; store = try PortableInstance.store(root)
        _ = try context(write: false)
        try store.validate(expectedVersion: 4)
    }
    private func context(write: Bool) throws -> (InstanceIdentity, HostBinding) {
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try FileEffectMetadata.text(binding.hostID, maximum: 256)
        try require(config.schemaVersion == 1 && identity.kind == "synthetic-prototype" && identity.schemaVersion == 1 && identity.generation >= 0
                    && binding.databaseName == store.databaseName && !binding.hostID.isEmpty
                    && config.users.filter({ Data($0.id.utf8) == userID }).map(\.role) == ["administrator"], .denied)
        try require(["synthetic_development", "read_only_recovery", "rolled_back_recovery"].contains(binding.mode), .denied)
        if write { try require(binding.mode == "synthetic_development", .denied) }
        try require(try PortableInstance.databaseDescriptor(root).version() == 4, .invalidSchema)
        return (identity, binding)
    }
    func registration() throws -> RecycleVaultRegistration {
        let (identity, binding) = try context(write: false)
        let bytes = try SafeFS.readData(SafeFS.resolve(root, RecycleVault.registrationPath), maximumBytes: 8192)
        let value = try FileEffectMetadata.decode(RecycleVaultRegistration.self, from: bytes)
        try require(value.version == 1 && value.instanceID == identity.instanceID && value.generation == Int64(identity.generation)
                    && value.databaseName == store.databaseName && Data(value.hostID.utf8) == Data(binding.hostID.utf8), .staleState)
        try require(value.ownerUserHex == FileEffectMetadata.hex(userID), .denied)
        try require(value.slots.count == 64 && Set(value.slots.map(\.id)).count == 64, .invalidSchema)
        for slot in value.slots { try FileEffectMetadata.unsignedDecimal(slot.inode) }
        try FileEffectMetadata.text(value.libraryID, maximum: 128)
        try FileEffectMetadata.unsignedDecimal(value.device); try FileEffectMetadata.unsignedDecimal(value.libraryInode)
        try FileEffectMetadata.unsignedDecimal(value.vaultInode)
        return value
    }
    /// The only creation entry: fresh fixed-layout synthetic directories beneath this TestLab instance.
    func createFreshFixture(confirmed: Bool) throws -> RecycleVaultRegistration {
        try require(confirmed, .denied)
        let gate = try InstanceLock(root, timeout: 1)
        return try withExtendedLifetime(gate) {
            _ = try context(write: true)
            return try RecycleVault.create(root: root, store: store, userID: userID)
        }
    }
    func approve(_ action: RecycleHostAction, confirmed: Bool) throws -> RecycleHostGrant {
        try require(confirmed, .denied); _ = try context(write: action != .observe)
        let registered = try FileEffectMetadata.encoded(registration())
        lock.lock(); defer { lock.unlock() }
        grants = grants.filter { $0.value.1 > now() }
        try require(grants.count < 8 && revision < UInt64.max, .budgetExceeded)
        let value = RecycleHostGrant(id: UUID(), host: host, action: action, revision: revision)
        grants[value.id] = (value, now() + 1800, registered)
        return value
    }
    func revokeAll() {
        lock.lock(); defer { lock.unlock() }; grants.removeAll()
        // Exhaustion permanently revokes this host; a new host still needs an explicit grant.
        if revision < UInt64.max { revision += 1 }
    }
    func validate(_ grant: RecycleHostGrant, action: RecycleHostAction, registration expected: RecycleVaultRegistration? = nil) throws {
        lock.lock()
        let held = grants[grant.id], current = revision
        lock.unlock()
        try require(grant.host == host && grant.action == action && grant.revision == current
                    && held?.0 == grant && (held?.1 ?? 0) > now(), .denied)
        _ = try context(write: action != .observe)
        let actual = try registration()
        try require(try FileEffectMetadata.encoded(actual) == held?.2, .staleState)
        if let expected { try require(try FileEffectMetadata.encoded(actual) == FileEffectMetadata.encoded(expected), .staleState) }
    }
    func withLockedVault<T>(_ grant: RecycleHostGrant, action: RecycleHostAction,
                            _ body: (FileEffectExecutionPermit) throws -> T) throws -> T {
        let gate = try InstanceLock(root, mode: .shared, timeout: 1)
        try validate(grant, action: action)
        let registration = try self.registration()
        // No library/vault descriptor is opened until the explicit fresh grant has passed.
        let vault = try RecycleVault(root: root, registration: registration), serial = try vault.lock()
        let origin = try TransferEncoding.digest(FileEffectMetadata.encoded(registration) + userID + Data(grant.id.uuidString.utf8))
        let permit = FileEffectExecutionPermit(action: action, registration: registration, userID: userID,
            originScopeSHA256: origin, vault: vault, instanceGate: gate, vaultLock: serial,
            validate: { try self.validate(grant, action: action, registration: registration) })
        return try withExtendedLifetime(permit) {
            try permit.check(action); let result = try body(permit); try permit.check(action); return result
        }
    }
}
