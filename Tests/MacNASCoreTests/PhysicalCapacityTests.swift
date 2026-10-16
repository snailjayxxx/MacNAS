import Foundation
import Darwin
import XCTest
@testable import MacNASCore

class PhysicalCapacityLab: LabTest {
    let owner = Data("fixture-owner".utf8)
    func physicalLab(_ name: String = "physical") throws -> (URL, FixturePhysicalCapacityNamespace) {
        let root = child(name); try PortableInstance.createSynthetic(at: root, databaseVersion: 6)
        _ = try FixturePhysicalCapacityNamespace.createFresh(root: root, userID: owner, confirmed: true)
        return (root, try FixturePhysicalCapacityNamespace(root: root, userID: owner))
    }
    func receive(_ host: FixturePhysicalCapacityNamespace, data: Data = Data("data".utf8), key: String = "incoming",
                 checkpoint: (PhysicalCapacityCheckpoint) throws -> Void = { _ in }) throws -> PhysicalCapacityResult {
        let grant = try host.approveReceive(key: Data(key.utf8), bytes: Int64(data.count), sha256: TransferEncoding.digest(data), confirmed: true)
        return try host.receive(data, grant: grant, checkpoint: checkpoint)
    }
    func inventory(_ host: FixturePhysicalCapacityNamespace) throws -> PhysicalCapacityInventory {
        try host.inspect(host.approveInspect(confirmed: true))
    }
    func library(_ root: URL) -> URL { root.appendingPathComponent(RecycleVault.fixturePath+"/library") }
    func staging(_ root: URL) -> URL { root.appendingPathComponent(FixturePhysicalCapacityNamespace.stagingPath) }
}

private final class PhysicalCapacityRaceResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var values: [PhysicalCapacityResult] = []
    private(set) var errors: [NASError] = []
    func add(_ value: PhysicalCapacityResult) { lock.lock(); defer { lock.unlock() }; values.append(value) }
    func fail(_ error: Error) { lock.lock(); defer { lock.unlock() }; errors.append(error as? NASError ?? .integrity) }
}

