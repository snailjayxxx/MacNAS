import Foundation
import Darwin

struct RecycleFilePreview {
    let previewID: UUID
    let operationID: UUID
    let entryID: UUID
    let bytes: Int64
    let sha256: String
}
struct RecycleExecutionResult {
    let operationID: UUID
    let entryID: UUID
    let state: String
    let record: FileEffectJournalRecord?
    let error: NASError?
}
enum RecycleCheckpoint: String, CaseIterable {
    case prepared, armed, beforeRename, afterRename, observed, sourceSynced, targetSynced, completed
}
struct RecycleFileObservation {
    let snapshot: FileEffectExecutionSnapshot?
    let classification: String
}

/// Only this coordinator file can construct a phase-specific witness after actual filesystem checks.
/// Holding a grant or a vault permit alone is insufficient to invoke observed/completed/cancelled setters.
final class FileEffectExecutionWitness {
    let permit: FileEffectExecutionPermit
    let snapshot: FileEffectExecutionSnapshot
    let evidence: FileEffectEvidence?
    private let target: FileEffectPhase
    private let validateFilesystem: () throws -> Void
    fileprivate init(permit: FileEffectExecutionPermit, snapshot: FileEffectExecutionSnapshot, target: FileEffectPhase,
                     evidence: FileEffectEvidence? = nil, validate: @escaping () throws -> Void) {
        self.permit = permit; self.snapshot = snapshot; self.target = target; self.evidence = evidence; validateFilesystem = validate
    }
    func check(_ target: FileEffectPhase) throws {
        try require(target == self.target, .denied); try permit.check(permit.action); try validateFilesystem()
    }
}

