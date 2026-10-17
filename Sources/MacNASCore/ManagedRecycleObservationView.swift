import Foundation

/// Pure projection; caller supplies an independently approved, locked and digest-verified observation.
public struct ManagedCapacityAllocationView: Encodable, Sendable {
    public let allocationID: String
    public let origin: String
    public let intentSHA256: String
    public let declaredBytes: Int64
    public let state: String
    public let revision: Int64
    public let sha256: String
    init(_ record: CapacityAllocation, scopeID: UUID) throws {
        try require(record.scopeID == scopeID && record.state == .owned, .denied)
        try require(record.origin != .initial && record.revision == 3
                    && (0...DurableCapacityLedger.fileLimit).contains(record.declaredBytes), .invalidSchema)
        try FileEffectMetadata.hash(record.intentSHA256)
        guard let sha = record.sha256 else { throw NASError.invalidSchema };try FileEffectMetadata.hash(sha)
        allocationID = record.allocationID.uuidString.lowercased(); origin = record.origin.rawValue
        intentSHA256 = record.intentSHA256;declaredBytes = record.declaredBytes
        state = record.state.rawValue;revision = record.revision;sha256 = sha
    }
}

/// Keeps the old exact C1 body and the conserved owned charge separate.
/// A caller must supply a genuinely observed/bound snapshot; this pure type cannot prove that.
public struct ManagedRecycleObservationView: Encodable, Sendable {
    public let managedObservationVersion = 1
    public let context: CapacityLedgerReadContext
    public let allocation: ManagedCapacityAllocationView?
    public let observation: RecycleOperationObservation
    enum CodingKeys: String, CodingKey { case managedObservationVersion, context, allocation, observation }
    init(operationID: UUID, value: RecycleFileObservation, allocation record: CapacityAllocation?,
         scopeID: UUID, context: CapacityLedgerReadContext, registry: RecycleVaultRegistration,
         intentDigest: ManagedRecycleIntentDigest?) throws {
        try registry.validateMetadata();try FileEffectMetadata.subject(Data(context.userID.utf8));try FileEffectMetadata.hash(context.sourceID)
        try require(context.scopeID == scopeID.uuidString.lowercased()
                    && FileEffectMetadata.hex(Data(context.userID.utf8)) == registry.ownerUserHex
                    && context.role == "administrator"
                    && ["synthetic_development","read_only_recovery","rolled_back_recovery"].contains(context.mode), .denied)
        observation = try RecycleOperationObservation(operationID:operationID,value:value,owner:Data(context.userID.utf8))
        self.context = context
        if let snapshot = value.snapshot {
            guard let record, let intentDigest else { throw NASError.denied }
            let row = try ManagedCapacityAllocationView(record,scopeID:scopeID), intent = snapshot.intent
            try intent.validate();try FileEffectMetadata.hash(snapshot.originScopeSHA256)
            try require(snapshot.volumeID == registry.volumeID && snapshot.vaultID == registry.vaultID
                        && Data(intent.libraryID.utf8) == Data(registry.libraryID.utf8)
                        && intent.kind == snapshot.record.kind
                        && intent.sourcePath == row.allocationID && intent.name == row.allocationID && intent.targetParentPath.isEmpty
                        && intentDigest.operationID == operationID
                        && intentDigest.sha256 == snapshot.record.intentSHA256, .denied)
            try snapshot.preEvidence.validate(bytes:row.declaredBytes)
            try require(snapshot.preEvidence.sha256 == row.sha256, .integrity)
            if let post = snapshot.postEvidence {
                try post.validate(bytes:row.declaredBytes)
                try require(post.sha256 == row.sha256 && RecycleDirectory.sameIdentity(snapshot.preEvidence.object,post.object), .integrity)
            }
            // The operation's original originScopeSHA includes its original write grant.
            // It must not be compared with a new observation grant's origin hash.
            allocation = row
        } else {
            try require(record == nil && intentDigest == nil, .denied);allocation = nil
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy:CodingKeys.self)
        try c.encode(managedObservationVersion,forKey:.managedObservationVersion);try c.encode(context,forKey:.context)
        try c.encode(observation,forKey:.observation)
        if let allocation {try c.encode(allocation,forKey:.allocation)}else{try c.encodeNil(forKey:.allocation)}
    }
}