final class PhysicalCapacityTests: PhysicalCapacityLab {
    func testPhysicalRegistryRejectsMalformedSQLIdentifiersBeforeDatabaseAccess() throws {
        for field in ["libraryInode","vaultInode"] {
            let (root,host) = try physicalLab("bad-"+field), before = try host.store.contentDigest()
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:FileEffectMetadata.encoded(host.registry)) as? [String:Any])
            object[field] = "not-an-inode' /*"
            let registry = try JSONDecoder().decode(RecycleVaultRegistration.self,from:JSONSerialization.data(withJSONObject:object))
            let hash = TransferEncoding.digest(try FileEffectMetadata.encoded(registry)), old = host.registration
            let unsigned = PhysicalCapacityRegistration(scopeID:old.scopeID,registrySHA256:hash,
                originScopeSHA256:String(repeating:"0",count:64),stagingDevice:old.stagingDevice,stagingInode:old.stagingInode)
            let changed = PhysicalCapacityRegistration(scopeID:old.scopeID,registrySHA256:hash,
                originScopeSHA256:try FixturePhysicalCapacityNamespace.scopeHash(registration:unsigned),
                stagingDevice:old.stagingDevice,stagingInode:old.stagingInode)
            try SafeFS.write(registry,to:SafeFS.resolve(root,RecycleVault.registrationPath))
            try SafeFS.write(changed,to:SafeFS.resolve(root,FixturePhysicalCapacityNamespace.markerPath))
            denied(.invalidSchema) { _ = try FixturePhysicalCapacityNamespace(root:root,userID:self.owner) }
            XCTAssertEqual(try host.store.contentDigest(),before)
            XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_allocations;"),[["0"]])
        }
    }
    func testIncomingLockAndVaultBindingReplacementRevokeSealedPhysicalPermit() throws {
        for replaced in ["execution.lock","binding.json"] {
            let (root,host) = try physicalLab("replace-"+replaced), original = child("original-"+replaced)
            let changed = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/"+replaced)
            denied(.staleState) {
                _ = try self.receive(host) { point in
                    if point == .stagingCreated {
                        try FileManager.default.moveItem(at:changed,to:original)
                        try Data().write(to:changed); XCTAssertEqual(chmod(changed.path,0o600),0)
                    }
                }
            }
            XCTAssertEqual(try host.store.rows("SELECT state,declared_bytes FROM macnas.capacity_allocations;"),[["armed","4"]])
            XCTAssertEqual(try host.store.rows("SELECT baseline_stamp IS NULL FROM macnas.capacity_file_ownership;"),[["t"]])
            XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:library(root).path).isEmpty)
            // Restore only the test's substituted metadata, retaining the armed allocation
            // and its partial stage. This grants no adoption/cancellation of that stage.
            try FileManager.default.removeItem(at:changed); try FileManager.default.moveItem(at:original,to:changed)
            let restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
            XCTAssertFalse(try inventory(restarted).clean)
            denied(.staleState) { _ = try self.receive(restarted,key:"blocked") }
        }
    }
    func testOwnedCommitRemainsBoundedAfterUnrelatedLegacyMetadataExceedsDigestBudget() throws {
        let (_,host) = try physicalLab()
        let value = try receive(host) { point in
            if point == .staged {
                try host.store.execute("UPDATE macnas.jobs SET checkpoint=jsonb_build_object('large',repeat('x',4001000));")
            }
        }
        XCTAssertEqual(value.state,"owned"); XCTAssertNil(value.error)
        XCTAssertEqual(try host.store.rows("SELECT state,declared_bytes FROM macnas.capacity_allocations;"),[["owned","4"]])
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_file_ownership WHERE baseline_stamp IS NOT NULL;"),[["1"]])
        denied(.budgetExceeded) { _ = try host.store.contentDigest() }
        XCTAssertThrowsError(try receive(host,key:"over-metadata"))
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_allocations;"),[["1"]])
    }
    func testDatabaseProofFailureRollsBackOwnedStateAndKeepsPublishedBytesChargedArmed() throws {
        let (root,host) = try physicalLab()
        let value = try receive(host) { point in
            if point == .staged {
                try host.store.execute("ALTER TABLE macnas.capacity_file_ownership ADD CONSTRAINT synthetic_proof_write_failure CHECK(baseline_stamp IS NULL);")
            }
        }
        XCTAssertEqual(value.state,"armed"); XCTAssertEqual(value.error,.database)
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(value.allocationID.uuidString.lowercased())),Data("data".utf8))
        XCTAssertEqual(try host.store.rows("SELECT state,revision,sha256 IS NULL FROM macnas.capacity_allocations;"),[["armed","2","t"]])
        XCTAssertEqual(try host.store.rows("SELECT baseline_stamp IS NULL,sha256 IS NULL,published_at IS NULL FROM macnas.capacity_file_ownership;"),[["t","t","t"]])
        try host.store.execute("ALTER TABLE macnas.capacity_file_ownership DROP CONSTRAINT synthetic_proof_write_failure;")
        try host.store.validate()
        XCTAssertEqual(try inventory(host).declared.unresolvedBytes,4)
        denied(.staleState) { _ = try self.receive(host,key:"cannot-adopt") }
    }
    func testConcurrentPhysicalUploadAndCopyCannotSpendTheLast16MiBTwice() throws {
        let (root,host) = try physicalLab(), data = Data(repeating:0x42,count:16*1024*1024)
        var source: UUID?
        for n in 0..<3 {
            let value = try receive(host,data:data,key:"seed-\(n)"); XCTAssertEqual(value.state,"owned")
            source = source ?? value.allocationID
        }
        let sourceID = try XCTUnwrap(source), userID = owner, results = PhysicalCapacityRaceResults(), group = DispatchGroup()
        for copy in [false,true] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let other = try FixturePhysicalCapacityNamespace(root:root,userID:userID)
                    if copy {
                        let grant = try other.approveCopy(source:sourceID,key:Data("race-copy".utf8),confirmed:true)
                        results.add(try other.copy(grant:grant))
                    } else {
                        let grant = try other.approveReceive(key:Data("race-upload".utf8),bytes:Int64(data.count),
                            sha256:TransferEncoding.digest(data),confirmed:true)
                        results.add(try other.receive(data,grant:grant))
                    }
                } catch { results.fail(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+120),.success)
        XCTAssertEqual(results.values.count,1); XCTAssertEqual(results.values.first?.state,"owned")
        XCTAssertNil(results.values.first?.error); XCTAssertEqual(results.errors.count,1)
        XCTAssertTrue(results.errors.allSatisfy { [.busy,.budgetExceeded].contains($0) })
        let observed = try inventory(host); XCTAssertTrue(observed.clean)
        XCTAssertEqual(observed.declared.allocatedBytes,67_108_864); XCTAssertEqual(observed.visible.count,4)
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(sourceID.uuidString.lowercased())),data)
        try host.store.validate()
    }
    func testOnlyConfirmedFreshSchema6CanRegisterAndCannotAdoptAnyPartialLayout() throws {
        let root = child("fresh"); try PortableInstance.createSynthetic(at: root, databaseVersion: 6)
        denied(.denied) { _ = try FixturePhysicalCapacityNamespace.createFresh(root: root, userID: self.owner, confirmed: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).path))
        let registration = try FixturePhysicalCapacityNamespace.createFresh(root: root, userID: owner, confirmed: true)
        let host = try FixturePhysicalCapacityNamespace(root: root, userID: owner)
        XCTAssertEqual(registration, host.registration); XCTAssertTrue(try inventory(host).clean)
        denied(.unsupported) { _ = try FixturePhysicalCapacityNamespace.createFresh(root: root, userID: self.owner, confirmed: true) }
        let old = child("old5"); try PortableInstance.createSynthetic(at: old, databaseVersion: 5)
        denied(.invalidSchema) { _ = try FixturePhysicalCapacityNamespace.createFresh(root: old, userID: self.owner, confirmed: true) }
        let partial = child("partial"); try PortableInstance.createSynthetic(at: partial, databaseVersion: 6)
        let oldHost = try FixtureRecycleAuthority(root: partial, userID: owner)
        _ = try oldHost.createFreshFixture(confirmed: true)
        XCTAssertThrowsError(try FixturePhysicalCapacityNamespace.createFresh(root: partial, userID: owner, confirmed: true))
    }
    func testZeroAndMaximumFilesHavePersistentIdentityAndExactDataAfterRestart() throws {
        for count in [0,16*1024*1024] {
            let (root, host) = try physicalLab("size-\(count)"), data = Data(repeating: 0x61, count: count)
            let result = try receive(host, data: data)
            XCTAssertEqual(result.state,"owned"); XCTAssertNil(result.error)
            let path = library(root).appendingPathComponent(result.allocationID.uuidString.lowercased())
            XCTAssertEqual(try Data(contentsOf:path),data)
            let restarted = try FixturePhysicalCapacityNamespace(root: root, userID: owner), observed = try inventory(restarted)
            XCTAssertTrue(observed.clean); XCTAssertEqual(observed.visible,[result.allocationID]); XCTAssertTrue(observed.retained.isEmpty)
            XCTAssertEqual(observed.declared.ownedBytes,Int64(count)); XCTAssertEqual(observed.declared.allocatedBytes,Int64(count))
            XCTAssertEqual(try host.store.rows("SELECT baseline_stamp->>'inode',sha256 FROM macnas.capacity_file_ownership;"),
                [[try XCTUnwrap(RecycleDirectory(library(root)).named(result.allocationID.uuidString.lowercased())).inode,TransferEncoding.digest(data)]])
            try host.store.validate(expectedVersion:6)
        }
    }
    func testCopySharesCapacityAndPreservesThePinnedSource() throws {
        let (root,host) = try physicalLab(), data = Data("copy me".utf8), source = try receive(host,data:data)
        let grant = try host.approveCopy(source: source.allocationID,key:Data("copy".utf8),confirmed:true)
        let copied = try host.copy(grant:grant)
        XCTAssertEqual(copied.state,"owned"); XCTAssertNil(copied.error); XCTAssertNotEqual(source.allocationID,copied.allocationID)
        for id in [source.allocationID,copied.allocationID] { XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(id.uuidString.lowercased())),data) }
        let observed = try inventory(host); XCTAssertTrue(observed.clean); XCTAssertEqual(observed.visible.count,2)
        XCTAssertEqual(observed.declared.allocatedBytes,Int64(data.count*2))
        try host.store.validate()
    }
    func testRecycleAndRestoreConserveOwnedCapacityAndOriginalFileIdentity() throws {
        let (root,host) = try physicalLab(), data = Data("conserved".utf8), incoming = try receive(host,data:data)
        let name = incoming.allocationID.uuidString.lowercased(), directory = try RecycleDirectory(library(root),privateMode:true)
        let original = try XCTUnwrap(directory.named(name))
        let grant = try host.approveRecycle(allocationID:incoming.allocationID,confirmed:true)
        let recycled = try host.recycle(grant:grant,key:Data("recycle".utf8))
        XCTAssertEqual(recycled.state,"completed"); XCTAssertNil(recycled.error)
        var observed = try inventory(host); XCTAssertTrue(observed.clean); XCTAssertTrue(observed.visible.isEmpty)
        XCTAssertEqual(observed.retained,[incoming.allocationID]); XCTAssertEqual(observed.declared.ownedBytes,Int64(data.count))
        let restore = try host.approveRestore(entryID:recycled.entryID,confirmed:true)
        let restored = try host.restore(grant:restore,key:Data("restore".utf8))
        XCTAssertEqual(restored.state,"completed"); XCTAssertNil(restored.error)
        observed = try inventory(host); XCTAssertTrue(observed.clean); XCTAssertEqual(observed.visible,[incoming.allocationID]); XCTAssertTrue(observed.retained.isEmpty)
        XCTAssertEqual(observed.declared.allocatedBytes,Int64(data.count)); XCTAssertEqual(observed.declared.historyCount,1)
        XCTAssertTrue(RecycleDirectory.sameStamp(original,try XCTUnwrap(directory.named(name)),allowingRenameCTime:true))
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(name)),data)
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_file_ownership WHERE baseline_stamp IS NOT NULL;"),[["1"]])
        try host.store.validate()
    }
    func testFull64MiBIncludingRetainedFilesRejectsBothUploadAndCopyBeforeNewStage() throws {
        let (root,host) = try physicalLab(), data = Data(repeating:0x42,count:16*1024*1024)
        var first: UUID?
        for n in 0..<4 {
            let value = try receive(host,data:data,key:"file-\(n)"); XCTAssertEqual(value.state,"owned"); XCTAssertNil(value.error)
            first = first ?? value.allocationID
        }
        let recycled = try host.recycle(grant:host.approveRecycle(allocationID:try XCTUnwrap(first),confirmed:true),key:Data("retained".utf8))
        XCTAssertEqual(recycled.state,"completed")
        host.revokeAll()
        let before = try host.store.contentDigest()
        denied(.budgetExceeded) { _ = try self.receive(host,data:Data([1]),key:"over") }
        let copy = try host.approveCopy(source:try XCTUnwrap(try inventory(host).visible.first),key:Data("copy-over".utf8),confirmed:true)
        denied(.budgetExceeded) { _ = try host.copy(grant:copy) }
        XCTAssertEqual(try host.store.contentDigest(),before)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:staging(root).path).isEmpty)
        XCTAssertEqual(try inventory(host).declared.allocatedBytes,67_108_864)
    }
    func testIdempotentOwnedRetryUsesTheSameIDWithoutAnotherPublication() throws {
        let (root,host) = try physicalLab(), first = try receive(host), name = first.allocationID.uuidString.lowercased()
        let directory = try RecycleDirectory(library(root)), before = try XCTUnwrap(directory.named(name)), digest = try host.store.contentDigest()
        let repeated = try receive(host)
        XCTAssertEqual(repeated.record,first.record); XCTAssertNil(repeated.error)
        XCTAssertEqual(try host.store.contentDigest(),digest); XCTAssertEqual(try directory.named(name),before)
        denied(.collision) { _ = try self.receive(host,data:Data("else".utf8)) }
    }
    func testUnarmedCancellationNeedsPositiveAbsenceAndCannotResurrectItsBusinessKey() throws {
        let (_,host) = try physicalLab()
        let value = try receive(host) { if $0 == .reserved { throw NASError.interrupted } }
        XCTAssertEqual(value.state,"reserved"); XCTAssertEqual(value.error,.interrupted)
        XCTAssertEqual(try inventory(host).declared.reservedBytes,4)
        let cancelled = try host.cancelUnarmed(grant:host.approveCancelIncoming(allocationID:value.allocationID,confirmed:true))
        XCTAssertEqual(cancelled.state,.cancelled)
        let repeated = try receive(host); XCTAssertEqual(repeated.allocationID,value.allocationID); XCTAssertEqual(repeated.state,"cancelled")
        XCTAssertEqual(try inventory(host).declared.allocatedBytes,0)
        try host.store.validate()
    }
    func testArmedFailureBeforeAnyStageStillCannotBeCancelledOrReadmitted() throws {
        let (root,host) = try physicalLab()
        let failed = try receive(host) { if $0 == .armed { throw NASError.interrupted } }
        XCTAssertEqual(failed.state,"armed"); XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath:staging(root).path).isEmpty)
        let digest = try host.store.contentDigest(), restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
        denied(.staleState) { _ = try restarted.cancelUnarmed(grant:restarted.approveCancelIncoming(allocationID:failed.allocationID,confirmed:true)) }
        denied(.staleState) { _ = try self.receive(restarted,key:"new") }
        XCTAssertEqual(try inventory(restarted).declared.unresolvedBytes,4); XCTAssertFalse(try inventory(restarted).clean)
        XCTAssertEqual(try host.store.contentDigest(),digest)
    }
    func testFailureAfterPublicationNeverAdoptsTheMatchingFileOrCreatesAnOwnershipProof() throws {
        let (root,host) = try physicalLab()
        let failed = try receive(host) { if $0 == .afterPublish { throw NASError.interrupted } }
        XCTAssertEqual(failed.state,"armed"); XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(failed.allocationID.uuidString.lowercased())),Data("data".utf8))
        let digest = try host.store.contentDigest(), restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
        denied(.staleState) { _ = try self.receive(restarted) }
        XCTAssertEqual(try host.store.contentDigest(),digest)
        XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_file_ownership WHERE baseline_stamp IS NULL;"),[["1"]])
        XCTAssertFalse(try inventory(restarted).clean); try host.store.validate()
    }
    func testSameBytesNewInodeAndUnknownNamesBlockAllWritesWithoutAdoption() throws {
        let (root,host) = try physicalLab(), first = try receive(host), url = library(root).appendingPathComponent(first.allocationID.uuidString.lowercased())
        let before = try host.store.contentDigest(), backup = child("original-owned-file")
        try FileManager.default.moveItem(at:url,to:backup)
        try Data("data".utf8).write(to:url); XCTAssertEqual(chmod(url.path,0o600),0)
        XCTAssertFalse(try inventory(host).clean)
        denied(.staleState) { _ = try self.receive(host,key:"another") }
        XCTAssertEqual(try host.store.contentDigest(),before)
        try FileManager.default.removeItem(at:url); try FileManager.default.moveItem(at:backup,to:url)
        XCTAssertTrue(try inventory(host).clean)
        try Data().write(to:library(root).appendingPathComponent("unregistered"))
        XCTAssertFalse(try inventory(host).clean)
        denied(.staleState) { _ = try self.receive(host,key:"unknown-blocked") }
    }
    func testRevocationDuringStagingPreservesFullArmedChargeAndPartialObject() throws {
        let (root,host) = try physicalLab()
        denied(.denied) { _ = try self.receive(host) { if $0 == .stagingCreated { host.revokeAll() } } }
        let row = try XCTUnwrap(try host.store.rows("SELECT allocation_id::text,state FROM macnas.capacity_allocations;").first)
        XCTAssertEqual(row[1],"armed")
        XCTAssertTrue(FileManager.default.fileExists(atPath:staging(root).appendingPathComponent(row[0]).path))
        let restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
        XCTAssertFalse(try inventory(restarted).clean); XCTAssertEqual(try inventory(restarted).declared.allocatedBytes,4)
        denied(.staleState) { _ = try self.receive(restarted,key:"blocked") }
    }
    func testLastGapReplacementAfterSyncLeavesArmedInsteadOfOwningAnotherInode() throws {
        let (root,host) = try physicalLab()
        let failed = try receive(host) { point in
            if point == .synced {
                let names = try FileManager.default.contentsOfDirectory(atPath:self.library(root).path), name = try XCTUnwrap(names.first)
                let url = self.library(root).appendingPathComponent(name)
                try FileManager.default.moveItem(at:url,to:self.child("real-published"))
                try Data("data".utf8).write(to:url); XCTAssertEqual(chmod(url.path,0o600),0)
            }
        }
        XCTAssertEqual(failed.state,"armed"); XCTAssertEqual(failed.error,.staleState)
        XCTAssertEqual(try host.store.rows("SELECT baseline_stamp IS NULL FROM macnas.capacity_file_ownership;"),[["t"]])
    }
    func testOldAuthorityAndMetadataOnlyPathsRefuseManagedTreeEvenWithMissingHostMarker() throws {
        let (root,host) = try physicalLab(), store = host.store, registry = host.registry, registration = host.registration
        let scope = FileEffectJournalScope(instanceID:registry.instanceID,generation:registry.generation,userID:owner,originScopeSHA256:registration.originScopeSHA256)
        denied(.unsupported) { _ = try FixtureRecycleAuthority(root:root,userID:self.owner) }
        denied(.unsupported) { _ = try DurableCapacityLedger(store:store,scope:scope,scopeID:registration.scopeID,libraryID:Data(registry.libraryID.utf8)) }
        denied(.unsupported) { _ = try DurableFileEffectJournal(store:store,scope:scope) }
        let marker = root.appendingPathComponent(FixturePhysicalCapacityNamespace.markerPath), saved = child("marker-backup")
        try FileManager.default.moveItem(at:marker,to:saved)
        denied(.unsupported) { _ = try FixtureRecycleAuthority(root:root,userID:self.owner) }
        denied(.unsupported) { _ = try DurableCapacityLedger(store:store,scope:scope,scopeID:registration.scopeID,libraryID:Data(registry.libraryID.utf8)) }
        denied(.unsupported) { _ = try DurableFileEffectJournal(store:store,scope:scope) }
        XCTAssertThrowsError(try FixturePhysicalCapacityNamespace(root:root,userID:owner))
    }
    func testPurposeAndRawActorBindingPreventCrossGrantAndRestoredHostUse() throws {
        let (root,host) = try physicalLab(), value = try receive(host)
        let read = try host.approveInspect(confirmed:true), before = try host.store.contentDigest()
        denied(.denied) { _ = try host.receive(Data(),grant:read) }
        denied(.denied) { _ = try host.recycle(grant:read,key:Data("wrong".utf8)) }
        let restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
        denied(.denied) { _ = try restarted.inspect(read) }
        let grant = try host.approveRecycle(allocationID:value.allocationID,confirmed:true)
        let authority = try FixtureRecycleAuthority(root:root,userID:owner,physicalAccess:host.legacyAccess(grant)), native = try authority.approve(.recycle,confirmed:true)
        denied(.denied) { _ = try FixtureRecycleCoordinator(authority:authority).preview(path:UUID().uuidString.lowercased(),grant:native) }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testReadOnlyRecoveryCanInspectButCannotApproveAnyWrite() throws {
        let (root,host) = try physicalLab(), value = try receive(host)
        let file = try SafeFS.resolve(root,"host-binding/binding.json"); var binding = try SafeFS.read(HostBinding.self,file)
        binding.mode = "read_only_recovery"; try SafeFS.write(binding,to:file); try host.store.setDefaultReadOnly()
        let restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner)
        XCTAssertTrue(try inventory(restarted).clean)
        denied(.denied) { _ = try restarted.approveRecycle(allocationID:value.allocationID,confirmed:true) }
        denied(.denied) { _ = try restarted.approveReceive(key:Data("write".utf8),bytes:0,sha256:TransferEncoding.digest(Data()),confirmed:true) }
    }
    func testCapacityHistoryRefusesExportWithoutChangingPhysicalPublication() throws {
        let (root,host) = try physicalLab(); _ = try receive(host)
        let output = child("forbidden-export"), files = try FileManager.default.contentsOfDirectory(atPath:library(root).path)
        denied(.unsupported) { try PortableInstance.export(from:root,to:output) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path)); XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:library(root).path),files)
        try host.store.validate()
    }
}