/// First B slice: synthetic single-file recycle only. No restore, desktop RPC or automatic replay.
final class FixtureRecycleCoordinator {
    let authority: FixtureRecycleAuthority
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private struct Pending {
        let preview: RecycleFilePreview
        let grant: RecycleHostGrant
        let intent: FileEffectIntent
        let source: RecyclePinnedFile
        let target: RecycleDirectory
        let payloadID: UUID
        let evidence: FileEffectEvidence
        let deadline: TimeInterval
    }
    private var pending: [UUID: Pending] = [:]
    init(authority: FixtureRecycleAuthority, now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.authority = authority; self.now = now
    }
    private func journal(_ permit: FileEffectExecutionPermit) throws -> DurableFileEffectJournal {
        try DurableFileEffectJournal(store: authority.store, scope: .init(instanceID: permit.registration.instanceID,
            generation: permit.registration.generation, userID: permit.userID, originScopeSHA256: permit.originScopeSHA256))
    }
    private func snapshot(_ journal: DurableFileEffectJournal, _ operationID: UUID) throws -> FileEffectExecutionSnapshot {
        guard let value = try journal.executionSnapshot(operationID: operationID) else { throw NASError.denied }; return value
    }
    /// Check every registered slot and the small bounded DB catalog, without adopting/deleting unknown objects.
    private func catalog(_ permit: FileEffectExecutionPermit) throws -> Set<UUID> {
        try permit.check(permit.action)
        let r = permit.registration
        let rows = try authority.store.rows("SELECT e.payload_id::text,e.vault_id::text,e.volume_id::text,e.instance_id::text,encode(e.owner_user_utf8,'hex'),o.kind,o.phase,coalesce((o.post_evidence->'object')::text,'null'),e.origin_generation::text FROM macnas.recycle_entries e JOIN macnas.file_effect_operations o USING(entry_id) ORDER BY e.entry_id;")
        try require(rows.count <= 64, .budgetExceeded)
        var used: Set<UUID> = []
        for row in rows {
            guard row.count == 9, let payload = UUID(uuidString: row[0]), let vault = UUID(uuidString: row[1]),
                  let volume = UUID(uuidString: row[2]), let instance = UUID(uuidString: row[3]) else { throw NASError.invalidSchema }
            try require(vault == r.vaultID && volume == r.volumeID && instance == r.instanceID
                        && row[4] == r.ownerUserHex && row[5] == "recycle" && row[8] == String(r.generation)
                        && r.slots.contains { $0.id == payload } && used.insert(payload).inserted, .unsupported)
            let slot = try permit.vault.slot(payload), names = Set(try slot.names(maximum: 1))
            if row[6] == "completed" {
                try require(names == ["payload"], .staleState)
                let expected = try FileEffectMetadata.decode(FileEffectStamp.self, from: Data(row[7].utf8))
                guard let named = try slot.named("payload") else { throw NASError.staleState }
                try named.validate(directory: false); try require(RecycleDirectory.sameStamp(named, expected), .staleState)
            } else {
                // First slice quarantines a vault with any possibly executed unresolved effect.
                try require(["prepared", "cancelled"].contains(row[6]) && names.isEmpty, .unsupported)
            }
        }
        for registered in r.slots where !used.contains(registered.id) {
            try require(try permit.vault.slot(registered.id).names(maximum: 1).isEmpty, .unsupported)
        }
        try permit.check(permit.action); return used
    }
    func preview(path: String, grant: RecycleHostGrant) throws -> RecycleFilePreview {
        try FileEffectMetadata.path(path)
        lock.lock(); defer { lock.unlock() }; pending = pending.filter { $0.value.deadline > now() }
        try require(pending.count < 8, .budgetExceeded)
        return try authority.withLockedVault(grant, action: .recycle) { permit in
            let used = try catalog(permit).union(pending.values.map(\.payloadID))
            guard let slot = permit.registration.slots.first(where: { !used.contains($0.id) }) else { throw NASError.budgetExceeded }
            let target = try permit.vault.slot(slot.id), (parent, name) = try permit.vault.library.parent(of: path)
            let source = try RecyclePinnedFile(source: parent, name: name, validate: { try permit.check(.recycle) })
            try require(try target.names(maximum: 1).isEmpty, .collision)
            let intent = FileEffectIntent(kind: .recycle, libraryID: permit.registration.libraryID, sourcePath: path, targetParentPath: "", name: name)
            try intent.validate()
            let evidence = FileEffectEvidence(object: source.before, sourceParent: RecycleDirectory.stamp(try TransferIO.attributes(parent.fd)),
                targetParent: RecycleDirectory.stamp(try TransferIO.attributes(target.fd)), sha256: source.sha256)
            try evidence.validate(bytes: source.before.bytes)
            let value = RecycleFilePreview(previewID: UUID(), operationID: UUID(), entryID: UUID(), bytes: source.before.bytes, sha256: source.sha256)
            pending[value.previewID] = .init(preview: value, grant: grant, intent: intent, source: source,
                target: target, payloadID: slot.id, evidence: evidence, deadline: now() + 30)
            return value
        }
    }
    private func before(_ p: Pending, _ permit: FileEffectExecutionPermit) throws {
        try require(now() < p.deadline, .expired)
        try p.source.validateBefore { try permit.check(.recycle) }; try p.target.validate(privateMode: true)
        try require(try p.target.names(maximum: 1).isEmpty, .collision)
        try require(RecycleDirectory.sameIdentity(p.evidence.targetParent, p.target.identity)
                    && RecycleDirectory.sameIdentity(p.evidence.sourceParent, p.source.source.identity), .staleState)
    }
    private func post(_ p: Pending, _ permit: FileEffectExecutionPermit, expected: FileEffectEvidence? = nil) throws -> FileEffectEvidence {
        try permit.check(.recycle); try p.source.source.validate(); try p.target.validate(privateMode: true)
        try require(Set(try p.target.names(maximum: 1)) == ["payload"], .unsupported)
        try require(try p.source.source.named(p.source.name) == nil, .staleState)
        guard let named = try p.target.named("payload") else { throw NASError.staleState }
        let current = RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))
        try current.validate(directory: false)
        try require(RecycleDirectory.sameStamp(named, current)
                    && RecycleDirectory.sameStamp(p.source.before, current, allowingRenameCTime: true), .staleState)
        if let expected { try require(RecycleDirectory.sameStamp(expected.object, current), .staleState) }
        let digest = try RecyclePinnedFile.digest(p.source.file, bytes: current.bytes, validate: { try permit.check(.recycle) })
        try require(digest == p.source.sha256 && RecycleDirectory.sameStamp(current, RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))), .integrity)
        try require(try p.source.source.named(p.source.name) == nil, .staleState)
        guard let afterHash = try p.target.named("payload") else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(current, afterHash) && Set(try p.target.names(maximum: 1)) == ["payload"], .staleState)
        let evidence = FileEffectEvidence(object: current,
            sourceParent: RecycleDirectory.stamp(try TransferIO.attributes(p.source.source.fd)),
            targetParent: RecycleDirectory.stamp(try TransferIO.attributes(p.target.fd)), sha256: digest)
        try evidence.validate(bytes: current.bytes); try permit.check(.recycle); return evidence
    }
    private func postStillMatches(_ p: Pending, _ permit: FileEffectExecutionPermit, _ evidence: FileEffectEvidence) throws {
        try permit.check(.recycle); try p.source.source.validate(); try p.target.validate(privateMode: true)
        try require(try p.source.source.named(p.source.name) == nil && Set(p.target.names(maximum: 1)) == ["payload"], .staleState)
        guard let named = try p.target.named("payload") else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(named, evidence.object)
                    && RecycleDirectory.sameStamp(evidence.object, RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))), .staleState)
    }
    func commit(previewID: UUID, grant: RecycleHostGrant, confirmed: Bool, key: Data,
                checkpoint: (RecycleCheckpoint) throws -> Void = { _ in }) throws -> RecycleExecutionResult {
        try require(confirmed, .denied); try FileEffectMetadata.subject(key)
        lock.lock(); defer { lock.unlock() }
        try authority.validate(grant, action: .recycle)
        guard let plan = pending[previewID] else { throw NASError.replay }
        try require(plan.grant == grant, .denied); pending.removeValue(forKey: previewID)
        return try authority.withLockedVault(grant, action: .recycle) { permit in
            let journal = try self.journal(permit)
            try before(plan, permit); let used = try catalog(permit)
            try require(!used.contains(plan.payloadID), .staleState)
            // Data fsync precedes the database arm and the one rename attempt.
            try require(fsync(plan.source.file) == 0, .unsafeFile); try before(plan, permit)
            var current: FileEffectJournalRecord?, renameAttempted = false
            do {
                current = try journal.prepareRecycle(key: key, intent: plan.intent, volumeID: permit.registration.volumeID,
                    vaultID: permit.registration.vaultID, byteCount: plan.preview.bytes, evidence: plan.evidence,
                    operationID: plan.preview.operationID, entryID: plan.preview.entryID, payloadID: plan.payloadID, executorPermit: permit)
                try require(current?.operationID == plan.preview.operationID && current?.entryID == plan.preview.entryID, .replay)
                var saved = try snapshot(journal, plan.preview.operationID)
                try require(saved.record.phase == .prepared && saved.payloadID == plan.payloadID, .staleState)
                try checkpoint(.prepared); try before(plan, permit)
                current = try journal.armForExecutor(permit, snapshot: saved)
                saved = try snapshot(journal, plan.preview.operationID)
                try require(saved.record == current && saved.record.phase == .armed, .staleState)
                try checkpoint(.armed); try before(plan, permit)
                // The hook models the unavoidable gap after the last check, including SIGKILL/revocation.
                try checkpoint(.beforeRename)
                renameAttempted = true
                let renamed = renameatx_np(plan.source.source.fd, plan.source.name, plan.target.fd, "payload", UInt32(RENAME_EXCL))
                if renamed != 0 {
                    if errno == EEXIST || errno == ENOTEMPTY { throw NASError.collision }
                    if errno == EXDEV || errno == ENOTSUP { throw NASError.unsupported }
                    throw NASError.unsafeFile
                }
                try checkpoint(.afterRename)
                let observed = try post(plan, permit)
                let observedWitness = FileEffectExecutionWitness(permit: permit, snapshot: saved, target: .observed, evidence: observed,
                    validate: { try self.postStillMatches(plan, permit, observed) })
                current = try journal.observedForExecutor(observedWitness)
                saved = try snapshot(journal, plan.preview.operationID)
                try require(saved.record == current && saved.record.phase == .observed, .staleState)
                try checkpoint(.observed); _ = try post(plan, permit, expected: observed)
                try plan.source.source.synchronize(); try checkpoint(.sourceSynced); _ = try post(plan, permit, expected: observed)
                try plan.target.synchronize(); try checkpoint(.targetSynced); _ = try post(plan, permit, expected: observed)
                let completedWitness = FileEffectExecutionWitness(permit: permit, snapshot: saved, target: .completed,
                    validate: { try self.postStillMatches(plan, permit, observed) })
                current = try journal.completedForExecutor(completedWitness)
                try checkpoint(.completed)
                let final = try snapshot(journal, plan.preview.operationID)
                try require(final.record.phase == .completed, .staleState)
                return .init(operationID: plan.preview.operationID, entryID: plan.preview.entryID, state: "completed", record: final.record, error: nil)
            } catch {
                let failure = error as? NASError ?? .unsafeFile
                var confirmedAbsent = false
                do {
                    if let saved = try journal.executionSnapshot(operationID: plan.preview.operationID) {
                        current = saved.record
                        if [.armed, .observed, .uncertain].contains(saved.record.phase) {
                            current = (try? journal.uncertainForExecutor(permit, snapshot: saved, error: failure)) ?? saved.record
                        }
                    } else { current = nil; confirmedAbsent = true }
                } catch {
                    if current?.operationID != plan.preview.operationID { current = nil }
                }
                let state = current?.phase == .completed ? "completed" : current?.phase == .prepared ? "prepared"
                    : confirmedAbsent && !renameAttempted ? "failed" : "uncertain"
                return .init(operationID: plan.preview.operationID, entryID: plan.preview.entryID, state: state, record: current, error: failure)
            }
        }
    }
    private func classify(_ value: FileEffectExecutionSnapshot, _ permit: FileEffectExecutionPermit) throws -> (String, RecycleDirectory, RecycleDirectory) {
        try permit.check(permit.action)
        try require(value.vaultID == permit.registration.vaultID && value.volumeID == permit.registration.volumeID
                    && Data(value.intent.libraryID.utf8) == Data(permit.registration.libraryID.utf8) && value.record.kind == .recycle, .denied)
        let (source, name) = try permit.vault.library.parent(of: value.intent.sourcePath)
        let target = try permit.vault.slot(value.payloadID)
        try require(Set(try target.names(maximum: 1)).isSubset(of: ["payload"]), .unsupported)
        try require(RecycleDirectory.sameIdentity(source.identity, value.preEvidence.sourceParent)
                    && RecycleDirectory.sameIdentity(target.identity, value.preEvidence.targetParent), .staleState)
        let sourceName = try source.named(name), targetName = try target.named("payload")
        if sourceName != nil && targetName == nil {
            let file = try RecyclePinnedFile(source: source, name: name, validate: { try permit.check(permit.action) })
            let matches = RecycleDirectory.sameStamp(file.before, value.preEvidence.object) && file.sha256 == value.preEvidence.sha256
            let classification = value.record.phase == .completed ? "changed"
                : matches ? ([FileEffectPhase.prepared, .cancelled].contains(value.record.phase) ? "notObserved" : "sourceOnly") : "ambiguous"
            return (classification, source, target)
        }
        if sourceName == nil && targetName != nil {
            let file = try RecyclePinnedFile(source: target, name: "payload", validate: { try permit.check(permit.action) })
            if let post = value.postEvidence {
                let matches = RecycleDirectory.sameStamp(file.before, post.object) && file.sha256 == post.sha256
                return (matches ? "matchedPost" : "ambiguous", source, target)
            }
            let candidate = RecycleDirectory.sameStamp(file.before, value.preEvidence.object, allowingRenameCTime: true)
                && file.sha256 == value.preEvidence.sha256
            return (candidate ? "candidateMoved" : "ambiguous", source, target)
        }
        return ("ambiguous", source, target)
    }
    func observe(operationID: UUID, grant: RecycleHostGrant) throws -> RecycleFileObservation {
        try authority.withLockedVault(grant, action: .observe) { permit in
            let journal = try self.journal(permit)
            guard let value = try journal.executionSnapshot(operationID: operationID) else { return .init(snapshot: nil, classification: "notVisible") }
            do { return .init(snapshot: value, classification: try classify(value, permit).0) }
            catch {
                try permit.check(.observe)
                return .init(snapshot: value, classification: "ambiguous")
            }
        }
    }
    func settle(operationID: UUID, grant: RecycleHostGrant) throws -> FileEffectJournalRecord {
        try authority.withLockedVault(grant, action: .settle) { permit in
            let journal = try self.journal(permit), value = try snapshot(journal, operationID)
            if value.record.phase == .completed { return value.record }
            try require([FileEffectPhase.observed, .uncertain].contains(value.record.phase) && value.postEvidence != nil, .staleState)
            let (classification, source, target) = try classify(value, permit)
            try require(classification == "matchedPost", .staleState)
            try source.synchronize(); try require(try classify(value, permit).0 == "matchedPost", .staleState)
            try target.synchronize(); try require(try classify(value, permit).0 == "matchedPost", .staleState)
            let witness = FileEffectExecutionWitness(permit: permit, snapshot: value, target: .completed,
                validate: { try require(try self.classify(value, permit).0 == "matchedPost", .staleState) })
            return try journal.completedForExecutor(witness)
        }
    }
    func cancelPrepared(operationID: UUID, grant: RecycleHostGrant) throws -> FileEffectJournalRecord {
        try authority.withLockedVault(grant, action: .cancelPrepared) { permit in
            let journal = try self.journal(permit), value = try snapshot(journal, operationID)
            try require(value.record.phase == .prepared, .staleState)
            try require(try classify(value, permit).0 == "notObserved", .staleState)
            let witness = FileEffectExecutionWitness(permit: permit, snapshot: value, target: .cancelled,
                validate: { try require(try self.classify(value, permit).0 == "notObserved", .staleState) })
            return try journal.cancelledForExecutor(witness)
        }
    }
}
