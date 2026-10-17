import Foundation
import Darwin

enum PhysicalCapacityCheckpoint: String, CaseIterable {
    case reserved, armed, stagingCreated, staged, beforePublish, afterPublish, synced, owned
}
struct PhysicalCapacityInventory {
    let declared: CapacityTotals
    let clean: Bool
    let visible: Set<UUID>
    let retained: Set<UUID>
}
struct PhysicalCapacityResult {
    let allocationID: UUID
    let state: String
    let record: CapacityAllocation?
    let error: NASError?
}

/// Created only here after the actual fresh publication or positive no-effect check.
/// A prior armed ID and an identical-looking file cannot construct a new witness.
final class PhysicalCapacityWitness {
    let permit: PhysicalCapacityPermit
    let record: CapacityAllocation
    let target: CapacityAllocationState
    let sha256: String?
    let baseline: FileEffectStamp?
    private let validateFilesystem: () throws -> Void
    fileprivate init(permit: PhysicalCapacityPermit, record: CapacityAllocation, target: CapacityAllocationState,
                     sha256: String? = nil, baseline: FileEffectStamp? = nil, validate: @escaping () throws -> Void) {
        self.permit = permit; self.record = record; self.target = target; self.sha256 = sha256; self.baseline = baseline
        validateFilesystem = validate
    }
    func check() throws { try permit.check(write: true); try validateFilesystem() }
}

