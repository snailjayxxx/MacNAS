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

/// Synthetic same-device recycle/restore with one move pipeline. No desktop RPC or automatic replay.
final class FixtureRecycleCoordinator {
    let authority: FixtureRecycleAuthority
    private let lock = NSLock()
    private let now: () -> TimeInterval
    private struct Pending {
        let preview: RecycleFilePreview
        let grant: RecycleHostGrant
        let destinationGrant: RecycleHostGrant?
        let expectedEntryRevision: Int64?
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
            generation: permit.registration.generation, userID: permit.userID, originScopeSHA256: permit.originScopeSHA256), physicalAccess: authority.physicalAccess)
    }
    private func snapshot(_ journal: DurableFileEffectJournal, _ operationID: UUID) throws -> FileEffectExecutionSnapshot {
        guard let value = try journal.executionSnapshot(operationID: operationID) else { throw NASError.denied }; return value
    }
    /// Check every registered slot and the small bounded DB catalog, without adopting/deleting unknown objects.
    private func catalog(_ permit: FileEffectExecutionPermit) throws -> Set<UUID> {
        try permit.check(permit.action)
        let r = permit.registration
        let rows = try authority.store.rows("""
        SELECT e.payload_id::text,e.vault_id::text,e.volume_id::text,e.instance_id::text,encode(e.owner_user_utf8,'hex'),e.origin_generation::text,e.charge_state,
          coalesce(a.kind,''),coalesce(a.phase,''),coalesce(r.phase,''),coalesce((r.post_evidence->'object')::text,'null'),
          (SELECT count(*)::text FROM macnas.file_effect_operations c WHERE c.entry_id=e.entry_id AND c.kind='recycle'),
          (SELECT count(*)::text FROM macnas.file_effect_operations c WHERE c.entry_id=e.entry_id AND c.kind='restore' AND c.phase='completed'),coalesce(e.active_operation_id::text,'none')
        FROM macnas.recycle_entries e LEFT JOIN macnas.file_effect_operations r ON r.entry_id=e.entry_id AND r.kind='recycle'
          LEFT JOIN macnas.file_effect_operations a ON a.operation_id=e.active_operation_id ORDER BY e.entry_id;
        """)
        try require(rows.count <= 64, .budgetExceeded)
        var used: Set<UUID> = []
        for row in rows {
            guard row.count == 14, let payload = UUID(uuidString: row[0]), let vault = UUID(uuidString: row[1]),
                  let volume = UUID(uuidString: row[2]), let instance = UUID(uuidString: row[3]) else { throw NASError.invalidSchema }
            try require(vault == r.vaultID && volume == r.volumeID && instance == r.instanceID
                        && row[4] == r.ownerUserHex && row[5] == String(r.generation) && row[11] == "1"
                        && r.slots.contains { $0.id == payload } && used.insert(payload).inserted, .unsupported)
            let slot = try permit.vault.slot(payload), names = Set(try slot.names(maximum: 1))
            if row[6] == "retained" {
                try require(row[9] == "completed" && row[12] == "0"
                            && (row[13] == "none" || (row[7] == "restore" && row[8] == "prepared")), .unsupported)
                try require(names == ["payload"], .staleState)
                let expected = try FileEffectMetadata.decode(FileEffectStamp.self, from: Data(row[10].utf8))
                guard let named = try slot.named("payload") else { throw NASError.staleState }
                try named.validate(directory: false); try require(RecycleDirectory.sameStamp(named, expected), .staleState)
            } else if row[6] == "reserved" {
                try require(row[7] == "recycle" && row[8] == "prepared" && row[9] == "prepared" && row[12] == "0" && names.isEmpty, .unsupported)
            } else if row[6] == "released" {
                try require(row[13] == "none" && names.isEmpty
                            && ((row[9] == "cancelled" && row[12] == "0") || (row[9] == "completed" && row[12] == "1")), .unsupported)
            } else { throw NASError.invalidSchema
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
            let boundIntent = FileEffectIntent(kind: .recycle, libraryID: permit.registration.libraryID,
                sourcePath: path, targetParentPath: "", name: (path as NSString).lastPathComponent)
            try authority.physicalAccess?.checkIntent(boundIntent)
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
            pending[value.previewID] = .init(preview: value, grant: grant, destinationGrant: nil, expectedEntryRevision: nil, intent: intent, source: source,
                target: target, payloadID: slot.id, evidence: evidence, deadline: now() + 30)
            return value
        }
    }
    private func directory(_ root: RecycleDirectory, relative: String) throws -> RecycleDirectory {
        try FileEffectMetadata.path(relative, empty: true)
        var current = root
        for part in relative.split(separator: "/") { current = try current.child(String(part)) }
        return current
    }
    private func vacant(_ target: RecycleDirectory, name: String) throws {
        try FixtureFileOperationIntent.component(name)
        let key = name.precomposedStringWithCanonicalMapping.lowercased()
        let names = try target.names(maximum: 1000)
        try require(!names.contains { $0.precomposedStringWithCanonicalMapping.lowercased() == key }, .collision)
    }
    func previewRestore(entryID: UUID, parentPath: String, name: String,
                        grant: RecycleHostGrant, destinationGrant: RecycleHostGrant) throws -> RecycleFilePreview {
        try FileEffectMetadata.path(parentPath, empty: true); try FixtureFileOperationIntent.component(name)
        lock.lock(); defer { lock.unlock() }; pending = pending.filter { $0.value.deadline > now() }
        try require(pending.count < 8, .budgetExceeded)
        return try authority.withLockedVault(grant, action: .restore, destinationGrant: destinationGrant) { permit in
            try require(permit.destinationParentPath == Data(parentPath.utf8), .denied)
            _ = try catalog(permit)
            let journal = try self.journal(permit)
            guard let original = try journal.retainedEntry(entryID: entryID), let originalPost = original.postEvidence else { throw NASError.denied }
            try require(original.vaultID == permit.registration.vaultID && original.volumeID == permit.registration.volumeID
                        && Data(original.intent.libraryID.utf8) == Data(permit.registration.libraryID.utf8), .denied)
            let boundIntent = FileEffectIntent(kind: .restore, libraryID: permit.registration.libraryID,
                sourcePath: original.intent.sourcePath, targetParentPath: parentPath, name: name)
            try authority.physicalAccess?.checkIntent(boundIntent, entryID: entryID)
            let sourceParent = try permit.vault.slot(original.payloadID), target = try directory(permit.vault.library, relative: parentPath)
            guard let approvedTarget = permit.destinationParentStamp else { throw NASError.denied }
            try require(RecycleDirectory.sameIdentity(approvedTarget, target.identity), .staleState)
            try vacant(target, name: name)
            let source = try RecyclePinnedFile(source: sourceParent, name: "payload", validate: { try permit.check(.restore) })
            try require(RecycleDirectory.sameStamp(source.before, originalPost.object) && source.sha256 == originalPost.sha256, .staleState)
            let intent = FileEffectIntent(kind: .restore, libraryID: permit.registration.libraryID, sourcePath: original.intent.sourcePath,
                targetParentPath: parentPath, name: name)
            try intent.validate()
            let evidence = FileEffectEvidence(object: source.before, sourceParent: RecycleDirectory.stamp(try TransferIO.attributes(sourceParent.fd)),
                targetParent: RecycleDirectory.stamp(try TransferIO.attributes(target.fd)), sha256: source.sha256)
            try evidence.validate(bytes: source.before.bytes)
            let value = RecycleFilePreview(previewID: UUID(), operationID: UUID(), entryID: entryID, bytes: source.before.bytes, sha256: source.sha256)
            pending[value.previewID] = .init(preview: value, grant: grant, destinationGrant: destinationGrant,
                expectedEntryRevision: original.record.entryRevision, intent: intent, source: source, target: target,
                payloadID: original.payloadID, evidence: evidence, deadline: now() + 30)
            return value
        }
    }
    private func action(_ p: Pending) -> RecycleHostAction { p.intent.kind == .recycle ? .recycle : .restore }
    private func targetName(_ p: Pending) -> String { p.intent.kind == .recycle ? "payload" : p.intent.name }
    private func targetLayout(_ p: Pending, published: Bool) throws {
        if p.intent.kind == .recycle {
            try require(Set(try p.target.names(maximum: 1)) == (published ? ["payload"] : []), published ? .unsupported : .collision)
        } else if !published { try vacant(p.target, name: p.intent.name) }
    }
    private func before(_ p: Pending, _ permit: FileEffectExecutionPermit) throws {
        try require(now() < p.deadline, .expired)
        try p.source.validateBefore { try permit.check(self.action(p)) }; try p.target.validate(privateMode: p.intent.kind == .recycle)
        try targetLayout(p, published: false)
        try require(RecycleDirectory.sameIdentity(p.evidence.targetParent, p.target.identity)
                    && RecycleDirectory.sameIdentity(p.evidence.sourceParent, p.source.source.identity), .staleState)
    }
    private func post(_ p: Pending, _ permit: FileEffectExecutionPermit, expected: FileEffectEvidence? = nil) throws -> FileEffectEvidence {
        try permit.check(action(p)); try p.source.source.validate(); try p.target.validate(privateMode: p.intent.kind == .recycle)
        try targetLayout(p, published: true)
        try require(try p.source.source.named(p.source.name) == nil, .staleState)
        guard let named = try p.target.named(targetName(p)) else { throw NASError.staleState }
        let current = RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))
        try current.validate(directory: false)
        try require(RecycleDirectory.sameStamp(named, current)
                    && RecycleDirectory.sameStamp(p.source.before, current, allowingRenameCTime: true), .staleState)
        if let expected { try require(RecycleDirectory.sameStamp(expected.object, current), .staleState) }
        let digest = try RecyclePinnedFile.digest(p.source.file, bytes: current.bytes, validate: { try permit.check(self.action(p)) })
        try require(digest == p.source.sha256 && RecycleDirectory.sameStamp(current, RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))), .integrity)
        try require(try p.source.source.named(p.source.name) == nil, .staleState)
        guard let afterHash = try p.target.named(targetName(p)) else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(current, afterHash), .staleState); try targetLayout(p, published: true)
        let evidence = FileEffectEvidence(object: current,
            sourceParent: RecycleDirectory.stamp(try TransferIO.attributes(p.source.source.fd)),
            targetParent: RecycleDirectory.stamp(try TransferIO.attributes(p.target.fd)), sha256: digest)
        try evidence.validate(bytes: current.bytes); try permit.check(action(p)); return evidence
    }
    private func postStillMatches(_ p: Pending, _ permit: FileEffectExecutionPermit, _ evidence: FileEffectEvidence) throws {
        try permit.check(action(p)); try p.source.source.validate(); try p.target.validate(privateMode: p.intent.kind == .recycle)
        try require(try p.source.source.named(p.source.name) == nil, .staleState); try targetLayout(p, published: true)
        guard let named = try p.target.named(targetName(p)) else { throw NASError.staleState }
        try require(RecycleDirectory.sameStamp(named, evidence.object)
                    && RecycleDirectory.sameStamp(evidence.object, RecycleDirectory.stamp(try TransferIO.attributes(p.source.file))), .staleState)
    }
    func commit(previewID: UUID, grant: RecycleHostGrant, confirmed: Bool, key: Data,
                destinationGrant: RecycleHostGrant? = nil,
                checkpoint: (RecycleCheckpoint) throws -> Void = { _ in }) throws -> RecycleExecutionResult {
        try require(confirmed, .denied); try FileEffectMetadata.subject(key)
        lock.lock(); defer { lock.unlock() }
        try require(grant.action == .recycle || grant.action == .restore, .denied)
        try authority.validate(grant, action: grant.action)
        guard let plan = pending[previewID] else { throw NASError.replay }
        try require(plan.grant == grant && plan.destinationGrant == destinationGrant && action(plan) == grant.action, .denied)
        pending.removeValue(forKey: previewID)
        return try authority.withLockedVault(grant, action: action(plan), destinationGrant: destinationGrant) { permit in
            try authority.physicalAccess?.checkIntent(plan.intent, entryID: plan.intent.kind == .restore ? plan.preview.entryID : nil)
            let journal = try self.journal(permit)
            try before(plan, permit); let used = try catalog(permit)
            try require(used.contains(plan.payloadID) == (plan.intent.kind == .restore), .staleState)
            // Data fsync precedes the database arm and the one rename attempt.
            try require(fsync(plan.source.file) == 0, .unsafeFile); try before(plan, permit)
            var current: FileEffectJournalRecord?, renameAttempted = false
            do {
                if plan.intent.kind == .recycle {
                    current = try journal.prepareRecycle(key: key, intent: plan.intent, volumeID: permit.registration.volumeID,
                        vaultID: permit.registration.vaultID, byteCount: plan.preview.bytes, evidence: plan.evidence,
                        operationID: plan.preview.operationID, entryID: plan.preview.entryID, payloadID: plan.payloadID, executorPermit: permit)
                } else {
                    guard let revision = plan.expectedEntryRevision else { throw NASError.integrity }
                    current = try journal.prepareRestore(entryID: plan.preview.entryID, expectedEntryRevision: revision, key: key,
                        intent: plan.intent, evidence: plan.evidence, operationID: plan.preview.operationID, executorPermit: permit)
                }
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
                let renamed = renameatx_np(plan.source.source.fd, plan.source.name, plan.target.fd, targetName(plan), UInt32(RENAME_EXCL))
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
    private func classify(_ value: FileEffectExecutionSnapshot, _ permit: FileEffectExecutionPermit,
                          capture: ((RecyclePinnedFile, RecycleDirectory, RecycleDirectory, String, String, Bool) -> Void)? = nil) throws -> (String, RecycleDirectory, RecycleDirectory) {
        try permit.check(permit.action)
        try require(value.vaultID == permit.registration.vaultID && value.volumeID == permit.registration.volumeID
                    && Data(value.intent.libraryID.utf8) == Data(permit.registration.libraryID.utf8), .denied)
        let source: RecycleDirectory, target: RecycleDirectory, name: String, destinationName: String
        if value.record.kind == .recycle {
            (source, name) = try permit.vault.library.parent(of: value.intent.sourcePath)
            target = try permit.vault.slot(value.payloadID); destinationName = "payload"
            try require(Set(try target.names(maximum: 1)).isSubset(of: ["payload"]), .unsupported)
        } else {
            if permit.action == .settle { try require(permit.destinationParentPath == Data(value.intent.targetParentPath.utf8), .denied) }
            source = try permit.vault.slot(value.payloadID); name = "payload"
            try require(Set(try source.names(maximum: 1)).isSubset(of: ["payload"]), .unsupported)
            target = try directory(permit.vault.library, relative: value.intent.targetParentPath); destinationName = value.intent.name
        }
        try require(RecycleDirectory.sameIdentity(source.identity, value.preEvidence.sourceParent)
                    && RecycleDirectory.sameIdentity(target.identity, value.preEvidence.targetParent), .staleState)
        let sourceName = try source.named(name), targetName = try target.named(destinationName)
        if sourceName != nil && targetName == nil {
            let file = try RecyclePinnedFile(source: source, name: name, validate: { try permit.check(permit.action) })
            try require(try target.named(destinationName) == nil, .staleState)
            try file.validateBefore { try permit.check(permit.action) }
            let matches = RecycleDirectory.sameStamp(file.before, value.preEvidence.object) && file.sha256 == value.preEvidence.sha256
            let classification = value.record.phase == .completed ? "changed"
                : matches ? ([FileEffectPhase.prepared, .cancelled].contains(value.record.phase) ? "notObserved" : "sourceOnly") : "ambiguous"
            capture?(file, source, target, name, destinationName, true)
            return (classification, source, target)
        }
        if sourceName == nil && targetName != nil {
            let file = try RecyclePinnedFile(source: target, name: destinationName, validate: { try permit.check(permit.action) })
            try require(try source.named(name) == nil, .staleState)
            try file.validateBefore { try permit.check(permit.action) }
            capture?(file, source, target, name, destinationName, false)
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
    /// A managed read may project and encode while the same actual locks are held.
    /// Rendering failures propagate and cannot be reclassified as ambiguous data.
    func withObservation<T>(operationID: UUID, grant: RecycleHostGrant,
                            _ render: (RecycleFileObservation, FileEffectExecutionPermit, ManagedRecycleIntentDigest?) throws -> T) throws -> T {
        try authority.withLockedVault(grant, action: .observe) { permit in
            let journal = try self.journal(permit)
            let (snapshot, digest) = try journal.managedExecutionSnapshot(operationID: operationID)
            let value: RecycleFileObservation
            var fileFence: (() throws -> Void)?
            if let snapshot {
                let classification: String
                do {
                    classification = try classify(snapshot, permit) { file, source, target, name, destinationName, sourcePresent in
                        let absent = sourcePresent ? target : source, absentName = sourcePresent ? destinationName : name
                        let slot = snapshot.record.kind == .recycle ? target : source
                        let slotHasPayload = snapshot.record.kind == .recycle ? !sourcePresent : sourcePresent
                        let slotNames: Set<String> = slotHasPayload ? ["payload"] : []
                        // The SHA was computed from this retained FD, with the
                        // original per-block grant/session checks. Full ctime,
                        // mtime, inode, size, mode, uid and link-count checks
                        // reject changes without hashing the same bytes again.
                        fileFence = {
                            try permit.check(.observe)
                            try file.validateBefore { try permit.check(.observe) }
                            try absent.validate(privateMode: true)
                            try require(try absent.named(absentName) == nil, .staleState)
                            do { try require(Set(try slot.names(maximum: 1)) == slotNames, .staleState) }
                            catch { try permit.check(.observe); throw NASError.staleState }
                        }
                    }.0
                }
                catch { try permit.check(.observe); classification = "ambiguous" }
                value = .init(snapshot: snapshot, classification: classification)
            } else { value = .init(snapshot: nil, classification: "notVisible") }
            let result = try render(value, permit, digest)
            if let fileFence { try fileFence() }
            else if let snapshot = value.snapshot {
                let current: String
                do { current = try classify(snapshot, permit).0 }
                catch { try permit.check(.observe); current = "ambiguous" }
                try require(current == value.classification, .staleState)
            }
            return result
        }
    }
    func settle(operationID: UUID, grant: RecycleHostGrant, destinationGrant: RecycleHostGrant? = nil) throws -> FileEffectJournalRecord {
        try authority.withLockedVault(grant, action: .settle, destinationGrant: destinationGrant) { permit in
            let journal = try self.journal(permit), value = try snapshot(journal, operationID)
            if value.record.kind == .restore { try require(permit.destinationParentPath == Data(value.intent.targetParentPath.utf8), .denied) }
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
