import Foundation

struct RecycleObservationAnchor: Equatable {
    let instanceID: UUID
    let generation: Int
    let databaseName: Data
    let hostID: Data
    let databaseSchema: Int
    init(root: URL, identity: InstanceIdentity) throws {
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        instanceID = identity.instanceID; generation = identity.generation
        databaseName = Data(binding.databaseName.utf8); hostID = Data(binding.hostID.utf8)
        databaseSchema = try PortableInstance.databaseDescriptor(root).version()
    }
}
struct RecycleObservationReadScope: Equatable {
    let sessionID: UUID
    let anchor: RecycleObservationAnchor
    let userID: Data
    let role: String
    let mode: String
}

/// Deliberately excludes all filesystem stamps, absolute/vault paths and execution approvals.
public struct RecycleOperationRecord: Encodable, Equatable, Sendable {
    public let operationID: String
    public let entryID: String
    public let kind: String
    public let phase: String
    public let revision: Int64
    public let entryRevision: Int64
    public let chargeState: String
    public let chargedBytes: Int64
    public let ownerUserHex: String
    public let intentSHA256: String
    init(_ value: FileEffectJournalRecord) throws {
        try require((1...9_007_199_254_740_991).contains(value.revision)
                    && (1...9_007_199_254_740_991).contains(value.entryRevision)
                    && (0...DurableFileEffectJournal.fileBytes).contains(value.chargedBytes), .invalidSchema)
        try FileEffectMetadata.hash(value.intentSHA256)
        if value.chargeState == .released { try require(value.chargedBytes == 0, .invalidSchema) }
        if value.kind == .restore {
            try require(value.chargeState != .reserved, .invalidSchema)
            if value.phase == .completed { try require(value.chargeState == .released, .invalidSchema) }
            else if value.phase != .cancelled { try require(value.chargeState == .retained, .invalidSchema) }
        } else if value.phase == .cancelled { try require(value.chargeState == .released, .invalidSchema) }
        else if value.phase == .completed { try require(value.chargeState != .reserved, .invalidSchema) }
        else { try require(value.chargeState == .reserved, .invalidSchema) }
        operationID = value.operationID.uuidString.lowercased(); entryID = value.entryID.uuidString.lowercased()
        kind = value.kind.rawValue; phase = value.phase.rawValue; revision = value.revision; entryRevision = value.entryRevision
        chargeState = value.chargeState.rawValue; chargedBytes = value.chargedBytes
        ownerUserHex = value.ownerUserHex; intentSHA256 = value.intentSHA256
    }
}
public struct RecycleOperationObservation: Encodable, Sendable {
    public let observationVersion = 1
    public let operationID: String
    public let visibility: String
    public let record: RecycleOperationRecord?
    public let classification: String
    enum CodingKeys: String, CodingKey { case observationVersion, operationID, visibility, record, classification }
    init(operationID: UUID, value: RecycleFileObservation, owner: Data) throws {
        self.operationID = operationID.uuidString.lowercased()
        try FileEffectMetadata.subject(owner)
        try require(["notVisible","notObserved","sourceOnly","candidateMoved","matchedPost","changed","ambiguous"].contains(value.classification), .invalidSchema)
        if let snapshot = value.snapshot {
            try require(snapshot.record.operationID == operationID && snapshot.record.ownerUserHex == FileEffectMetadata.hex(owner), .denied)
            record = try RecycleOperationRecord(snapshot.record); visibility = "visible"
            try require(value.classification != "notVisible", .invalidSchema)
            let phase = snapshot.record.phase
            if [.observed, .completed].contains(phase) { try require(snapshot.postEvidence != nil, .invalidSchema) }
            switch value.classification {
            case "matchedPost": try require([.observed, .uncertain, .completed].contains(phase) && snapshot.postEvidence != nil, .invalidSchema)
            case "notObserved": try require([.prepared, .cancelled].contains(phase), .invalidSchema)
            case "sourceOnly": try require(![.prepared, .cancelled, .completed].contains(phase), .invalidSchema)
            case "changed": try require(phase == .completed, .invalidSchema)
            case "candidateMoved": try require(![.observed, .completed].contains(phase), .invalidSchema)
            default: break
            }
        } else {
            try require(value.classification == "notVisible", .invalidSchema)
            record = nil; visibility = "notVisible"
        }
        classification = value.classification
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(observationVersion, forKey: .observationVersion); try c.encode(operationID, forKey: .operationID)
        try c.encode(visibility, forKey: .visibility); try c.encode(classification, forKey: .classification)
        if let record { try c.encode(record, forKey: .record) } else { try c.encodeNil(forKey: .record) }
    }
}

