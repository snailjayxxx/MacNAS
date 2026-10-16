import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class RecycleCoordinatorTests: RecycleVaultLab {
    func testRealEmptyBinaryAndExactLimitRecyclesRetainBytesAndCompleteEvidence() throws {
        let (root, host, registration) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        let inputs = [Data(), Data((0..<70001).map { UInt8($0 % 251) }), Data(repeating: 73, count: 16 * 1024 * 1024)]
        for (i, bytes) in inputs.enumerated() {
            let name = "日本語-\(i).bin"; try bytes.write(to: library(root).appendingPathComponent(name))
            let preview = try coordinator.preview(path: name, grant: grant)
            let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data(name.utf8))
            XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.record?.chargeState, .retained)
            XCTAssertEqual(result.record?.chargedBytes, Int64(bytes.count)); XCTAssertNil(result.error)
            XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent(name).path))
            let observation = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
            XCTAssertEqual(observation.classification, "matchedPost")
            let saved = try XCTUnwrap(observation.snapshot)
            XCTAssertEqual(saved.record.phase, .completed); XCTAssertNotNil(saved.postEvidence)
            XCTAssertEqual(saved.vaultID, registration.vaultID)
            let target = vault(root).appendingPathComponent("entries/" + saved.payloadID.uuidString.lowercased() + "/payload")
            XCTAssertEqual(try Data(contentsOf: target), bytes)
            denied(.replay) { _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data(name.utf8)) }
        }
        try host.store.validate(expectedVersion: 4)
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries WHERE charge_state='retained';"), [["3"]])
        denied(.unsupported) { _ = try PortableInstance.preview(root) }
    }
    func testFalseConfirmationAndExpiredPreviewHaveNoDatabaseOrPayloadEffect() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        var clock: TimeInterval = 0
        let coordinator = FixtureRecycleCoordinator(authority: host, now: { clock })
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        denied(.denied) { _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: false, key: Data("false".utf8)) }
        clock += 31
        denied(.expired) { _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("expired".utf8)) }
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["0"]])
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("source")), Data("keep".utf8))
    }
    func testSourceReplacementAfterPreviewRefusesBeforeAnyJournalAdmission() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host), original = library(root).appendingPathComponent("source")
        try Data("old".utf8).write(to: original); let preview = try coordinator.preview(path: "source", grant: grant)
        try FileManager.default.moveItem(at: original, to: library(root).appendingPathComponent("preserved")); try Data("new".utf8).write(to: original)
        denied(.staleState) { _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("replace".utf8)) }
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["0"]])
        XCTAssertEqual(try Data(contentsOf: original), Data("new".utf8))
    }
    func testPreparedInterruptionNeedsFreshPositiveProofToCancelAndKeepsHistory() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("prepared".utf8)) {
            if $0 == .prepared { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "prepared"); XCTAssertEqual(result.record?.chargeState, .reserved)
        let read = try host.approve(.observe, confirmed: true)
        let saved = try XCTUnwrap(coordinator.observe(operationID: preview.operationID, grant: read).snapshot)
        let registration = try host.registration()
        let journal = try DurableFileEffectJournal(store: host.store, scope: .init(instanceID: registration.instanceID,
            generation: registration.generation, userID: Data("fixture-owner".utf8), originScopeSHA256: saved.originScopeSHA256))
        denied(.unsupported) { _ = try journal.arm(operationID: preview.operationID, expectedRevision: 1) }
        denied(.unsupported) { _ = try journal.cancelPreparedWithoutExecutor(operationID: preview.operationID, expectedRevision: 1) }
        denied(.unsupported) { _ = try journal.prepareRecycle(key: Data("bypass".utf8), intent: saved.intent, volumeID: registration.volumeID,
            vaultID: registration.vaultID, byteCount: 4, evidence: saved.preEvidence) }
        denied(.denied) { _ = try coordinator.cancelPrepared(operationID: preview.operationID, grant: grant) }
        let cancelled = try coordinator.cancelPrepared(operationID: preview.operationID, grant: host.approve(.cancelPrepared, confirmed: true))
        XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertEqual(cancelled.chargeState, .released)
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["1"]])
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("source")), Data("keep".utf8))
        denied(.unsupported) { _ = try PortableInstance.export(from: root, to: child("forbidden-export")) }
    }
    func testArmedBeforeRenameIsUncertainAndCannotBeReplayedCancelledOrSettled() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("armed".utf8)) {
            if $0 == .beforeRename { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargeState, .reserved)
        let observation = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observation.classification, "sourceOnly"); XCTAssertNil(observation.snapshot?.postEvidence)
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true)) }
        denied(.staleState) { _ = try coordinator.cancelPrepared(operationID: preview.operationID, grant: host.approve(.cancelPrepared, confirmed: true)) }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("source")), Data("keep".utf8))
    }
    func testMovedWithoutPostIsOnlyCandidateAndReadOnlyObservationDoesNotWrite() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("post-missing".utf8)) {
            if $0 == .afterRename { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargedBytes, 4)
        let before = try host.store.contentDigest()
        let observation = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observation.classification, "candidateMoved"); XCTAssertNil(observation.snapshot?.postEvidence)
        XCTAssertEqual(try host.store.contentDigest(), before)
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true)) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("source").path))
    }
    func testObservedPostCanOnlyBeSettledWithNewWriteApprovalAndOriginalID() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("observed".utf8)) {
            if $0 == .observed { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "uncertain")
        let restarted = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        let next = FixtureRecycleCoordinator(authority: restarted), read = try restarted.approve(.observe, confirmed: true)
        let before = try host.store.contentDigest(), observation = try next.observe(operationID: preview.operationID, grant: read)
        XCTAssertEqual(observation.classification, "matchedPost"); XCTAssertEqual(try host.store.contentDigest(), before)
        denied(.denied) { _ = try next.settle(operationID: preview.operationID, grant: read) }
        let done = try next.settle(operationID: preview.operationID, grant: restarted.approve(.settle, confirmed: true))
        XCTAssertEqual(done.operationID, preview.operationID); XCTAssertEqual(done.entryID, preview.entryID)
        XCTAssertEqual(done.phase, .completed); XCTAssertEqual(done.chargeState, .retained)
        XCTAssertEqual(try host.store.rows("SELECT encode(reconciler_user_utf8,'hex') FROM macnas.file_effect_operations;"), [[FileEffectMetadata.hex(Data("fixture-owner".utf8))]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("source").path))
    }
    func testExistingWriterRestoringMtimeAfterObservedCannotProduceCompletion() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host), url = library(root).appendingPathComponent("source")
        try Data("good".utf8).write(to: url)
        let fd = open(url.path, O_RDWR | O_NOFOLLOW); XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("changed".utf8)) {
            if $0 == .observed {
                let stamp = try TransferIO.attributes(fd)
                try Data("evil".utf8).withUnsafeBytes { try require(pwrite(fd, $0.baseAddress, 4, 0) == 4, .unsafeFile) }
                let times = [stamp.st_atimespec, stamp.st_mtimespec]
                try times.withUnsafeBufferPointer { try require(futimens(fd, $0.baseAddress) == 0, .unsafeFile) }
            }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargeState, .reserved)
        let observation = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observation.classification, "ambiguous")
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true)) }
    }
    func testLegacyGrowthAfterArmCannotRejectAlreadyReservedPostEvidence() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("legacy-growth".utf8)) {
            if $0 == .armed { try host.store.execute("INSERT INTO macnas.labels VALUES('grow-after-arm',repeat('x',4000001));") }
        }
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.record?.chargeState, .retained)
        denied(.budgetExceeded) { _ = try host.store.contentDigest() }
        let observation = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observation.classification, "matchedPost")
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("next"))
        let refused = try coordinator.preview(path: "next", grant: grant)
        let refusal = try coordinator.commit(previewID: refused.previewID, grant: grant, confirmed: true, key: Data("over-metadata".utf8))
        XCTAssertNotEqual(refusal.state, "completed")
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["1"]])
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("next")), Data("keep".utf8))
    }
    func testUnknownPayloadInUnusedRegisteredSlotBlocksAdmissionAndIsPreserved() throws {
        let (root, host, registration) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let orphan = vault(root).appendingPathComponent("entries/" + registration.slots[0].id.uuidString.lowercased() + "/payload")
        try Data("unknown".utf8).write(to: orphan)
        try Data("source".utf8).write(to: library(root).appendingPathComponent("source"))
        let coordinator = FixtureRecycleCoordinator(authority: host)
        denied(.unsupported) { _ = try coordinator.preview(path: "source", grant: grant) }
        XCTAssertEqual(try Data(contentsOf: orphan), Data("unknown".utf8))
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["0"]])
    }
    func testRevocationInLastCheckGapCanMoveButCannotRecordPostOrReuseOldApproval() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        denied(.denied) {
            _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("last-gap-revoke".utf8)) {
                if $0 == .beforeRename { host.revokeAll() }
            }
        }
        let observed = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observed.classification, "candidateMoved"); XCTAssertEqual(observed.snapshot?.record.phase, .armed)
        XCTAssertNil(observed.snapshot?.postEvidence); XCTAssertEqual(observed.snapshot?.record.chargeState, .reserved)
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("source").path))
        denied(.denied) { _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("last-gap-revoke".utf8)) }
    }
    func testSourceReplacementInLastGapPreservesBothObjectsAndQuarantinesAdmission() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host), source = library(root).appendingPathComponent("source")
        try Data("good".utf8).write(to: source)
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("last-gap-replace".utf8)) {
            if $0 == .beforeRename {
                try FileManager.default.moveItem(at: source, to: library(root).appendingPathComponent("preserved-original"))
                try Data("evil".utf8).write(to: source)
            }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargeState, .reserved)
        let observed = try coordinator.observe(operationID: preview.operationID, grant: host.approve(.observe, confirmed: true))
        XCTAssertEqual(observed.classification, "ambiguous")
        let saved = try XCTUnwrap(observed.snapshot)
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("preserved-original")), Data("good".utf8))
        XCTAssertEqual(try Data(contentsOf: vault(root).appendingPathComponent("entries/" + saved.payloadID.uuidString.lowercased() + "/payload")), Data("evil".utf8))
        denied(.unsupported) { _ = try coordinator.preview(path: "preserved-original", grant: grant) }
    }
    func testReadOnlyDatabaseAndRecoveryModeOnlyObserveWithoutSettlement() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("keep".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        _ = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("readonly-post".utf8)) {
            if $0 == .observed { throw NASError.interrupted }
        }
        try host.store.setDefaultReadOnly()
        let file = root.appendingPathComponent("host-binding/binding.json")
        var binding = try SafeFS.read(HostBinding.self, file); binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: file)
        let fresh = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8)), next = FixtureRecycleCoordinator(authority: fresh)
        let before = try host.store.contentDigest(), read = try fresh.approve(.observe, confirmed: true)
        XCTAssertEqual(try next.observe(operationID: preview.operationID, grant: read).classification, "matchedPost")
        XCTAssertEqual(try host.store.contentDigest(), before)
        denied(.denied) { _ = try fresh.approve(.settle, confirmed: true) }
        denied(.denied) { _ = try next.settle(operationID: preview.operationID, grant: read) }
        XCTAssertEqual(try host.store.rows("SHOW default_transaction_read_only;"), [["on"]])
    }
    func testEscapedIntentCannotConsumeTheReservedPostRecordSpace() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        let base = try RecycleDirectory(library(root))
        var directory = base, components: [String] = []
        for i in 0..<3 {
            let part = "d\(i)" + String(repeating: "\u{1}", count: 205)
            directory = try directory.child(part, create: true); components.append(part)
        }
        let fd = openat(directory.fd, "file", O_CREAT | O_EXCL | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        XCTAssertEqual(write(fd, "data", 4), 4)
        let path = (components + ["file"]).joined(separator: "/"), preview = try coordinator.preview(path: path, grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("escaped-record".utf8))
        XCTAssertEqual(result.state, "failed"); XCTAssertEqual(result.error, .budgetExceeded)
        XCTAssertNotNil(try directory.named("file")); XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["0"]])
    }
    func testPreparedCancellationRefusesChangedSourceAndKeepsFullCharge() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host), source = library(root).appendingPathComponent("source")
        try Data("good".utf8).write(to: source)
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("prepared-changed".utf8)) {
            if $0 == .prepared { throw NASError.interrupted }
        }
        XCTAssertEqual(result.record?.phase, .prepared)
        try Data("evil".utf8).write(to: source)
        let before = try host.store.contentDigest(), cancel = try host.approve(.cancelPrepared, confirmed: true)
        denied(.staleState) { _ = try coordinator.cancelPrepared(operationID: preview.operationID, grant: cancel) }
        XCTAssertEqual(try host.store.contentDigest(), before)
        XCTAssertEqual(try Data(contentsOf: source), Data("evil".utf8))
        XCTAssertEqual(try host.store.rows("SELECT phase,charge_state,byte_count::text FROM macnas.file_effect_operations JOIN macnas.recycle_entries USING(entry_id);"), [["prepared","reserved","4"]])
    }
    func testJournalForcesSynchronousCommitWithoutChangingFixtureDatabaseDefault() throws {
        let (root, host, _) = try recycleLab()
        _ = try host.store.tools.sql("ALTER DATABASE \(host.store.databaseName) SET synchronous_commit='off';", database: "postgres", admin: true)
        XCTAssertEqual(try host.store.rows("SHOW synchronous_commit;"), [["off"]])
        let grant = try host.approve(.recycle, confirmed: true), coordinator = FixtureRecycleCoordinator(authority: host)
        try Data("durable".utf8).write(to: library(root).appendingPathComponent("source"))
        let preview = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data("synchronous-journal".utf8))
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.record?.chargeState, .retained)
        XCTAssertEqual(try host.store.rows("SHOW synchronous_commit;"), [["off"]])
        XCTAssertEqual(try host.store.rows("SELECT current_setting('fsync'),current_setting('full_page_writes');"), [["on","on"]])
    }
}
