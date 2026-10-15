import Foundation

public enum FixtureVolumeAccess: String, Codable { case readOnly, readWrite }
public enum FixtureVolumeState: String, Codable {
    case missing, ambiguous, systemVolume, authorizationRequired, readOnly
    case needsBinding, identityChanged, readyReadOnly, readyReadWrite
}

/// Injected test inventory only. No real disks are enumerated or authorized by these values.
public struct FixtureVolumeObservation: Codable, Equatable {
    public var volumeID: UUID
    public var mediaID: UUID
    public var mountID: UUID
    public var displayName: String
    public var cabinetID: String
    public var isSystem: Bool
    public var isReadOnly: Bool
    public var authorized: Bool
    public init(volumeID: UUID, mediaID: UUID = UUID(), mountID: UUID = UUID(),
                displayName: String, cabinetID: String = "fixture-cabinet",
                isSystem: Bool = false, isReadOnly: Bool = false, authorized: Bool = false) {
        self.volumeID = volumeID; self.mediaID = mediaID; self.mountID = mountID
        self.displayName = displayName; self.cabinetID = cabinetID
        self.isSystem = isSystem; self.isReadOnly = isReadOnly; self.authorized = authorized
    }
}

public struct FixtureVolumeStatus: Codable, Equatable {
    public let libraryID: String
    public let volumeID: UUID
    public let state: FixtureVolumeState
    public let inventoryRevision: UInt64
}
public struct FixtureVolumePreview: Codable, Equatable {
    public let id: UUID
    public let registryID: UUID
    public let libraryID: String
    public let volumeID: UUID
    public let mountID: UUID?
    public let mediaID: UUID?
    public let displayName: String?
    public let cabinetID: String?
    public let requestedAccess: FixtureVolumeAccess
    public let state: FixtureVolumeState
    public let inventoryRevision: UInt64
}

public struct FixtureLibrarySummary: Codable, Equatable {
    public let libraryID: String
    public let volumeID: UUID
    public let estimatedBytes: Int64
    public let state: FixtureVolumeState
}

struct FixtureVolumePermit {
    let reference: VolumeReference
    let observation: FixtureVolumeObservation
    let approvalID: UUID
    let revision: UInt64
}

/// Host/session state, deliberately absent from portable exports. A restart requires a fresh binding.
final class FixtureVolumeRegistry: @unchecked Sendable {
    let references: [VolumeReference]
    private let lock = NSLock()
    private let identity = UUID()
    private var revision: UInt64 = 0
    private var inventory: [FixtureVolumeObservation] = []
    private struct Binding { let mediaID: UUID; let mountID: UUID; let access: FixtureVolumeAccess; let approvalID: UUID }
    private struct Pending { let preview: FixtureVolumePreview; let caller: UUID; let expires: Date }
    private var bindings: [String: Binding] = [:]
    private var pending: [UUID: Pending] = [:]
    private var readers: [String: Set<String>] = [:]

