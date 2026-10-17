import Foundation
import CryptoKit

/// Shares a data-only context shape with the ledger, while
/// issuing independent purposes, grants, per-API keys and source domains.
final class ManagedRecycleObservationRegistry {
    final class Entry {
        let scope: RecycleObservationReadScope
        let host: FixturePhysicalCapacityNamespace
        let grant: PhysicalCapacityGrant
        let context: CapacityLedgerReadContext
        init(scope: RecycleObservationReadScope, host: FixturePhysicalCapacityNamespace,
             grant: PhysicalCapacityGrant, context: CapacityLedgerReadContext) {
            self.scope = scope; self.host = host; self.grant = grant; self.context = context
        }
    }
    private let nonce = SymmetricKey(size: .bits256)
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    func context(scope: RecycleObservationReadScope, host: FixturePhysicalCapacityNamespace,
                 grant: PhysicalCapacityGrant) throws -> CapacityLedgerReadContext {
        try require(grant.purpose == .managedObserve, .denied)
        let parts = [Data("macnas-managed-recycle-observation-source-v1".utf8), Data(scope.sessionID.uuidString.lowercased().utf8),
            Data(scope.anchor.instanceID.uuidString.lowercased().utf8), Data(String(scope.anchor.generation).utf8),
            scope.anchor.databaseName, scope.anchor.hostID, Data(String(scope.anchor.databaseSchema).utf8), scope.userID,
            Data(scope.role.utf8), Data(scope.mode.utf8), try FileEffectMetadata.encoded(host.registration),
            try FileEffectMetadata.encoded(host.registry), Data(grant.id.uuidString.lowercased().utf8),
            Data(grant.host.uuidString.lowercased().utf8), Data(String(grant.epoch).utf8)]
        var framed = Data()
        for part in parts { framed.append(Data("\(part.count):".utf8)); framed.append(part) }
        let sourceID = HMAC<SHA256>.authenticationCode(for: framed, using: nonce).map { String(format: "%02x", $0) }.joined()
        return .init(scopeID: host.registration.scopeID.uuidString.lowercased(), sourceID: sourceID,
                     userID: String(decoding: scope.userID, as: UTF8.self), role: scope.role, mode: scope.mode)
    }
    func register(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        try require(entries[entry.scope.sessionID] != nil || entries.count < 8, .budgetExceeded)
        entries[entry.scope.sessionID]?.host.revokeAll(); entries[entry.scope.sessionID] = entry
    }
    func entry(_ scope: RecycleObservationReadScope) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        guard let entry = entries[scope.sessionID], entry.scope == scope else { throw NASError.denied }
        return entry
    }
    func removeIfCurrent(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if entries[entry.scope.sessionID] === entry { entries.removeValue(forKey: entry.scope.sessionID)?.host.revokeAll() }
    }
    func endSession(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }; entries.removeValue(forKey: id)?.host.revokeAll()
    }
}

extension PrototypePlatformAPI {
    public func authorizeFixtureManagedRecycleObservation(session: PrototypeSession, confirmed: Bool) throws {
        try authorizeManagedRecycleObservation(session: session, confirmed: confirmed, now: { ProcessInfo.processInfo.systemUptime })
    }
    func authorizeManagedRecycleObservation(session: PrototypeSession, confirmed: Bool, now: @escaping () -> TimeInterval) throws {
        try require(confirmed, .denied)
        let scope = try capacityLedgerReadScope(session)
        let host = try FixturePhysicalCapacityNamespace(root: root, userID: scope.userID, now: now,
            additionalContextCheck: { [weak self] in
                guard let self else { throw NASError.denied }
                try require(try self.capacityLedgerReadScope(session) == scope, .denied)
            })
        let grant = try host.approveManagedObserve(confirmed: true)
        let context = try managedRecycleObservationReads.context(scope: scope, host: host, grant: grant)
        let entry = ManagedRecycleObservationRegistry.Entry(scope: scope, host: host, grant: grant, context: context)
        try host.withManagedObservationContext(grant) { try require(try self.capacityLedgerReadScope(session) == scope, .denied) }
        try managedRecycleObservationReads.register(entry)
        do { try host.validate(grant) }
        catch { managedRecycleObservationReads.removeIfCurrent(entry); throw error }
    }
    public func revokeFixtureManagedRecycleObservation(session: PrototypeSession) { managedRecycleObservationReads.endSession(session.id) }
    public func fixtureManagedRecycleObservationContext(session: PrototypeSession) throws -> CapacityLedgerReadContext {
        try withFixtureManagedRecycleObservationContext(session: session) { $0 }
    }
    func withFixtureManagedRecycleObservationContext<T>(session: PrototypeSession,
                                                        _ render: (CapacityLedgerReadContext) throws -> T) throws -> T {
        let scope = try capacityLedgerReadScope(session), entry = try managedRecycleObservationReads.entry(scope)
        return try entry.host.withManagedObservationContext(entry.grant) {
            let result = try render(entry.context)
            try require(try self.capacityLedgerReadScope(session) == scope, .denied)
            try require(try self.managedRecycleObservationReads.entry(scope) === entry, .denied)
            return result
        }
    }
    public func observeFixtureManagedRecycleOperation(scopeID: String, sourceID: String, operationID: String,
                                                      session: PrototypeSession) throws -> ManagedRecycleObservationView {
        try withFixtureManagedRecycleOperationObservation(scopeID: scopeID, sourceID: sourceID, operationID: operationID, session: session) { $0 }
    }
    func withFixtureManagedRecycleOperationObservation<T>(scopeID: String, sourceID: String, operationID: String,
                                                          session: PrototypeSession,
                                                          _ render: (ManagedRecycleObservationView) throws -> T) throws -> T {
        guard let id = UUID(uuidString: operationID), operationID == id.uuidString.lowercased(),
              let scopeUUID = UUID(uuidString: scopeID), scopeID == scopeUUID.uuidString.lowercased() else { throw NASError.invalidSchema }
        try FileEffectMetadata.hash(sourceID)
        let scope = try capacityLedgerReadScope(session), entry = try managedRecycleObservationReads.entry(scope)
        try require(entry.context.scopeID == scopeID && entry.context.sourceID == sourceID, .denied)
        return try entry.host.withManagedObservation(entry.grant, operationID: id) { value, allocation, digest in
            let view = try ManagedRecycleObservationView(operationID: id, value: value, allocation: allocation,
                scopeID: scopeUUID, context: entry.context, registry: entry.host.registry, intentDigest: digest)
            let result = try render(view)
            try require(try self.capacityLedgerReadScope(session) == scope, .denied)
            try require(try self.managedRecycleObservationReads.entry(scope) === entry, .denied)
            return result
        }
    }
}
