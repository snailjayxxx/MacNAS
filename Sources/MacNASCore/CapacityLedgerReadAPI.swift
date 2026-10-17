import Foundation
import CryptoKit

/// Equality context for one host-approved ledger read. Never an execution credential.
public struct CapacityLedgerReadContext: Encodable, Equatable, Sendable {
    public let contextVersion = 1
    public let source = "fixture-host"
    public let scopeID: String
    public let sourceID: String
    public let userID: String
    public let role: String
    public let mode: String
}

final class CapacityLedgerReadRegistry {
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
        let parts = [Data("macnas-capacity-ledger-source-v1".utf8), Data(scope.sessionID.uuidString.lowercased().utf8),
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
    func capacityLedgerReadScope(_ session: PrototypeSession) throws -> RecycleObservationReadScope {
        let scope = try recycleObservationScope(session)
        try require(scope.anchor.databaseSchema == 6, .unsupported)
        return scope
    }
    /// Host-only, separate from observation/inspection/execution approval. Never a desktop message.
    public func authorizeFixtureCapacityLedgerRead(session: PrototypeSession, confirmed: Bool) throws {
        try authorizeCapacityLedgerRead(session: session, confirmed: confirmed, now: { ProcessInfo.processInfo.systemUptime })
    }
    func authorizeCapacityLedgerRead(session: PrototypeSession, confirmed: Bool, now: @escaping () -> TimeInterval) throws {
        try require(confirmed, .denied)
        let scope = try capacityLedgerReadScope(session)
        let host = try FixturePhysicalCapacityNamespace(root: root, userID: scope.userID, now: now,
            additionalContextCheck: { [weak self] in
                guard let self else { throw NASError.denied }
                try require(try self.capacityLedgerReadScope(session) == scope, .denied)
            })
        let grant = try host.approveLedgerRead(confirmed: true)
        let context = try capacityLedgerReads.context(scope: scope, host: host, grant: grant)
        let entry = CapacityLedgerReadRegistry.Entry(scope: scope, host: host, grant: grant, context: context)
        // Approval also proves the actual roots/private binding/lock identity. No payload audit.
        try host.withLedgerRead(grant) { _ in try require(try self.capacityLedgerReadScope(session) == scope, .denied) }
        try capacityLedgerReads.register(entry)
        do { try host.validate(grant) }
        catch { capacityLedgerReads.removeIfCurrent(entry); throw error }
    }
    public func revokeFixtureCapacityLedgerRead(session: PrototypeSession) { capacityLedgerReads.endSession(session.id) }
    public func fixtureCapacityLedgerContext(session: PrototypeSession) throws -> CapacityLedgerReadContext {
        try withFixtureCapacityLedgerRead(session: session) { _, entry in entry.context }
    }
    func withFixtureCapacityLedgerContext<T>(session: PrototypeSession, _ render: (CapacityLedgerReadContext) throws -> T) throws -> T {
        try withFixtureCapacityLedgerRead(session: session) { _, entry in try render(entry.context) }
    }
    public func listFixtureCapacityLedger(scopeID: String, sourceID: String, session: PrototypeSession) throws -> CapacityLedgerListView {
        try withFixtureCapacityLedgerList(scopeID: scopeID, sourceID: sourceID, session: session) { $0 }
    }
    func withFixtureCapacityLedgerList<T>(scopeID: String, sourceID: String, session: PrototypeSession,
                                        _ render: (CapacityLedgerListView) throws -> T) throws -> T {
        guard let id = UUID(uuidString: scopeID), scopeID == id.uuidString.lowercased() else { throw NASError.invalidSchema }
        try FileEffectMetadata.hash(sourceID)
        return try withFixtureCapacityLedgerRead(session: session) { permit, entry in
            try require(entry.context.scopeID == scopeID && entry.context.sourceID == sourceID, .denied)
            return try render(permit.ledger().completeReadOnlyList(sourceID: sourceID))
        }
    }
    private func withFixtureCapacityLedgerRead<T>(session: PrototypeSession,
                                                   _ body: (PhysicalCapacityPermit, CapacityLedgerReadRegistry.Entry) throws -> T) throws -> T {
        let scope = try capacityLedgerReadScope(session), entry = try capacityLedgerReads.entry(scope)
        return try entry.host.withLedgerRead(entry.grant) { permit in
            let result = try body(permit, entry)
            try require(try self.capacityLedgerReadScope(session) == scope, .denied)
            try require(try self.capacityLedgerReads.entry(scope) === entry, .denied)
            try permit.check()
            return result
        }
    }
}