enum PhysicalCapacityFiles {
    static func receive(_ data: Data, permit: PhysicalCapacityPermit,
                        checkpoint: (PhysicalCapacityCheckpoint) throws -> Void) throws -> PhysicalCapacityResult {
        guard let declaration = permit.grant.declaration else { throw NASError.denied }
        try require(permit.grant.purpose == .receive && declaration.origin == .upload, .denied)
        try require(data.count == declaration.bytes && TransferEncoding.digest(data) == declaration.sha256, .integrity)
        return try publish(permit, checkpoint: checkpoint, sourceCheck: {}) { offset, count in
            data.subdata(in: Int(offset)..<(Int(offset)+count))
        }
    }
    static func copy(permit: PhysicalCapacityPermit,
                     checkpoint: (PhysicalCapacityCheckpoint) throws -> Void) throws -> PhysicalCapacityResult {
        guard let declaration = permit.grant.declaration, let sourceID = declaration.sourceAllocationID,
              let sourceRecord = try permit.ledger().allocation(sourceID) else { throw NASError.denied }
        try require(permit.grant.purpose == .copy && permit.grant.allocationID == sourceID, .denied)
        let source = try visibleFile(permit, record: sourceRecord)
        try require(source.before.bytes == declaration.bytes && source.sha256 == declaration.sha256, .staleState)
        let sourceCheck = { try source.validateBefore { try permit.check(write: true) } }
        return try publish(permit, checkpoint: checkpoint, sourceCheck: sourceCheck) { offset, count in
            var block = Data(count: count)
            try block.withUnsafeMutableBytes { buffer in
                var loaded = 0
                while loaded < count {
                    let n = pread(source.file, buffer.baseAddress!.advanced(by: loaded), count-loaded, off_t(offset)+off_t(loaded))
                    if n < 0 && errno == EINTR { continue }
                    try require(n > 0 && n <= count-loaded, .unsafeFile); loaded += n
                }
            }
            return block
        }
    }
    private static func publish(_ permit: PhysicalCapacityPermit,
                                checkpoint: (PhysicalCapacityCheckpoint) throws -> Void,
                                sourceCheck: () throws -> Void,
                                read: (Int64, Int) throws -> Data) throws -> PhysicalCapacityResult {
        guard let declaration = permit.grant.declaration else { throw NASError.denied }
        let ledger = try permit.ledger()
        var record = try ledger.reservePhysical(declaration)
        if [.owned,.cancelled].contains(record.state) {
            return .init(allocationID: record.allocationID, state: record.state.rawValue, record: record, error: nil)
        }
        try require(record.state == .reserved, .staleState)
        let name = record.allocationID.uuidString.lowercased()
        var fd: Int32 = -1
        defer { if fd >= 0 { close(fd) } } // Preserve all partial/staged bytes after failure.
        do {
            try checkpoint(.reserved); try permit.check(write: true); try sourceCheck()
            try require(try permit.staging.named(name) == nil && permit.vault.library.named(name) == nil, .collision)
            record = try ledger.armPhysical(record)
            try checkpoint(.armed); try permit.check(write: true); try sourceCheck()
            try require(try permit.staging.named(name) == nil && permit.vault.library.named(name) == nil, .collision)
            fd = openat(permit.staging.fd, name, O_RDWR | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC | O_NONBLOCK, 0o600)
            guard fd >= 0 else { throw NASError.collision }
            try require(fchmod(fd, 0o600) == 0, .unsafeFile)
            let created = RecycleDirectory.stamp(try TransferIO.attributes(fd))
            try created.validate(directory: false)
            try require(created.bytes == 0 && created.uid == Int64(getuid())
                        && created.mode & 0o7777 == 0o600 && created.device == permit.registry.device, .unsafeFile)
            try checkpoint(.stagingCreated)
            var offset: Int64 = 0
            while offset < declaration.bytes {
                try permit.check(write: true); try sourceCheck()
                let block = try read(offset, Int(min(32768, declaration.bytes-offset)))
                try require(block.count == min(32768, declaration.bytes-offset), .integrity)
                try block.withUnsafeBytes { buffer in
                    var written = 0
                    while written < buffer.count {
                        let n = pwrite(fd, buffer.baseAddress!.advanced(by: written), buffer.count-written, off_t(offset)+off_t(written))
                        if n < 0 && errno == EINTR { continue }
                        try require(n > 0 && n <= buffer.count-written, .unsafeFile); written += n
                    }
                }
                offset += Int64(block.count)
            }
            try permit.check(write: true); try sourceCheck()
            try require(fsync(fd) == 0, .unsafeFile)
            let staged = try RecyclePinnedFile(source: permit.staging, name: name, validate: { try permit.check(write: true) })
            try require(RecycleDirectory.sameIdentity(created, staged.before)
                        && staged.before.bytes == declaration.bytes && staged.sha256 == declaration.sha256
                        && RecycleDirectory.sameStamp(staged.before, RecycleDirectory.stamp(try TransferIO.attributes(fd))), .integrity)
            try checkpoint(.staged); try checkpoint(.beforePublish)
            try permit.check(write: true); try sourceCheck()
            try staged.validateBefore { try permit.check(write: true) }
            try require(try permit.vault.library.named(name) == nil, .collision)
            // This is the only publication attempt. Never retry/overwrite on any error.
            try require(renameatx_np(permit.staging.fd, name, permit.vault.library.fd, name, UInt32(RENAME_EXCL)) == 0, .unsafeFile)
            try checkpoint(.afterPublish)
            let published = try verifyPublished(permit, name: name, staged: staged, expected: nil)
            try permit.staging.synchronize(); try permit.vault.library.synchronize()
            try checkpoint(.synced); try sourceCheck()
            _ = try verifyPublished(permit, name: name, staged: staged, expected: published)
            let witness = PhysicalCapacityWitness(permit: permit, record: record, target: .owned,
                sha256: staged.sha256, baseline: published, validate: {
                    _ = try verifyPublished(permit, name: name, staged: staged, expected: published)
                })
            record = try ledger.finishPhysical(witness)
            try checkpoint(.owned); try permit.check(write: true)
            return .init(allocationID: record.allocationID, state: "owned", record: record, error: nil)
        } catch {
            // A post-COMMIT context failure can leave durable owned state. Report the
            // original ID and error without retrying an effect or promising rollback.
            let actual = (try? ledger.allocation(record.allocationID)) ?? record
            return .init(allocationID: record.allocationID, state: actual.state.rawValue, record: actual,
                         error: (error as? NASError) ?? .unsafeFile)
        }
    }
    private static func verifyPublished(_ permit: PhysicalCapacityPermit, name: String,
                                        staged: RecyclePinnedFile, expected: FileEffectStamp?) throws -> FileEffectStamp {
        try permit.check(write: true)
        try require(try permit.staging.named(name) == nil, .staleState)
        guard let named = try permit.vault.library.named(name) else { throw NASError.staleState }
        let current = RecycleDirectory.stamp(try TransferIO.attributes(staged.file))
        try current.validate(directory: false)
        try require(RecycleDirectory.sameStamp(named, current)
                    && RecycleDirectory.sameStamp(staged.before, current, allowingRenameCTime: true), .staleState)
        if let expected { try require(RecycleDirectory.sameStamp(expected, current), .staleState) }
        let sha = try RecyclePinnedFile.digest(staged.file, bytes: current.bytes, validate: { try permit.check(write: true) })
        try require(sha == staged.sha256 && RecycleDirectory.sameStamp(current,
            RecycleDirectory.stamp(try TransferIO.attributes(staged.file))), .integrity)
        guard let after = try permit.vault.library.named(name) else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(current, after) && permit.staging.named(name) == nil, .staleState)
        return current
    }
    static func cancelUnarmed(permit: PhysicalCapacityPermit) throws -> CapacityAllocation {
        guard let id = permit.grant.allocationID else { throw NASError.denied }
        try require(permit.grant.purpose == .cancelIncoming, .denied)
        let ledger = try permit.ledger()
        guard let record = try ledger.allocation(id), record.state == .reserved else { throw NASError.staleState }
        let validate = {
            try permit.check(write: true)
            try require(try permit.staging.named(id.uuidString.lowercased()) == nil
                        && permit.vault.library.named(id.uuidString.lowercased()) == nil, .staleState)
        }
        try validate()
        return try ledger.finishPhysical(PhysicalCapacityWitness(permit: permit, record: record, target: .cancelled, validate: validate))
    }
    private struct Ownership: Codable { let baseline: FileEffectStamp; let sha256: String }
    private static func verifyOwnership(_ file: RecyclePinnedFile, permit: PhysicalCapacityPermit,
                                        record: CapacityAllocation) throws {
        let rows = try permit.store.rows("""
        SELECT jsonb_build_object('baseline',o.baseline_stamp,'sha256',o.sha256)::text
        FROM macnas.capacity_file_ownership o JOIN macnas.capacity_allocations a USING(allocation_id)
        WHERE a.allocation_id=\(FileEffectMetadata.uuidSQL(record.allocationID))
          AND a.scope_id=\(FileEffectMetadata.uuidSQL(permit.registration.scopeID)) AND a.state='owned'
          AND o.baseline_stamp IS NOT NULL AND o.sha256=a.sha256 AND o.published_at=a.owned_at;
        """)
        try require(rows.count == 1 && rows[0].count == 1, .integrity)
        let proof = try FileEffectMetadata.decode(Ownership.self, from: Data(rows[0][0].utf8))
        try proof.baseline.validate(directory: false)
        try require(file.before.bytes == record.declaredBytes && file.sha256 == record.sha256
                    && proof.sha256 == file.sha256
                    && RecycleDirectory.sameStamp(proof.baseline, file.before, allowingRenameCTime: true), .staleState)
        try file.validateBefore { try permit.check() }
    }
    static func visibleFile(_ permit: PhysicalCapacityPermit, record: CapacityAllocation) throws -> RecyclePinnedFile {
        try require(permit.grant.purpose != .ledgerRead, .denied)
        try permit.check()
        try require(record.scopeID == permit.registration.scopeID && record.state == .owned, .denied)
        let file = try RecyclePinnedFile(source: permit.vault.library, name: record.allocationID.uuidString.lowercased(),
            validate: { try permit.check() })
        try verifyOwnership(file, permit: permit, record: record)
        return file
    }
    static func audit(_ permit: PhysicalCapacityPermit, requireClean: Bool) throws -> PhysicalCapacityInventory {
        try require(permit.grant.purpose != .ledgerRead, .denied)
        try permit.check(); try permit.vault.validate()
        let ledger = try permit.ledger(), declared = try ledger.totals(), records = try ledger.allocations()
        let byID = Dictionary(uniqueKeysWithValues: records.map { ($0.allocationID,$0) })
        var clean = declared.unresolvedCount == 0
        let rows = try permit.store.rows("""
        SELECT entry_id::text,convert_from(original_path_utf8,'UTF8'),payload_id::text,byte_count::text,sha256,
          charge_state,coalesce(active_operation_id::text,'none'),instance_id::text,origin_generation::text,
          encode(owner_user_utf8,'hex'),encode(library_id_utf8,'hex'),volume_id::text,vault_id::text
        FROM macnas.recycle_entries ORDER BY entry_id LIMIT 65;
        """)
        try require(rows.count <= 64, .budgetExceeded)
        struct Entry { let allocation: UUID; let payload: UUID; let charge: String; let active: Bool }
        var entries: [Entry] = []
        for row in rows {
            guard row.count == 13, let allocation = UUID(uuidString: row[1]),
                  allocation.uuidString.lowercased() == row[1], let payload = UUID(uuidString: row[2]),
                  let bytes = Int64(row[3]), let record = byID[allocation],
                  record.state == .owned, record.declaredBytes == bytes, record.sha256 == row[4],
                  row[7] == permit.registry.instanceID.uuidString.lowercased(),
                  row[8] == String(permit.registry.generation), row[9] == FileEffectMetadata.hex(permit.userID),
                  row[10] == FileEffectMetadata.hex(Data(permit.registry.libraryID.utf8)),
                  row[11] == permit.registry.volumeID.uuidString.lowercased(),
                  row[12] == permit.registry.vaultID.uuidString.lowercased() else {
                throw NASError.integrity
            }
            try require(["reserved","retained","released"].contains(row[5]), .invalidSchema)
            entries.append(Entry(allocation: allocation,payload: payload,charge: row[5],active: row[6] != "none"))
            if row[5] == "reserved" || row[6] != "none" { clean = false }
        }
        let libraryNames = Set(try permit.vault.library.names(maximum: 64))
        let stagingNames = Set(try permit.staging.names(maximum: 8))
        let knownNames = Set(records.map { $0.allocationID.uuidString.lowercased() })
        if !libraryNames.isSubset(of: knownNames) || !stagingNames.isSubset(of: knownNames) { clean = false }
        var visible: Set<UUID> = [], retained: Set<UUID> = []
        for record in records {
            try permit.check()
            let name = record.allocationID.uuidString.lowercased()
            let chargedEntries = entries.filter { $0.allocation == record.allocationID && $0.charge != "released" }
            if record.state != .owned {
                if record.state == .armed { clean = false }
                else if libraryNames.contains(name) || stagingNames.contains(name) { clean = false }
                continue
            }
            if record.origin == .initial || stagingNames.contains(name) { clean = false }
            if chargedEntries.isEmpty {
                if !libraryNames.contains(name) { clean = false; continue }
                do { _ = try visibleFile(permit, record: record); visible.insert(record.allocationID) }
                catch { try permit.check(); clean = false }
            } else if chargedEntries.count == 1, chargedEntries[0].charge == "retained", !chargedEntries[0].active {
                if libraryNames.contains(name) { clean = false }
                do {
                    let slot = try permit.vault.slot(chargedEntries[0].payload)
                    let file = try RecyclePinnedFile(source: slot, name: "payload", validate: { try permit.check() })
                    try verifyOwnership(file, permit: permit, record: record)
                    retained.insert(record.allocationID)
                } catch { try permit.check(); clean = false }
            } else { clean = false }
        }
        for slot in permit.registry.slots {
            try permit.check()
            let directory = try permit.vault.slot(slot.id), names = Set(try directory.names(maximum: 2))
            let linked = entries.filter { $0.payload == slot.id }
            if linked.isEmpty || linked.allSatisfy({ $0.charge == "released" }) {
                if !names.isEmpty { clean = false }
            } else if !names.isSubset(of: ["payload"]) { clean = false }
        }
        try permit.check()
        if requireClean { try require(clean, .staleState) }
        return .init(declared: declared,clean: clean,visible: visible,retained: retained)
    }
}
