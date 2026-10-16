import Foundation
import CryptoKit

enum RecycleHostAction: String, Codable { case recycle, restore, restoreDestination, observe, settle, cancelPrepared }

struct RecycleHostGrant: Equatable {
    let id: UUID
    let host: UUID
    let action: RecycleHostAction
    let revision: UInt64
    let destinationParentPath: Data?
    let destinationParentStamp: FileEffectStamp?
}

/// Construction is confined to this file after fresh approval, instance gate and vault flock.
/// The grant is not serializable and cannot be recreated from an operation/entry ID.
final class FileEffectExecutionPermit {
    let action: RecycleHostAction
    let registration: RecycleVaultRegistration
    let userID: Data
    let originScopeSHA256: String
    let vault: RecycleVault
    let destinationParentPath: Data?
    let destinationParentStamp: FileEffectStamp?
    private let instanceGate: InstanceLock
    private let vaultLock: RecycleVaultLock
    private let validateGrant: () throws -> Void
    fileprivate init(action: RecycleHostAction, registration: RecycleVaultRegistration, userID: Data,
                     originScopeSHA256: String, vault: RecycleVault, instanceGate: InstanceLock,
                     vaultLock: RecycleVaultLock, destinationParentPath: Data? = nil, destinationParentStamp: FileEffectStamp? = nil,
                     validate: @escaping () throws -> Void) {
        self.action = action; self.registration = registration; self.userID = userID; self.originScopeSHA256 = originScopeSHA256
        self.vault = vault; self.instanceGate = instanceGate; self.vaultLock = vaultLock; validateGrant = validate
        self.destinationParentPath = destinationParentPath
        self.destinationParentStamp = destinationParentStamp
    }
    func validateHeldLock() throws { try vaultLock.validate() }
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
    private let databaseVersion: Int
    let physicalAccess: PhysicalCapacityLegacyAccess?
    private let host = UUID()
    private let lock = NSLock()
    private var revision: UInt64 = 0
    private var grants: [UUID: (RecycleHostGrant, TimeInterval, Data)] = [:]
    private let now: () -> TimeInterval
    private let additionalContextCheck: () throws -> Void

