import Foundation
import CryptoKit
import XCTest
@testable import MacNASCore

/// Shared synthetic-only builders. No source/vault/payload path is created or opened by these fixtures.
class FileEffectJournalLab: LabTest {
    let journalVolumeID = UUID(uuidString: "70000000-0000-0000-0000-000000000001")!
    let journalVaultID = UUID(uuidString: "70000000-0000-0000-0000-000000000002")!
    let journalScopeHash = String(repeating: "a", count: 64)

    func journalFixture(_ name: String = "journal") throws -> (URL, StateStore, DurableFileEffectJournal) {
        let root = child(name); try PortableInstance.createSynthetic(at: root, databaseVersion: 4)
        let store = try PortableInstance.store(root), identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let scope = FileEffectJournalScope(instanceID: identity.instanceID, generation: Int64(identity.generation), userID: Data("fixture-owner".utf8), originScopeSHA256: journalScopeHash)
        return (root, store, try DurableFileEffectJournal(store: store, scope: scope))
    }
    func journalIntent(_ name: String = "source.bin", kind: FileEffectDirection = .recycle) -> FileEffectIntent {
        FileEffectIntent(kind: kind, libraryID: "fixture-library", sourcePath: "folder/" + name, targetParentPath: "", name: name)
    }
    func journalEvidence(bytes: Int64 = 0) -> FileEffectEvidence {
        let object = FileEffectStamp(device: "1", inode: "18446744073709551615", mode: 0o100600, uid: 501, links: 1, bytes: bytes,
                                     mtimeSeconds: "1700000000", mtimeNanos: 123, ctimeSeconds: "1700000001", ctimeNanos: 456)
        var parent = object; parent.inode = "11"; parent.mode = 0o040700; parent.links = 2; parent.bytes = 0
        var target = parent; target.inode = "12"
        return FileEffectEvidence(object: object, sourceParent: parent, targetParent: target, sha256: String(repeating: "b", count: 64))
    }
    @discardableResult
    func prepareJournal(_ journal: DurableFileEffectJournal, name: String = "source.bin", key: String? = nil, bytes: Int64 = 0) throws -> FileEffectJournalRecord {
        try journal.prepareRecycle(key: Data((key ?? name).utf8), intent: journalIntent(name), volumeID: journalVolumeID, vaultID: journalVaultID,
                                   byteCount: bytes, evidence: journalEvidence(bytes: bytes))
    }
    /// Closed SQL-only constraint fixture; this never proves or performs a filesystem effect.
    func journalRetainedFixture(_ store: StateStore, record: FileEffectJournalRecord) throws -> FileEffectJournalRecord {
        try store.execute("""
        BEGIN;
        UPDATE macnas.file_effect_operations SET phase='completed',revision=revision+1,armed_at=prepared_at,observed_at=prepared_at,completed_at=prepared_at,
          source_parent_synced_at=prepared_at,target_parent_synced_at=prepared_at,post_evidence=pre_evidence WHERE operation_id=\(FileEffectMetadata.uuidSQL(record.operationID));
        UPDATE macnas.recycle_entries SET charge_state='retained',active_operation_id=NULL,revision=revision+1 WHERE entry_id=\(FileEffectMetadata.uuidSQL(record.entryID));
        COMMIT;
        """)
        return FileEffectJournalRecord(operationID: record.operationID, entryID: record.entryID, kind: .recycle, phase: .completed,
                                      revision: record.revision + 1, entryRevision: record.entryRevision + 1, chargeState: .retained,
                                      chargedBytes: record.chargedBytes, ownerUserHex: record.ownerUserHex, intentSHA256: record.intentSHA256)
    }
}

private final class JournalThreadResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [FileEffectJournalRecord] = []
    private(set) var errors: [NASError] = []
    func record(_ value: FileEffectJournalRecord) { lock.lock(); defer { lock.unlock() }; records.append(value) }
    func error(_ value: Error) { lock.lock(); defer { lock.unlock() }; errors.append(value as? NASError ?? .invalidSchema) }
}