    init(references: [VolumeReference]) throws {
        try require(references.count <= 1024 && Set(references.map(\.libraryID)).count == references.count, .invalidSchema)
        for reference in references {
            try require(!reference.libraryID.isEmpty && reference.libraryID.utf8.count <= 128 && reference.estimatedBytes >= 0, .invalidSchema)
            try SafeFS.relative(reference.relativePath)
        }
        self.references = references
    }
    private func advance() throws { try require(revision < UInt64.max, .budgetExceeded); revision += 1 }
    private func reference(_ id: String) throws -> VolumeReference {
        guard let value = references.first(where: { $0.libraryID == id }) else { throw NASError.denied }
        return value
    }
    private func candidates(_ reference: VolumeReference) -> [FixtureVolumeObservation] {
        inventory.filter { $0.volumeID == reference.volumeID }
    }
    private func eligible(_ observation: FixtureVolumeObservation) -> Bool {
        !observation.isSystem && observation.authorized
    }
    private func state(_ reference: VolumeReference) -> FixtureVolumeState {
        let matches = candidates(reference)
        guard !matches.isEmpty else { return .missing }
        guard matches.count == 1 else { return .ambiguous }
        let observation = matches[0]
        if observation.isSystem { return .systemVolume }
        if !observation.authorized { return .authorizationRequired }
        guard let binding = bindings[reference.libraryID] else { return .needsBinding }
        guard binding.mediaID == observation.mediaID && binding.mountID == observation.mountID else { return .identityChanged }
        return observation.isReadOnly || binding.access == .readOnly ? .readyReadOnly : .readyReadWrite
    }
    func update(_ observations: [FixtureVolumeObservation]) throws {
        lock.lock(); defer { lock.unlock() }
        try require(observations.count <= 1024, .budgetExceeded)
        for value in observations {
            try require(!value.displayName.isEmpty && value.displayName.utf8.count <= 256
                        && !value.cabinetID.isEmpty && value.cabinetID.utf8.count <= 128, .invalidSchema)
        }
        try advance()
        inventory = observations
        // Once identity/authorization is lost, returning to the old name or UUID never restores a grant.
        for reference in references {
            let values = candidates(reference)
            if let binding = bindings[reference.libraryID],
               !(values.count == 1 && eligible(values[0]) && binding.mediaID == values[0].mediaID && binding.mountID == values[0].mountID) {
                bindings.removeValue(forKey: reference.libraryID)
            }
        }
    }
    func summaries(user: LogicalUser) -> [FixtureLibrarySummary] {
        lock.lock(); defer { lock.unlock() }
        return references.filter { user.role == "administrator" || readers[$0.libraryID, default: []].contains(user.id) }
            .map { .init(libraryID: $0.libraryID, volumeID: $0.volumeID, estimatedBytes: $0.estimatedBytes, state: state($0)) }
    }
    func statuses() -> [FixtureVolumeStatus] {
        lock.lock(); defer { lock.unlock() }
        return references.map { .init(libraryID: $0.libraryID, volumeID: $0.volumeID, state: state($0), inventoryRevision: revision) }
    }
    func preview(libraryID: String, access: FixtureVolumeAccess, caller: UUID, now: Date = Date()) throws -> FixtureVolumePreview {
        lock.lock(); defer { lock.unlock() }
        let reference = try reference(libraryID), values = candidates(reference)
        let observation = values.count == 1 ? values[0] : nil
        let current = state(reference)
        let result = FixtureVolumePreview(id: UUID(), registryID: identity, libraryID: libraryID, volumeID: reference.volumeID,
            mountID: observation?.mountID, mediaID: observation?.mediaID, displayName: observation?.displayName,
            cabinetID: observation?.cabinetID, requestedAccess: access,
            state: observation.map { eligible($0) && $0.isReadOnly && access == .readWrite } == true ? .readOnly : current,
            inventoryRevision: revision)
        pending = pending.filter { $0.value.expires > now }
        if let observation, eligible(observation), !(observation.isReadOnly && access == .readWrite) {
            try require(pending.count < 128, .budgetExceeded)
            pending[result.id] = Pending(preview: result, caller: caller, expires: now.addingTimeInterval(30))
        }
        return result
    }
    func commit(_ preview: FixtureVolumePreview, caller: UUID, confirmed: Bool, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        guard let grant = pending.removeValue(forKey: preview.id) else { throw NASError.replay }
        try require(grant.preview == preview && grant.caller == caller && preview.registryID == identity && confirmed, .denied)
        try require(now < grant.expires, .expired)
        try require(revision == preview.inventoryRevision, .staleState)
        let reference = try reference(preview.libraryID), values = candidates(reference)
        try require(values.count == 1, .missingVolume)
        let observation = values[0]
        try require(eligible(observation) && !(observation.isReadOnly && preview.requestedAccess == .readWrite), .denied)
        try require(observation.mountID == preview.mountID && observation.mediaID == preview.mediaID, .staleState)
        try advance()
        bindings[reference.libraryID] = Binding(mediaID: observation.mediaID, mountID: observation.mountID,
                                              access: preview.requestedAccess, approvalID: preview.id)
    }
    func revoke(libraryID: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try reference(libraryID); try advance()
        bindings.removeValue(forKey: libraryID)
        pending = pending.filter { $0.value.preview.libraryID != libraryID }
    }
    func endSession(_ caller: UUID) {
        lock.lock(); defer { lock.unlock() }
        pending = pending.filter { $0.value.caller != caller }
    }
    func setReaders(_ users: Set<String>, libraryID: String) throws {
        lock.lock(); defer { lock.unlock() }
        _ = try reference(libraryID); try advance(); readers[libraryID] = users
    }
    func permit(libraryID: String, user: LogicalUser, access: FixtureVolumeAccess = .readOnly) throws -> FixtureVolumePermit {
        lock.lock(); defer { lock.unlock() }
        let reference = try reference(libraryID)
        try require(user.role == "administrator" || (access == .readOnly && readers[libraryID, default: []].contains(user.id)), .denied)
        let current = state(reference)
        if current == .missing || current == .ambiguous { throw NASError.missingVolume }
        try require(current == .readyReadWrite || (access == .readOnly && current == .readyReadOnly), .denied)
        guard let binding = bindings[libraryID], let observation = candidates(reference).first else { throw NASError.denied }
        return FixtureVolumePermit(reference: reference, observation: observation, approvalID: binding.approvalID, revision: revision)
    }
    func validate(_ permit: FixtureVolumePermit, user: LogicalUser, access: FixtureVolumeAccess = .readOnly) throws {
        let current = try self.permit(libraryID: permit.reference.libraryID, user: user, access: access)
        try require(current.revision == permit.revision && current.approvalID == permit.approvalID
                    && current.observation.mountID == permit.observation.mountID, .staleState)
    }
}