    init(root: URL, userID: Data, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         additionalContextCheck: @escaping () throws -> Void = {},
         physicalAccess: PhysicalCapacityLegacyAccess? = nil) throws {
        try RecycleVault.requireLabRoot(root); try FileEffectMetadata.subject(userID)
        self.physicalAccess = physicalAccess
        self.root = root; self.userID = userID; self.now = now; self.additionalContextCheck = additionalContextCheck; store = try PortableInstance.store(root)
        databaseVersion = try PortableInstance.databaseDescriptor(root).version()
        try require([4,5,6].contains(databaseVersion), .unsupported)
        _ = try context(write: false)
        try store.validate(expectedVersion: databaseVersion)
        try requireNamespaceAccess()
    }
    private func requireNamespaceAccess(_ action: RecycleHostAction? = nil) throws {
        if let physicalAccess {
            try require(physicalAccess.root == root && physicalAccess.userID == userID && databaseVersion == 6, .denied)
            if let action { try physicalAccess.check(action) } else { try physicalAccess.check() }
        } else if databaseVersion >= 6 {
            try require(try store.rows("SELECT EXISTS(SELECT 1 FROM macnas.physical_capacity_scopes);") == [["f"]], .unsupported)
        }
    }
    private func context(write: Bool) throws -> (InstanceIdentity, HostBinding) {
        try additionalContextCheck()
        if let physicalAccess { try physicalAccess.check() }
        else { try require(!FileManager.default.fileExists(atPath: root.appendingPathComponent(FixturePhysicalCapacityNamespace.markerPath).path), .unsupported) }
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        let config = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try FileEffectMetadata.text(binding.hostID, maximum: 256)
        try require(config.schemaVersion == 1 && identity.kind == "synthetic-prototype" && identity.schemaVersion == 1 && identity.generation >= 0
                    && binding.databaseName == store.databaseName && !binding.hostID.isEmpty
                    && config.users.filter({ Data($0.id.utf8) == userID }).map(\.role) == ["administrator"], .denied)
        try require(["synthetic_development", "read_only_recovery", "rolled_back_recovery"].contains(binding.mode), .denied)
        if write { try require(binding.mode == "synthetic_development", .denied) }
        try require(try PortableInstance.databaseDescriptor(root).version() == databaseVersion, .invalidSchema)
        return (identity, binding)
    }
    func registration() throws -> RecycleVaultRegistration {
        let (identity, binding) = try context(write: false)
        let bytes = try SafeFS.readData(SafeFS.resolve(root, RecycleVault.registrationPath), maximumBytes: 8192)
        let value = try FileEffectMetadata.decode(RecycleVaultRegistration.self, from: bytes)
        try require(value.version == 1 && value.instanceID == identity.instanceID && value.generation == Int64(identity.generation)
                    && value.databaseName == store.databaseName && Data(value.hostID.utf8) == Data(binding.hostID.utf8), .staleState)
        try require(value.ownerUserHex == FileEffectMetadata.hex(userID), .denied)
        try value.validateMetadata()
        return value
    }
    /// The only creation entry: fresh fixed-layout synthetic directories beneath this TestLab instance.
    func createFreshFixture(confirmed: Bool) throws -> RecycleVaultRegistration {
        try require(confirmed, .denied); try requireNamespaceAccess()
        let gate = try InstanceLock(root, timeout: 1)
        return try withExtendedLifetime(gate) {
            _ = try context(write: true)
            return try RecycleVault.create(root: root, store: store, userID: userID)
        }
    }
    func approve(_ action: RecycleHostAction, confirmed: Bool) throws -> RecycleHostGrant {
        try require(action != .restoreDestination, .denied)
        return try issue(action, destinationParentPath: nil, destinationParentStamp: nil, confirmed: confirmed)
    }
    func approveRestoreDestination(parentPath: String, confirmed: Bool) throws -> RecycleHostGrant {
        try FileEffectMetadata.path(parentPath, empty: true)
        try physicalAccess?.checkDestination(parentPath)
        try require(confirmed, .denied); _ = try context(write: true)
        let registered = try registration(), directory = try destinationDirectory(parentPath, registration: registered)
        return try issue(.restoreDestination, destinationParentPath: Data(parentPath.utf8), destinationParentStamp: directory.identity, confirmed: true)
    }
    private func destinationDirectory(_ path: String, registration: RecycleVaultRegistration) throws -> RecycleDirectory {
        var directory = try RecycleDirectory(root.appendingPathComponent(RecycleVault.fixturePath + "/library"), privateMode: true)
        try require(directory.identity.device == registration.device && directory.identity.inode == registration.libraryInode, .staleState)
        for part in path.split(separator: "/") { directory = try directory.child(String(part)) }
        return directory
    }
    private func issue(_ action: RecycleHostAction, destinationParentPath: Data?, destinationParentStamp: FileEffectStamp?, confirmed: Bool) throws -> RecycleHostGrant {
        try require(confirmed, .denied); _ = try context(write: action != .observe)
        let registered = try FileEffectMetadata.encoded(registration())
        lock.lock(); defer { lock.unlock() }
        grants = grants.filter { $0.value.1 > now() }
        try require(grants.count < 8 && revision < UInt64.max, .budgetExceeded)
        let value = RecycleHostGrant(id: UUID(), host: host, action: action, revision: revision,
            destinationParentPath: destinationParentPath, destinationParentStamp: destinationParentStamp)
        grants[value.id] = (value, now() + 1800, registered)
        return value
    }
    func revokeAll() {
        lock.lock(); defer { lock.unlock() }; grants.removeAll()
        // Exhaustion permanently revokes this host; a new host still needs an explicit grant.
        if revision < UInt64.max { revision += 1 }
    }
    func validate(_ grant: RecycleHostGrant, action: RecycleHostAction, registration expected: RecycleVaultRegistration? = nil) throws {
        try physicalAccess?.check(action)
        lock.lock()
        let held = grants[grant.id], current = revision
        lock.unlock()
        try require(grant.host == host && grant.action == action && grant.revision == current
                    && held?.0 == grant && (held?.1 ?? 0) > now(), .denied)
        _ = try context(write: action != .observe)
        let actual = try registration()
        try require(try FileEffectMetadata.encoded(actual) == held?.2, .staleState)
        if let expected { try require(try FileEffectMetadata.encoded(actual) == FileEffectMetadata.encoded(expected), .staleState) }
        if action == .restoreDestination {
            guard let path = grant.destinationParentPath, let stamp = grant.destinationParentStamp else { throw NASError.denied }
            let current = try destinationDirectory(String(decoding: path, as: UTF8.self), registration: actual)
            try require(RecycleDirectory.sameIdentity(stamp, current.identity), .staleState)
        }
    }
    func withLockedVault<T>(_ grant: RecycleHostGrant, action: RecycleHostAction, destinationGrant: RecycleHostGrant? = nil,
                            _ body: (FileEffectExecutionPermit) throws -> T) throws -> T {
        try require(action != .restoreDestination, .denied)
        if action == .restore { try require(destinationGrant != nil, .denied) }
        let gate = try InstanceLock(root, mode: .shared, timeout: 1)
        try requireNamespaceAccess(action)
        try validate(grant, action: action)
        let registration = try self.registration()
        if let destinationGrant {
            try require([RecycleHostAction.restore, .settle].contains(action) && destinationGrant.destinationParentPath != nil, .denied)
            try validate(destinationGrant, action: .restoreDestination, registration: registration)
        }
        // No library/vault descriptor is opened until the explicit fresh grant has passed.
        let vault = try RecycleVault(root: root, registration: registration), serial = try vault.lock()
        let origin = try TransferEncoding.digest(FileEffectMetadata.encoded(registration) + userID + Data(grant.id.uuidString.utf8)
            + Data((destinationGrant?.id.uuidString ?? "").utf8) + (destinationGrant?.destinationParentPath ?? Data()))
        let permit = FileEffectExecutionPermit(action: action, registration: registration, userID: userID,
            originScopeSHA256: origin, vault: vault, instanceGate: gate, vaultLock: serial,
            destinationParentPath: destinationGrant?.destinationParentPath,
            destinationParentStamp: destinationGrant?.destinationParentStamp,
            validate: {
                try self.validate(grant, action: action, registration: registration)
                if let destinationGrant { try self.validate(destinationGrant, action: .restoreDestination, registration: registration) }
            })
        return try withExtendedLifetime(permit) {
            try permit.check(action); try physicalAccess?.checkLocked(permit)
            let result = try body(permit); try permit.check(action); return result
        }
    }
}