final class FileEffectJournalTests: FileEffectJournalLab {
    func testPreparedRecordPersistsAcrossNewCoordinatorWithoutCreatingAnyPayload() throws {
        let (root, store, journal) = try journalFixture()
        // The coordinator legitimately creates this single known lock; include it in the baseline, never ignore host-binding or payload names.
        do { let lock = try InstanceLock(root, mode: .shared); withExtendedLifetime(lock) {} }
        let before = try SafeFS.files(root)
        XCTAssertTrue(before.contains(".instance.lock"))
        let first = try prepareJournal(journal, bytes: 123)
        XCTAssertEqual(first.phase, .prepared); XCTAssertEqual(first.chargeState, .reserved); XCTAssertEqual(first.chargedBytes, 123)
        let identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let restarted = try DurableFileEffectJournal(store: StateStore(databaseName: store.databaseName, instanceRoot: root),
            scope: FileEffectJournalScope(instanceID: identity.instanceID, generation: Int64(identity.generation), userID: Data("fixture-owner".utf8), originScopeSHA256: journalScopeHash))
        XCTAssertEqual(try restarted.record(operationID: first.operationID), first)
        XCTAssertEqual(try SafeFS.files(root), before)
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["1"]])
    }
    func testIdempotencyReturnsOriginalIDsAndDifferentIntentCollides() throws {
        let (_, store, journal) = try journalFixture()
        let first = try prepareJournal(journal, bytes: 4), repeated = try prepareJournal(journal, bytes: 4)
        XCTAssertEqual(first, repeated)
        denied(.collision) { _ = try prepareJournal(journal, name: "changed.bin", key: "source.bin", bytes: 4) }
        denied(.collision) { _ = try prepareJournal(journal, bytes: 5) }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
    }
    func testExplicitPayloadIdentityCollisionDoesNotLeaveHalfAnEntry() throws {
        let (_, store, journal) = try journalFixture(), payloadID = UUID()
        let first = try journal.prepareRecycle(key: Data("first".utf8), intent: journalIntent(), volumeID: journalVolumeID, vaultID: journalVaultID, byteCount: 0, evidence: journalEvidence(), payloadID: payloadID)
        denied(.collision) { _ = try journal.prepareRecycle(key: Data("second".utf8), intent: journalIntent("other.bin"), volumeID: journalVolumeID, vaultID: journalVaultID, byteCount: 0, evidence: journalEvidence(), payloadID: payloadID) }
        XCTAssertEqual(try journal.record(operationID: first.operationID), first)
        XCTAssertEqual(try store.rows("SELECT (SELECT count(*) FROM macnas.recycle_entries),(SELECT count(*) FROM macnas.file_effect_operations);"), [["1", "1"]])
    }
    func testCompareAndSwapAllowsOnlyOneArmAndUncertainRetainsFullCharge() throws {
        let (_, store, journal) = try journalFixture(), first = try prepareJournal(journal, bytes: 99)
        let armed = try journal.arm(operationID: first.operationID, expectedRevision: 1)
        XCTAssertEqual(armed.phase, .armed); XCTAssertEqual(armed.revision, 2)
        denied(.staleState) { _ = try journal.arm(operationID: first.operationID, expectedRevision: 1) }
        denied(.staleState) { _ = try journal.cancelPreparedWithoutExecutor(operationID: first.operationID, expectedRevision: armed.revision) }
        let uncertain = try journal.markUncertain(operationID: first.operationID, expectedRevision: armed.revision, error: .interrupted)
        XCTAssertEqual(uncertain.phase, .uncertain); XCTAssertEqual(uncertain.chargedBytes, 99)
        denied(.staleState) { _ = try journal.cancelPreparedWithoutExecutor(operationID: first.operationID, expectedRevision: uncertain.revision) }
        XCTAssertEqual(try store.rows("SELECT charge_state,byte_count FROM macnas.recycle_entries;"), [["reserved", "99"]])
    }
    func testPreparedCancellationReleasesOnlyRecycleReservationAndCannotRevive() throws {
        let (_, _, journal) = try journalFixture(), first = try prepareJournal(journal, bytes: 33)
        let cancelled = try journal.cancelPreparedWithoutExecutor(operationID: first.operationID, expectedRevision: first.revision)
        XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertEqual(cancelled.chargeState, .released); XCTAssertEqual(cancelled.chargedBytes, 0)
        XCTAssertEqual(try prepareJournal(journal, bytes: 33), cancelled)
        denied(.staleState) { _ = try journal.arm(operationID: cancelled.operationID, expectedRevision: cancelled.revision) }
        denied(.staleState) { _ = try journal.markUncertain(operationID: cancelled.operationID, expectedRevision: cancelled.revision, error: .interrupted) }
    }
    func testRestoreRequiresRetainedEntryAndCancellationDoesNotReleasePayloadCharge() throws {
        let (_, store, journal) = try journalFixture(), original = try prepareJournal(journal, bytes: 81)
        let restore = journalIntent(kind: .restore), evidence = journalEvidence(bytes: 81)
        denied(.staleState) { _ = try journal.prepareRestore(entryID: original.entryID, expectedEntryRevision: original.entryRevision, key: Data("restore".utf8), intent: restore, evidence: evidence) }
        let retained = try journalRetainedFixture(store, record: original)
        let first = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: retained.entryRevision, key: Data("restore".utf8), intent: restore, evidence: evidence)
        XCTAssertEqual(first.kind, .restore); XCTAssertEqual(first.chargeState, .retained); XCTAssertEqual(first.chargedBytes, 81)
        let repeated = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: retained.entryRevision, key: Data("restore".utf8), intent: restore, evidence: evidence)
        XCTAssertEqual(first, repeated)
        denied(.staleState) { _ = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: first.entryRevision, key: Data("other".utf8), intent: restore, evidence: evidence) }
        let cancelled = try journal.cancelPreparedWithoutExecutor(operationID: first.operationID, expectedRevision: first.revision)
        XCTAssertEqual(cancelled.chargeState, .retained); XCTAssertEqual(cancelled.chargedBytes, 81)
        XCTAssertEqual(try store.rows("SELECT count(*),sum(byte_count) FROM macnas.recycle_entries;"), [["1", "81"]])
    }
    func testRestoreCannotChangeLibraryOriginalObjectOrByteEvidence() throws {
        let (_, store, journal) = try journalFixture(), original = try prepareJournal(journal, bytes: 4), retained = try journalRetainedFixture(store, record: original)
        for changed in ["library", "path", "hash", "bytes"] {
            var intent = journalIntent(kind: .restore), evidence = journalEvidence(bytes: 4)
            if changed == "library" { intent.libraryID = "other" }
            if changed == "path" { intent.sourcePath = "folder/other" }
            if changed == "hash" { evidence.sha256 = String(repeating: "c", count: 64) }
            if changed == "bytes" { evidence.object.bytes = 5 }
            denied(.staleState) { _ = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: retained.entryRevision, key: Data(changed.utf8), intent: intent, evidence: evidence) }
        }
    }
    func testAtomicCapacityAdmissionAcrossConcurrentCoordinators() throws {
        let (root, store, journal) = try journalFixture()
        for number in 0..<3 { _ = try prepareJournal(journal, name: "existing\(number)", bytes: DurableFileEffectJournal.fileBytes) }
        let identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json")), instanceID = identity.instanceID, generation = Int64(identity.generation), result = JournalThreadResults(), group = DispatchGroup(), databaseName = store.databaseName
        for number in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let coordinator = try DurableFileEffectJournal(store: StateStore(databaseName: databaseName, instanceRoot: root), scope: FileEffectJournalScope(instanceID: instanceID, generation: generation, userID: Data("fixture-owner".utf8), originScopeSHA256: String(repeating: "a", count: 64)))
                    let intent = FileEffectIntent(kind: .recycle, libraryID: "fixture-library", sourcePath: "concurrent\(number)", targetParentPath: "", name: "concurrent\(number)")
                    var object = FileEffectStamp(device: "1", inode: "123", mode: 0o100600, uid: 501, links: 1, bytes: DurableFileEffectJournal.fileBytes, mtimeSeconds: "1", mtimeNanos: 0, ctimeSeconds: "1", ctimeNanos: 0)
                    let source = object; object.mode = 0o040700; object.links = 2; object.bytes = 0
                    let evidence = FileEffectEvidence(object: source, sourceParent: object, targetParent: object, sha256: String(repeating: "b", count: 64))
                    result.record(try coordinator.prepareRecycle(key: Data("concurrent\(number)".utf8), intent: intent, volumeID: UUID(uuidString: "70000000-0000-0000-0000-000000000001")!, vaultID: UUID(uuidString: "70000000-0000-0000-0000-000000000002")!, byteCount: DurableFileEffectJournal.fileBytes, evidence: evidence))
                } catch { result.error(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success)
        XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.errors, [.budgetExceeded])
        XCTAssertEqual(try store.rows("SELECT count(*),sum(byte_count) FROM macnas.recycle_entries;"), [["4", "67108864"]])
    }
    func testConcurrentRevisionCASDoesNotCreateDuplicateEffects() throws {
        let (root, store, journal) = try journalFixture(), first = try prepareJournal(journal)
        let identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json")), instanceID = identity.instanceID, result = JournalThreadResults(), group = DispatchGroup(), databaseName = store.databaseName
        for _ in 0..<2 {
            group.enter()
            DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let coordinator = try DurableFileEffectJournal(store: StateStore(databaseName: databaseName, instanceRoot: root), scope: FileEffectJournalScope(instanceID: instanceID, generation: 0, userID: Data("fixture-owner".utf8), originScopeSHA256: String(repeating: "a", count: 64)))
                    result.record(try coordinator.arm(operationID: first.operationID, expectedRevision: first.revision))
                } catch { result.error(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success); XCTAssertEqual(result.records.count, 1); XCTAssertEqual(result.errors, [.staleState])
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
    }
    func testConcurrentDuplicatePreparationReturnsOneDurableOperation() throws {
        let (root, store, _) = try journalFixture(), identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let scope = FileEffectJournalScope(instanceID: identity.instanceID, generation: 0, userID: Data("fixture-owner".utf8), originScopeSHA256: journalScopeHash)
        let intent = journalIntent(), evidence = journalEvidence(), volumeID = journalVolumeID, vaultID = journalVaultID, databaseName = store.databaseName
        let group = DispatchGroup(), result = JournalThreadResults()
        for _ in 0..<2 {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let coordinator = try DurableFileEffectJournal(store: StateStore(databaseName: databaseName, instanceRoot: root), scope: scope)
                    result.record(try coordinator.prepareRecycle(key: Data("one-key".utf8), intent: intent, volumeID: volumeID, vaultID: vaultID, byteCount: 0, evidence: evidence))
                } catch { result.error(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 20), .success); XCTAssertTrue(result.errors.isEmpty); XCTAssertEqual(result.records.count, 2)
        XCTAssertEqual(result.records.first?.operationID, result.records.last?.operationID)
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
    }
    func testActivityBudgetIncludesUncertainAndZeroByteOperations() throws {
        let (_, _, journal) = try journalFixture()
        for number in 0..<8 {
            let record = try prepareJournal(journal, name: "zero\(number)")
            if number == 0 { let armed = try journal.arm(operationID: record.operationID, expectedRevision: 1); _ = try journal.markUncertain(operationID: record.operationID, expectedRevision: armed.revision, error: .interrupted) }
        }
        denied(.budgetExceeded) { _ = try prepareJournal(journal, name: "ninth") }
    }
    func testEntryHistoryBudgetIncludesCancelledReleasedRecords() throws {
        let (_, store, journal) = try journalFixture()
        for number in 0..<64 {
            let record = try prepareJournal(journal, name: "history\(number)")
            _ = try journal.cancelPreparedWithoutExecutor(operationID: record.operationID, expectedRevision: record.revision)
        }
        denied(.budgetExceeded) { _ = try prepareJournal(journal, name: "overflow") }
        XCTAssertEqual(try store.rows("SELECT count(*),sum(byte_count) FROM macnas.recycle_entries WHERE charge_state='released';"), [["64", "0"]])
    }
    func testOperationHistoryBudgetIncludesCancelledRestores() throws {
        let (_, store, journal) = try journalFixture(), first = try prepareJournal(journal), retained = try journalRetainedFixture(store, record: first)
        var entryRevision = retained.entryRevision
        for number in 0..<255 {
            let record = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: entryRevision, key: Data("restore\(number)".utf8), intent: journalIntent(kind: .restore), evidence: journalEvidence())
            let cancelled = try journal.cancelPreparedWithoutExecutor(operationID: record.operationID, expectedRevision: record.revision); entryRevision = cancelled.entryRevision
        }
        denied(.budgetExceeded) { _ = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: entryRevision, key: Data("overflow".utf8), intent: journalIntent(kind: .restore), evidence: journalEvidence()) }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["256"]])
        XCTAssertEqual(try store.rows("SELECT charge_state FROM macnas.recycle_entries;"), [["retained"]])
    }
    func testRawUTF8SubjectsRemainSeparateDespiteSwiftCanonicalEquivalence() throws {
        let (root, store, _) = try journalFixture()
        let composed = "\u{e9}", decomposed = "e\u{301}"
        XCTAssertEqual(composed, decomposed); XCTAssertNotEqual(Data(composed.utf8), Data(decomposed.utf8))
        var config = try SafeFS.read(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        config.users = [LogicalUser(id: composed, role: "administrator"), LogicalUser(id: decomposed, role: "administrator")]
        try SafeFS.write(config, to: SafeFS.resolve(root, "config/platform.json"))
        let identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let one = try DurableFileEffectJournal(store: store, scope: FileEffectJournalScope(instanceID: identity.instanceID, generation: 0, userID: Data(composed.utf8), originScopeSHA256: journalScopeHash))
        let two = try DurableFileEffectJournal(store: store, scope: FileEffectJournalScope(instanceID: identity.instanceID, generation: 0, userID: Data(decomposed.utf8), originScopeSHA256: journalScopeHash))
        let a = try prepareJournal(one), b = try prepareJournal(two)
        XCTAssertNotEqual(a.operationID, b.operationID); XCTAssertNotEqual(a.ownerUserHex, b.ownerUserHex)
        XCTAssertNil(try one.record(operationID: b.operationID)); XCTAssertNil(try two.record(operationID: a.operationID))
        denied(.denied) { _ = try two.arm(operationID: a.operationID, expectedRevision: a.revision) }
    }
    func testChangedScopeGenerationAndReadonlyDatabaseRefuseWrites() throws {
        let (root, store, journal) = try journalFixture(), record = try prepareJournal(journal)
        let identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let changed = try DurableFileEffectJournal(store: store, scope: FileEffectJournalScope(instanceID: identity.instanceID, generation: 0, userID: Data("fixture-owner".utf8), originScopeSHA256: String(repeating: "c", count: 64)))
        XCTAssertNotNil(try changed.record(operationID: record.operationID))
        denied(.staleState) { _ = try changed.arm(operationID: record.operationID, expectedRevision: 1) }
        var binding = try SafeFS.read(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json")); binding.mode = "read_only_recovery"
        try SafeFS.write(binding, to: SafeFS.resolve(root, "host-binding/binding.json"))
        denied(.denied) { _ = try journal.cancelPreparedWithoutExecutor(operationID: record.operationID, expectedRevision: 1) }
        XCTAssertNotNil(try journal.record(operationID: record.operationID))
        binding.mode = "synthetic_development"; try SafeFS.write(binding, to: SafeFS.resolve(root, "host-binding/binding.json")); try store.setDefaultReadOnly()
        denied(.database) { _ = try journal.arm(operationID: record.operationID, expectedRevision: 1) }
    }
    func testIdentityGenerationDatabaseBindingAndUnknownHostStateRejectEvenRecordReads() throws {
        let (root, _, journal) = try journalFixture(), record = try prepareJournal(journal)
        let identityURL = try SafeFS.resolve(root, "instance.json"), bindingURL = try SafeFS.resolve(root, "host-binding/binding.json"), configURL = try SafeFS.resolve(root, "config/platform.json")
        let identity = try SafeFS.read(InstanceIdentity.self, identityURL), binding = try SafeFS.read(HostBinding.self, bindingURL), config = try SafeFS.read(PortableConfig.self, configURL)
        for change in ["identity", "generation", "identity-schema"] {
            var altered = identity
            if change == "identity" { altered.instanceID = UUID() }
            if change == "generation" { altered.generation += 1 }
            if change == "identity-schema" { altered.schemaVersion = 99 }
            try SafeFS.write(altered, to: identityURL)
            denied(.denied) { _ = try journal.record(operationID: record.operationID) }
        }
        try SafeFS.write(identity, to: identityURL)
        for change in ["database", "host", "mode"] {
            var altered = binding
            if change == "database" { altered.databaseName = "macnas_fixture_other" }
            if change == "host" { altered.hostID = "" }
            if change == "mode" { altered.mode = "unknown-mode" }
            try SafeFS.write(altered, to: bindingURL)
            denied(.denied) { _ = try journal.record(operationID: record.operationID) }
        }
        try SafeFS.write(binding, to: bindingURL)
        var altered = config; altered.users[0].role = "unknown-role"; try SafeFS.write(altered, to: configURL)
        denied(.denied) { _ = try journal.record(operationID: record.operationID) }
        try SafeFS.write(config, to: configURL)
        XCTAssertNotNil(try journal.record(operationID: record.operationID))
    }
    func testNativeAppRolesCannotReadOrModifyEitherEffectTable() throws {
        let (_, store, journal) = try journalFixture(); _ = try prepareJournal(journal)
        for app in SampleApp.allCases {
            for table in ["recycle_entries", "file_effect_operations"] {
                denied(.database) { _ = try store.tools.sql("SELECT * FROM macnas.\(table);", database: store.databaseName, principal: .app(app)) }
                denied(.database) { _ = try store.tools.sql("DELETE FROM macnas.\(table);", database: store.databaseName, principal: .app(app)) }
            }
        }
    }
    func testStrictMetadataRejectsUnknownKeysMalformedUTF8PathsAndLossyWideIntegers() throws {
        var intent = journalIntent(); intent.sourcePath = "../escape"
        denied(.unsafePath) { try intent.validate() }
        XCTAssertNoThrow(try FileEffectMetadata.path(String(repeating: "x", count: 255)))
        denied(.unsafePath) { try FileEffectMetadata.path(String(repeating: "x", count: 256)) }
        denied(.unsafePath) { try FileEffectMetadata.path(String(repeating: "字", count: 86)) }
        denied(.unsafePath) { try FileEffectMetadata.path("folder/   /source.bin") }
        let valid = journalIntent(), encoded = try FileEffectMetadata.encoded(valid)
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: encoded) as? [String: Any]); object["hostRoot"] = "/tmp"
        denied(.invalidSchema) { _ = try FileEffectMetadata.decode(FileEffectIntent.self, from: JSONSerialization.data(withJSONObject: object)) }
        denied(.invalidSchema) { try FileEffectMetadata.subject(Data([0xc3, 0x28])) }
        for number in ["01", "+1", "18446744073709551616", "-1"] { denied(.invalidSchema) { try FileEffectMetadata.unsignedDecimal(number) } }
        for number in ["-0", "+1", "9223372036854775808"] { denied(.invalidSchema) { try FileEffectMetadata.signedDecimal(number) } }
        XCTAssertNoThrow(try FileEffectMetadata.unsignedDecimal("18446744073709551615"))
        var evidence = journalEvidence(); evidence.object.inode = "18446744073709551616"
        denied(.invalidSchema) { try evidence.validate(bytes: 0) }
        evidence = journalEvidence(); evidence.object.links = 2
        denied(.unsafeFile) { try evidence.validate(bytes: 0) }
    }
    func testWholeRecordMetadataBudgetAndTotalLegacyGrowthRefuseBeforePreparing() throws {
        let (_, store, journal) = try journalFixture()
        var intent = journalIntent(); intent.sourcePath = Array(repeating: String(repeating: "x", count: 200), count: 15).joined(separator: "/") + "/source.bin"
        XCTAssertNoThrow(try intent.validate())
        denied(.budgetExceeded) { _ = try journal.prepareRecycle(key: Data("large-row".utf8), intent: intent, volumeID: journalVolumeID, vaultID: journalVaultID, byteCount: 0, evidence: journalEvidence()) }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["0"]])
        try store.execute("INSERT INTO macnas.labels VALUES('oversized-metadata',repeat('x',3990000));")
        denied(.budgetExceeded) { _ = try prepareJournal(journal) }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["0"]])
    }
    func testRestoreReservesWorstCasePostEvidenceWithinEightKiBOperationBudget() throws {
        let (_, store, journal) = try journalFixture(), first = try prepareJournal(journal), retained = try journalRetainedFixture(store, record: first)
        var intent = journalIntent(kind: .restore); intent.targetParentPath = Array(repeating: String(repeating: "t", count: 200), count: 18).joined(separator: "/")
        XCTAssertNoThrow(try intent.validate())
        denied(.budgetExceeded) { _ = try journal.prepareRestore(entryID: retained.entryID, expectedEntryRevision: retained.entryRevision, key: Data("oversized-restore".utf8), intent: intent, evidence: journalEvidence()) }
        XCTAssertEqual(try store.rows("SELECT (SELECT count(*) FROM macnas.recycle_entries),(SELECT count(*) FROM macnas.file_effect_operations);"), [["1", "1"]])
        XCTAssertEqual(try store.rows("SELECT charge_state,active_operation_id IS NULL FROM macnas.recycle_entries;"), [["retained", "t"]])
    }
    func testSingleFileDeclaredSizeLimitRejectsBeforeCreatingRecords() throws {
        let (_, store, journal) = try journalFixture()
        for size in [-1, DurableFileEffectJournal.fileBytes + 1] { denied(.budgetExceeded) { _ = try prepareJournal(journal, name: "invalid", bytes: size) } }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["0"]])
    }
    func testSQLConstraintsRejectForgedCompletionAndUnknownEvidenceFields() throws {
        let (_, store, journal) = try journalFixture(), record = try prepareJournal(journal)
        denied(.database) { try store.execute("UPDATE macnas.file_effect_operations SET phase='completed',completed_at=prepared_at WHERE operation_id=\(FileEffectMetadata.uuidSQL(record.operationID));") }
        denied(.database) { try store.execute("UPDATE macnas.file_effect_operations SET pre_evidence=pre_evidence || '{\"extra\":true}'::jsonb;") }
        XCTAssertEqual(try journal.record(operationID: record.operationID)?.phase, .prepared)
    }
}
