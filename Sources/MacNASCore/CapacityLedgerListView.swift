import Foundation

/// A projection of one already-bound complete ledger read. This constructs no
/// host approval/source marker and does not observe or modify any filesystem.
public struct CapacityLedgerItemView: Encodable, Sendable {
    public let allocationID: String
    public let origin: String
    public let intentSHA256: String
    public let declaredBytes: Int64
    public let state: String
    public let revision: Int64
    public let sha256: String?
    enum CodingKeys: String, CodingKey { case allocationID, origin, intentSHA256, declaredBytes, state, revision, sha256 }
    fileprivate init(_ record: CapacityAllocation) {
        allocationID = record.allocationID.uuidString.lowercased(); origin = record.origin.rawValue
        intentSHA256 = record.intentSHA256; declaredBytes = record.declaredBytes
        state = record.state.rawValue; revision = record.revision; sha256 = record.sha256
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(allocationID, forKey: .allocationID); try c.encode(origin, forKey: .origin)
        try c.encode(intentSHA256, forKey: .intentSHA256); try c.encode(declaredBytes, forKey: .declaredBytes)
        try c.encode(state, forKey: .state); try c.encode(revision, forKey: .revision)
        if let sha256 { try c.encode(sha256, forKey: .sha256) } else { try c.encodeNil(forKey: .sha256) }
    }
}
public struct CapacityLedgerTotalsView: Encodable, Sendable {
    public let reservedBytes: Int64
    public let unresolvedBytes: Int64
    public let ownedBytes: Int64
    public let allocatedBytes: Int64
    public let historyCount: Int
    public let unresolvedCount: Int
}
public struct CapacityLedgerListView: Encodable, Sendable {
    public let listVersion = 1
    public let scopeID: String
    public let ownerUserHex: String
    public let sourceID: String
    public let evidence = "ledgerOnly"
    public let limitBytes = DurableCapacityLedger.byteLimit
    public let totals: CapacityLedgerTotalsView
    public let items: [CapacityLedgerItemView]

    /// Caller must obtain records from one bounded, scope-filtered, consistent read,
    /// not concatenate pages or independently query totals. No source is inferred.
    init(scopeID: UUID, ownerUserID: Data, sourceID: String, records: [CapacityAllocation]) throws {
        try FileEffectMetadata.subject(ownerUserID); try FileEffectMetadata.hash(sourceID)
        try require(records.count <= 64, .budgetExceeded)
        var previous: String?, rows: [CapacityLedgerItemView] = []
        var reserved: Int64 = 0, unresolved: Int64 = 0, owned: Int64 = 0
        var active = 0, unresolvedCount = 0
        for record in records {
            try require(record.scopeID == scopeID, .denied)
            try require(record.origin != .initial
                        && (0...DurableCapacityLedger.fileLimit).contains(record.declaredBytes), .invalidSchema)
            try FileEffectMetadata.hash(record.intentSHA256)
            let expectedRevision: Int64
            switch record.state {
            case .reserved: expectedRevision = 1; reserved += record.declaredBytes; active += 1
            case .armed: expectedRevision = 2; unresolved += record.declaredBytes; active += 1; unresolvedCount += 1
            case .owned: expectedRevision = 3; owned += record.declaredBytes
            case .cancelled: expectedRevision = 2
            }
            try require(record.revision == expectedRevision, .invalidSchema)
            if record.state == .owned {
                guard let sha256 = record.sha256 else { throw NASError.invalidSchema }
                try FileEffectMetadata.hash(sha256)
            } else { try require(record.sha256 == nil, .invalidSchema) }
            let row = CapacityLedgerItemView(record)
            if let previous { try require(previous < row.allocationID, .invalidSchema) }
            previous = row.allocationID; rows.append(row)
        }
        let allocated = reserved + unresolved + owned
        try require(active <= 8 && allocated <= DurableCapacityLedger.byteLimit, .budgetExceeded)
        self.scopeID = scopeID.uuidString.lowercased(); ownerUserHex = FileEffectMetadata.hex(ownerUserID)
        self.sourceID = sourceID; items = rows
        totals = .init(reservedBytes: reserved, unresolvedBytes: unresolved, ownedBytes: owned,
                       allocatedBytes: allocated, historyCount: records.count, unresolvedCount: unresolvedCount)
    }
}
