import Foundation
import Darwin
import XCTest
@testable import MacNASCore

class RestoreLab: RecycleVaultLab {
    func retained(_ root: URL, _ host: FixtureRecycleAuthority, _ coordinator: FixtureRecycleCoordinator,
                  name: String = "source", bytes: Data = Data("keep".utf8), grant: RecycleHostGrant? = nil) throws -> UUID {
        let granted = try grant ?? host.approve(.recycle, confirmed: true)
        try bytes.write(to: library(root).appendingPathComponent(name))
        let preview = try coordinator.preview(path: name, grant: granted)
        let result = try coordinator.commit(previewID: preview.previewID, grant: granted, confirmed: true, key: Data(UUID().uuidString.utf8))
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.record?.chargeState, .retained)
        return preview.entryID
    }
    func destination(_ root: URL, name: String = "dest") throws {
        try FileManager.default.createDirectory(at: library(root).appendingPathComponent(name), withIntermediateDirectories: false,
            attributes: [.posixPermissions: 0o700])
    }
}

final class RestoreCoordinatorTests: RestoreLab {
    func testRealRestoreEmptyBinaryAndExactLimitPreservesEntryAndReleasesOnlyRetainedCharge() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), recycle = try host.approve(.recycle, confirmed: true)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let read = try host.approve(.observe, confirmed: true)
        try Data("untouched".utf8).write(to: library(root).appendingPathComponent("dest/other"))
        for (i, bytes) in [Data(), Data((0..<70001).map { UInt8($0 % 251) }), Data(repeating: 41, count: 16 * 1024 * 1024)].enumerated() {
            let entry = try retained(root, host, coordinator, name: "original-\(i)", bytes: bytes, grant: recycle)
            let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "復元-\(i).bin", grant: restore, destinationGrant: target)
            let result = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-\(i)".utf8), destinationGrant: target)
            XCTAssertEqual(result.state, "completed"); XCTAssertNil(result.error)
            XCTAssertEqual(result.record?.entryID, entry); XCTAssertEqual(result.record?.kind, .restore)
            XCTAssertEqual(result.record?.chargeState, .released); XCTAssertEqual(result.record?.chargedBytes, 0)
            XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/復元-\(i).bin")), bytes)
            let observation = try coordinator.observe(operationID: preview.operationID, grant: read)
            XCTAssertEqual(observation.classification, "matchedPost")
            XCTAssertNil(try RecycleDirectory(vault(root).appendingPathComponent("entries/" + XCTUnwrap(observation.snapshot).payloadID.uuidString.lowercased())).named("payload"))
            denied(.replay) { _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-\(i)".utf8), destinationGrant: target) }
        }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/other")), Data("untouched".utf8))
        XCTAssertEqual(try host.store.rows("SELECT count(*),count(*) FILTER(WHERE charge_state='released') FROM macnas.recycle_entries;"), [["3","3"]])
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["6"]])
        try host.store.validate(expectedVersion: 4)
    }
    func testRestoreRequiresIndependentPurposeAndExactDestinationApproval() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), recycle = try host.approve(.recycle, confirmed: true)
        let entry = try retained(root, host, coordinator, grant: recycle)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        denied(.denied) { _ = try host.approve(.restoreDestination, confirmed: true) }
        denied(.denied) { _ = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: recycle, destinationGrant: target) }
        denied(.denied) { _ = try coordinator.previewRestore(entryID: entry, parentPath: "", name: "out", grant: restore, destinationGrant: target) }
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        denied(.denied) { _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("missing-target".utf8)) }
        denied(.denied) { _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: false, key: Data("false".utf8), destinationGrant: target) }
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("dest/out").path))
    }
    func testRestoreConflictCaseUnicodeAndMissingAncestorNeverOverwriteOrCreateParents() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        try Data("other".utf8).write(to: library(root).appendingPathComponent("dest/Exists"))
        try Data("unicode".utf8).write(to: library(root).appendingPathComponent("dest/é.txt"))
        for name in ["Exists", "exists", "e\u{301}.txt"] {
            denied(.collision) { _ = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: name, grant: restore, destinationGrant: target) }
        }
        denied(.unsafeFile) { _ = try host.approveRestoreDestination(parentPath: "missing/child", confirmed: true) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("missing").path))
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/Exists")), Data("other".utf8))
        XCTAssertEqual(try host.store.rows("SELECT charge_state,byte_count::text FROM macnas.recycle_entries;"), [["retained","4"]])
    }
    func testPreparedRestoreCancellationRetainsEntryBytesAndAllowsFreshPreview() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        let result = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("cancel-restore".utf8), destinationGrant: target) {
            if $0 == .prepared { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "prepared"); XCTAssertEqual(result.record?.chargeState, .retained)
        let cancelled = try coordinator.cancelPrepared(operationID: preview.operationID, grant: host.approve(.cancelPrepared, confirmed: true))
        XCTAssertEqual(cancelled.phase, .cancelled); XCTAssertEqual(cancelled.chargeState, .retained); XCTAssertEqual(cancelled.chargedBytes, 4)
        let fresh = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "another", grant: restore, destinationGrant: target)
        XCTAssertEqual(fresh.entryID, entry); XCTAssertNotEqual(fresh.operationID, preview.operationID)
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.recycle_entries;"), [["1"]])
        try host.store.validate(expectedVersion: 4)
    }
    func testRestoreMovedWithoutPostCannotBeSettledOrReleaseRetainedBytes() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        let result = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-no-post".utf8), destinationGrant: target) {
            if $0 == .afterRename { throw NASError.interrupted }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargeState, .retained)
        let read = try host.approve(.observe, confirmed: true), before = try host.store.contentDigest()
        let observed = try coordinator.observe(operationID: preview.operationID, grant: read)
        XCTAssertEqual(observed.classification, "candidateMoved"); XCTAssertNil(observed.snapshot?.postEvidence)
        XCTAssertEqual(try host.store.contentDigest(), before)
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true), destinationGrant: target) }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("keep".utf8))
    }
    func testRestoreObservedSettlementNeedsFreshDestinationAndReleasesOriginalEntry() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-post".utf8), destinationGrant: target) {
            if $0 == .observed { throw NASError.interrupted }
        }
        let restarted = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8)), next = FixtureRecycleCoordinator(authority: restarted)
        let read = try restarted.approve(.observe, confirmed: true), before = try host.store.contentDigest()
        XCTAssertEqual(try next.observe(operationID: preview.operationID, grant: read).classification, "matchedPost")
        XCTAssertEqual(try host.store.contentDigest(), before)
        let write = try restarted.approve(.settle, confirmed: true)
        denied(.denied) { _ = try next.settle(operationID: preview.operationID, grant: write) }
        let freshTarget = try restarted.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let done = try next.settle(operationID: preview.operationID, grant: write, destinationGrant: freshTarget)
        XCTAssertEqual(done.operationID, preview.operationID); XCTAssertEqual(done.entryID, entry)
        XCTAssertEqual(done.chargeState, .released); XCTAssertEqual(done.chargedBytes, 0)
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("keep".utf8))
        try host.store.validate(expectedVersion: 4)
    }
    func testTargetDirectoryReplacementInvalidatesOldDestinationApprovalBeforePayloadAccess() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        try FileManager.default.moveItem(at: library(root).appendingPathComponent("dest"), to: library(root).appendingPathComponent("preserved-dir"))
        try destination(root)
        denied(.staleState) { _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("target-replaced".utf8), destinationGrant: target) }
        denied(.staleState) { _ = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target) }
        let fresh = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        XCTAssertNoThrow(try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: fresh))
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
        XCTAssertTrue(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("preserved-dir").path))
    }
    func testReleasedEntryCannotRestoreAgainAndItsRegisteredSlotNeverRecycles() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        XCTAssertEqual(try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("released".utf8), destinationGrant: target).state, "completed")
        denied(.denied) { _ = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "again", grant: restore, destinationGrant: target) }
        let recycle = try host.approve(.recycle, confirmed: true), next = try coordinator.preview(path: "dest/out", grant: recycle)
        XCTAssertEqual(try coordinator.commit(previewID: next.previewID, grant: recycle, confirmed: true, key: Data("new-entry".utf8)).state, "completed")
        XCTAssertNotEqual(next.entryID, entry)
        XCTAssertEqual(try host.store.rows("SELECT count(*),count(DISTINCT payload_id),sum(byte_count) FILTER(WHERE charge_state<>'released')::text FROM macnas.recycle_entries;"), [["2","2","4"]])
        try host.store.validate(expectedVersion: 4)
    }
    func testRestorePostSurvivesLegacyGrowthAfterArmWithoutRechargingBytes() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        let done = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-growth".utf8), destinationGrant: target) {
            if $0 == .armed { try host.store.execute("INSERT INTO macnas.labels VALUES('restore-legacy-growth',repeat('x',4000001));") }
        }
        XCTAssertEqual(done.state, "completed"); XCTAssertEqual(done.record?.chargeState, .released)
        denied(.budgetExceeded) { _ = try host.store.contentDigest() }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("keep".utf8))
    }
    func testRecoveryModeCannotIssueEitherRestoreOrDestinationWriteApproval() throws {
        let (root, host, _) = try recycleLab(), coordinator = FixtureRecycleCoordinator(authority: host)
        try destination(root)
        let entry = try retained(root, host, coordinator), restore = try host.approve(.restore, confirmed: true)
        let target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-readonly".utf8), destinationGrant: target) {
            if $0 == .observed { throw NASError.interrupted }
        }
        try host.store.setDefaultReadOnly()
        let path = root.appendingPathComponent("host-binding/binding.json")
        var binding = try SafeFS.read(HostBinding.self, path); binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: path)
        let fresh = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        let next = FixtureRecycleCoordinator(authority: fresh), read = try fresh.approve(.observe, confirmed: true)
        let before = try host.store.contentDigest()
        XCTAssertEqual(try next.observe(operationID: preview.operationID, grant: read).classification, "matchedPost")
        XCTAssertEqual(try host.store.contentDigest(), before)
        denied(.denied) { _ = try fresh.approve(.restore, confirmed: true) }
        denied(.denied) { _ = try fresh.approveRestoreDestination(parentPath: "", confirmed: true) }
        denied(.denied) { _ = try fresh.approve(.settle, confirmed: true) }
        XCTAssertEqual(try host.store.rows("SELECT charge_state,byte_count::text FROM macnas.recycle_entries;"), [["retained","4"]])
    }
    func testChangedPreparedRestorePayloadCannotBeCancelledToReleaseOrReuseEntry() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("prepared-modified".utf8), destinationGrant: target) {
            if $0 == .prepared { throw NASError.interrupted }
        }
        let payload = try XCTUnwrap(try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries;").first?.first)
        try Data("evil".utf8).write(to: vault(root).appendingPathComponent("entries/" + payload + "/payload"))
        let before = try host.store.contentDigest()
        denied(.staleState) { _ = try coordinator.cancelPrepared(operationID: preview.operationID, grant: host.approve(.cancelPrepared, confirmed: true)) }
        XCTAssertEqual(try host.store.contentDigest(), before)
        XCTAssertEqual(try host.store.rows("SELECT phase,charge_state,byte_count::text FROM macnas.file_effect_operations JOIN macnas.recycle_entries USING(entry_id) WHERE kind='restore';"), [["prepared","retained","4"]])
    }
    func testRestoreExistingWriterRestoringMtimeAfterObservedCannotReleaseCharge() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let payload = try XCTUnwrap(try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries;").first?.first)
        let fd = open(vault(root).appendingPathComponent("entries/" + payload + "/payload").path, O_RDWR | O_NOFOLLOW)
        XCTAssertGreaterThanOrEqual(fd, 0); defer { close(fd) }
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        let result = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-restored-mtime".utf8), destinationGrant: target) {
            if $0 == .observed {
                let before = try TransferIO.attributes(fd)
                try Data("evil".utf8).withUnsafeBytes { try require(pwrite(fd, $0.baseAddress, 4, 0) == 4, .unsafeFile) }
                let times = [before.st_atimespec, before.st_mtimespec]
                try times.withUnsafeBufferPointer { try require(futimens(fd, $0.baseAddress) == 0, .unsafeFile) }
            }
        }
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.record?.chargeState, .retained)
        let read = try host.approve(.observe, confirmed: true)
        XCTAssertEqual(try coordinator.observe(operationID: preview.operationID, grant: read).classification, "ambiguous")
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true), destinationGrant: target) }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("evil".utf8))
    }
    func testRetentionExpiryKeepsChargeAndPayloadUntilAnApprovedRestoreCompletes() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        try host.store.execute("UPDATE macnas.recycle_entries SET created_at=created_at-interval '31 days',retain_until=retain_until-interval '31 days';")
        XCTAssertEqual(try host.store.rows("SELECT retain_until<clock_timestamp(),charge_state,byte_count::text FROM macnas.recycle_entries;"), [["t","retained","4"]])
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        XCTAssertEqual(try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("expired-policy".utf8), destinationGrant: target).state, "completed")
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("keep".utf8))
        XCTAssertEqual(try host.store.rows("SELECT charge_state FROM macnas.recycle_entries;"), [["released"]])
        try host.store.validate(expectedVersion: 4)
    }
    func testDestinationReplacementInLastRenameGapPreservesMovedObjectAndRetainedCharge() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        denied(.staleState) {
            _ = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-last-target-gap".utf8), destinationGrant: target) {
                if $0 == .beforeRename {
                    try FileManager.default.moveItem(at: library(root).appendingPathComponent("dest"), to: library(root).appendingPathComponent("preserved-destination"))
                    try destination(root)
                }
            }
        }
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("preserved-destination/out")), Data("keep".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("dest/out").path))
        let read = try host.approve(.observe, confirmed: true), before = try host.store.contentDigest()
        XCTAssertEqual(try coordinator.observe(operationID: preview.operationID, grant: read).classification, "ambiguous")
        XCTAssertEqual(try host.store.contentDigest(), before)
        let freshTarget = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        denied(.staleState) { _ = try coordinator.settle(operationID: preview.operationID, grant: host.approve(.settle, confirmed: true), destinationGrant: freshTarget) }
        XCTAssertEqual(try host.store.rows("SELECT phase,charge_state,post_evidence IS NULL FROM macnas.file_effect_operations JOIN macnas.recycle_entries USING(entry_id) WHERE kind='restore';"), [["armed","retained","t"]])
    }
    func testUnrelatedDestinationGrowthAfterRenameCannotHideUniquePostEvidence() throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let coordinator = FixtureRecycleCoordinator(authority: host), entry = try retained(root, host, coordinator)
        let restore = try host.approve(.restore, confirmed: true), target = try host.approveRestoreDestination(parentPath: "dest", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: entry, parentPath: "dest", name: "out", grant: restore, destinationGrant: target)
        let result = try coordinator.commit(previewID: preview.previewID, grant: restore, confirmed: true, key: Data("restore-post-growth".utf8), destinationGrant: target) {
            if $0 == .afterRename {
                for index in 0...1000 { try Data().write(to: library(root).appendingPathComponent("dest/unrelated-\(index)")) }
            }
        }
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.record?.chargeState, .released)
        XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("dest/out")), Data("keep".utf8))
        XCTAssertTrue(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("dest/unrelated-1000").path))
        try host.store.validate(expectedVersion: 4)
    }

}