/// Opaque equality marker for this approved API/session/registration. It is not an authentication credential.
public struct RecycleObservationContext: Encodable, Equatable, Sendable {
    public let contextVersion = 1
    public let source = "fixture-host"
    public let scopeID: String
    public let userID: String
    public let role: String
    public let mode: String
}
public struct RecycleOperationObservationEnvelope: Encodable, Sendable {
    public let observationEnvelopeVersion = 1
    public let context: RecycleObservationContext
    public let observation: RecycleOperationObservation
}

final class RecycleObservationRegistry {
    final class Entry {
        let scope: RecycleObservationReadScope
        let authority: FixtureRecycleAuthority
        let coordinator: FixtureRecycleCoordinator
        let grant: RecycleHostGrant
        let context: RecycleObservationContext
        init(scope: RecycleObservationReadScope, authority: FixtureRecycleAuthority, grant: RecycleHostGrant, context: RecycleObservationContext) {
            self.scope = scope; self.authority = authority; self.grant = grant; self.context = context
            coordinator = FixtureRecycleCoordinator(authority: authority)
        }
    }
    private let lock = NSLock()
    private var entries: [UUID: Entry] = [:]
    func register(_ entry: Entry) throws {
        lock.lock(); defer { lock.unlock() }
        try require(entries[entry.scope.sessionID] != nil || entries.count < 8, .budgetExceeded)
        entries[entry.scope.sessionID]?.authority.revokeAll()
        entries[entry.scope.sessionID] = entry
    }
    func entry(_ scope: RecycleObservationReadScope) throws -> Entry {
        lock.lock(); defer { lock.unlock() }
        guard let value = entries[scope.sessionID], value.scope == scope else { throw NASError.denied }
        return value
    }
    func removeIfCurrent(_ entry: Entry) {
        lock.lock(); defer { lock.unlock() }
        if entries[entry.scope.sessionID] === entry { entries.removeValue(forKey: entry.scope.sessionID)?.authority.revokeAll() }
    }
    func endSession(_ id: UUID) {
        lock.lock(); defer { lock.unlock() }
        entries.removeValue(forKey: id)?.authority.revokeAll()
    }
}

extension PrototypePlatformAPI {
    /// Host-only approval. It is never a desktop message, and grants no write or settlement capability.
    public func authorizeFixtureRecycleObservation(session: PrototypeSession, confirmed: Bool) throws {
        try require(confirmed, .denied)
        let scope = try recycleObservationScope(session)
        let authority = try FixtureRecycleAuthority(root: root, userID: scope.userID, additionalContextCheck: { [weak self] in
            guard let self else { throw NASError.denied }
            try require(try self.recycleObservationScope(session) == scope, .denied)
        })
        let grant = try authority.approve(.observe, confirmed: true)
        try require(try recycleObservationScope(session) == scope, .denied)
        let registration = try authority.registration()
        try authority.validate(grant, action: .observe, registration: registration)
        let context = try makeRecycleObservationContext(scope: scope, registration: registration)
        let entry = RecycleObservationRegistry.Entry(scope: scope, authority: authority, grant: grant, context: context)
        try recycleObservationReads.register(entry)
        do { try require(try recycleObservationScope(session) == scope, .denied) }
        catch { recycleObservationReads.removeIfCurrent(entry); throw error }
    }
    public func revokeFixtureRecycleObservation(session: PrototypeSession) {
        recycleObservationReads.endSession(session.id)
    }
    public func observeFixtureRecycleOperation(operationID: String, session: PrototypeSession) throws -> RecycleOperationObservation {
        try withFixtureRecycleOperationObservation(operationID: operationID, session: session) { $0 }
    }
    func withFixtureRecycleOperationObservation<T>(operationID: String, session: PrototypeSession,
                                                   _ render: (RecycleOperationObservation) throws -> T) throws -> T {
        try withBoundFixtureRecycleOperationObservation(operationID: operationID, session: session) { value, _ in try render(value) }
    }
    func withBoundFixtureRecycleOperationObservation<T>(operationID: String, session: PrototypeSession,
                                                       _ render: (RecycleOperationObservation, RecycleObservationContext) throws -> T) throws -> T {
        guard let id = UUID(uuidString: operationID), Data(operationID.utf8) == Data(id.uuidString.lowercased().utf8) else { throw NASError.invalidSchema }
        let scope = try recycleObservationScope(session), entry = try recycleObservationReads.entry(scope)
        let value = try entry.coordinator.observe(operationID: id, grant: entry.grant)
        try require(try recycleObservationScope(session) == scope, .denied)
        let projected = try RecycleOperationObservation(operationID: id, value: value, owner: scope.userID)
        let rendered = try render(projected, entry.context)
        try require(try recycleObservationScope(session) == scope, .denied)
        try entry.authority.validate(entry.grant, action: .observe)
        return rendered
    }
}
