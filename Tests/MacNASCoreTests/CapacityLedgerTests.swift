import Foundation
import XCTest
@testable import MacNASCore

class CapacityLedgerLab: FileEffectJournalLab {
    let capacityHash = String(repeating: "c", count: 64)
    func capacityFixture(_ name: String = "capacity") throws -> (URL, StateStore, DurableCapacityLedger, FileEffectJournalScope) {
        let root = child(name); try PortableInstance.createSynthetic(at: root, databaseVersion: 5)
        let store = try PortableInstance.store(root), identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(root,"instance.json"))
        let scope = FileEffectJournalScope(instanceID: identity.instanceID, generation: Int64(identity.generation),
            userID: Data("fixture-owner".utf8), originScopeSHA256: capacityHash)
        let ledger = try DurableCapacityLedger(store: store, scope: scope, scopeID: UUID(), libraryID: Data("metadata-library".utf8))
        return (root,store,ledger,scope)
    }
    func reserve(_ ledger: DurableCapacityLedger, _ key: String = "incoming", bytes: Int64 = 4, origin: CapacityOrigin = .upload) throws -> CapacityAllocation {
        try ledger.reserve(origin: origin, key: Data(key.utf8), intentSHA256: capacityHash, bytes: bytes)
    }
    func owned(_ ledger: DurableCapacityLedger, _ key: String, bytes: Int64) throws -> CapacityAllocation {
        let r = try reserve(ledger,key,bytes:bytes,origin:.initial)
        let armed = try ledger.armMetadataOnly(r.allocationID,revision:r.revision)
        return try ledger.markOwnedMetadataOnly(r.allocationID,revision:armed.revision,sha256:capacityHash)
    }
}

private final class CapacityConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var records: [CapacityAllocation] = []
    private(set) var errors: [NASError] = []
    func record(_ value: CapacityAllocation) { lock.lock(); defer { lock.unlock() }; records.append(value) }
    func error(_ value: Error) { lock.lock(); defer { lock.unlock() }; errors.append(value as? NASError ?? .integrity) }
}

private final class MetadataConcurrentResults: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var successes: [String] = []
    private(set) var errors: [NASError] = []
    func record(_ value: String) { lock.lock(); defer { lock.unlock() }; successes.append(value) }
    func error(_ value: Error) { lock.lock(); defer { lock.unlock() }; errors.append(value as? NASError ?? .integrity) }
}

final class CapacityLedgerTests: CapacityLedgerLab {
    func testScopeRequiresConfirmationAndNeverCreatesPhysicalFiles() throws {
        let (root,store,ledger,_) = try capacityFixture()
        do { let lock = try InstanceLock(root,mode:.shared); withExtendedLifetime(lock) {} }
        let before = try SafeFS.files(root)
        XCTAssertFalse(try store.hasCapacityHistory())
        denied(.denied) { _ = try ledger.createMetadataScope(confirmed:false) }
        XCTAssertFalse(try store.hasCapacityHistory())
        XCTAssertEqual(try ledger.createMetadataScope(confirmed:true),ledger.scopeID)
        XCTAssertEqual(try ledger.createMetadataScope(confirmed:true),ledger.scopeID)
        XCTAssertTrue(try store.hasCapacityHistory()); XCTAssertFalse(try store.hasRecycleHistory())
        XCTAssertEqual(try SafeFS.files(root),before)
        XCTAssertEqual(try ledger.totals().allocatedBytes,0)
        denied(.unsupported) { try store.requirePortableRecycleEmpty() }
    }
    func testPersistentReservationSurvivesLedgerAndSQLConnectionRecreation() throws {
        let (root,store,ledger,scope) = try capacityFixture()
        _ = try ledger.createMetadataScope(confirmed:true)
        let r = try reserve(ledger,bytes:123)
        let second = try DurableCapacityLedger(store:StateStore(databaseName:store.databaseName,instanceRoot:root),scope:scope,scopeID:ledger.scopeID,libraryID:Data("metadata-library".utf8))
        XCTAssertEqual(try second.allocation(r.allocationID),r)
        XCTAssertEqual(try second.totals().allocatedBytes,123)
        let before = try store.contentDigest()
        _ = try second.totals(); _ = try second.allocation(UUID())
        XCTAssertEqual(try store.contentDigest(),before)
    }
    func testIdempotencyPreservesOriginalIDsAndRejectsDifferentDeclaration() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let first = try reserve(ledger), repeated = try reserve(ledger)
        XCTAssertEqual(first,repeated)
        denied(.collision) { _ = try self.reserve(ledger,bytes:5) }
        denied(.collision) { _ = try ledger.reserve(origin:.upload,key:Data("incoming".utf8),intentSHA256:String(repeating:"d",count:64),bytes:4) }
        _ = try ledger.cancelUnarmedMetadataOnly(first.allocationID,revision:first.revision)
        XCTAssertEqual(try reserve(ledger).state,.cancelled)
        XCTAssertEqual(try ledger.totals().allocatedBytes,0)
        XCTAssertEqual(try ledger.totals().historyCount,1)
        try store.validate()
    }
    func testUnicodeKeysAreComparedAsRawUTF8AndOriginsHaveSeparateKeys() throws {
        let (_,_,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let a = try reserve(ledger,"é"), b = try reserve(ledger,"e\u{301}"), c = try reserve(ledger,"é",origin:.copy)
        XCTAssertNotEqual(a.allocationID,b.allocationID); XCTAssertNotEqual(a.allocationID,c.allocationID)
        XCTAssertEqual(try ledger.totals().historyCount,3)
    }
    func testConcurrentUploadAndCopyCannotSpendTheSameRemainingCapacity() throws {
        let (root,store,ledger,scope) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        for n in 0..<3 { _ = try owned(ledger,"seed\(n)",bytes:DurableCapacityLedger.fileLimit) }
        let results = CapacityConcurrentResults(), group = DispatchGroup(), database = store.databaseName, scopeID = ledger.scopeID
        for origin in [CapacityOrigin.upload,.copy] {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let other = try DurableCapacityLedger(store:StateStore(databaseName:database,instanceRoot:root),scope:scope,scopeID:scopeID,libraryID:Data("metadata-library".utf8))
                    results.record(try other.reserve(origin:origin,key:Data("race".utf8),intentSHA256:scope.originScopeSHA256,bytes:DurableCapacityLedger.fileLimit))
                } catch { results.error(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+30),.success)
        XCTAssertEqual(results.records.count,1); XCTAssertEqual(results.errors,[.budgetExceeded])
        XCTAssertEqual(try ledger.totals().allocatedBytes,DurableCapacityLedger.byteLimit)
        try store.validate()
    }
    func testUncertainArmedReservationBlocksNewAdmissionAcrossRestartAndCannotBeCancelled() throws {
        let (root,store,ledger,scope) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let first = try reserve(ledger,bytes:0), armed = try ledger.armMetadataOnly(first.allocationID,revision:1)
        denied(.staleState) { _ = try ledger.cancelUnarmedMetadataOnly(first.allocationID,revision:armed.revision) }
        denied(.staleState) { _ = try self.reserve(ledger,"second",bytes:0) }
        let restarted = try DurableCapacityLedger(store:store,scope:scope,scopeID:ledger.scopeID,libraryID:Data("metadata-library".utf8))
        XCTAssertEqual(try restarted.totals().unresolvedCount,1)
        XCTAssertEqual(try restarted.allocation(first.allocationID)?.state,.armed)
        denied(.staleState) { _ = try self.reserve(restarted,"after-restart") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("host-binding/recycle-fixture").path))
    }
    func testOwnedBytesNeverReleaseAndCancelledUnarmedBytesDoRelease() throws {
        let (_,_,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let first = try owned(ledger,"first",bytes:16_777_216)
        denied(.staleState) { _ = try ledger.cancelUnarmedMetadataOnly(first.allocationID,revision:first.revision) }
        let pending = try reserve(ledger,"second",bytes:16_777_216)
        XCTAssertEqual(try ledger.totals().allocatedBytes,33_554_432)
        _ = try ledger.cancelUnarmedMetadataOnly(pending.allocationID,revision:1)
        XCTAssertEqual(try ledger.totals().allocatedBytes,16_777_216)
        XCTAssertEqual(try ledger.totals().ownedBytes,16_777_216)
    }
    func testIndependentCASRejectsStaleTransitionsWithoutChangingTotals() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let first = try reserve(ledger), armed = try ledger.armMetadataOnly(first.allocationID,revision:1)
        let before = try store.contentDigest()
        denied(.staleState) { _ = try ledger.armMetadataOnly(first.allocationID,revision:1) }
        denied(.staleState) { _ = try ledger.markOwnedMetadataOnly(first.allocationID,revision:1,sha256:self.capacityHash) }
        XCTAssertEqual(try store.contentDigest(),before)
        let owned = try ledger.markOwnedMetadataOnly(first.allocationID,revision:armed.revision,sha256:capacityHash)
        XCTAssertEqual(owned.revision,3); XCTAssertEqual(try ledger.totals().allocatedBytes,4)
        denied(.staleState) { _ = try ledger.markOwnedMetadataOnly(first.allocationID,revision:2,sha256:self.capacityHash) }
    }
    func testHistoryAndActiveLimitsCountZeroByteAndCancelledRecords() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        var records:[CapacityAllocation] = []
        for n in 0..<8 { records.append(try reserve(ledger,"\(n)",bytes:0)) }
        denied(.budgetExceeded) { _ = try self.reserve(ledger,"ninth",bytes:0) }
        for r in records { _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:1) }
        for n in 8..<64 {
            let r = try reserve(ledger,"\(n)",bytes:0)
            _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:1)
        }
        denied(.budgetExceeded) { _ = try self.reserve(ledger,"sixty-five",bytes:0) }
        XCTAssertEqual(try ledger.totals().historyCount,64); XCTAssertEqual(try ledger.totals().allocatedBytes,0)
        try store.validate()
    }
    func testScopeAliasesAndChangedOriginCannotCreateAnotherBudget() throws {
        let (_,store,ledger,scope) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true); _ = try reserve(ledger)
        let other = try DurableCapacityLedger(store:store,scope:scope,scopeID:UUID(),libraryID:Data("other-alias".utf8))
        denied(.collision) { _ = try other.createMetadataScope(confirmed:true) }
        denied(.denied) { _ = try self.reserve(other) }
        denied(.denied) { _ = try other.totals() }
        let changed = FileEffectJournalScope(instanceID:scope.instanceID,generation:scope.generation,userID:scope.userID,originScopeSHA256:String(repeating:"d",count:64))
        let stale = try DurableCapacityLedger(store:store,scope:changed,scopeID:ledger.scopeID,libraryID:Data("metadata-library".utf8))
        denied(.collision) { _ = try stale.createMetadataScope(confirmed:true) }
        XCTAssertEqual(try ledger.totals().allocatedBytes,4)
    }
    func testRoleDuplicatesAndInstanceOrHostRebindingFailClosed() throws {
        let (root,_,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let configFile = try SafeFS.resolve(root,"config/platform.json"), originalConfig = try SafeFS.read(PortableConfig.self,configFile)
        var config = originalConfig; config.users.append(config.users[0]); try SafeFS.write(config,to:configFile)
        denied(.denied) { _ = try self.reserve(ledger) }; try SafeFS.write(originalConfig,to:configFile)
        let bindingFile = try SafeFS.resolve(root,"host-binding/binding.json"), originalBinding = try SafeFS.read(HostBinding.self,bindingFile)
        var binding = originalBinding; binding.hostID = "rebound"; try SafeFS.write(binding,to:bindingFile)
        denied(.denied) { _ = try ledger.totals() }; try SafeFS.write(originalBinding,to:bindingFile)
        let identityFile = try SafeFS.resolve(root,"instance.json"); var identity = try SafeFS.read(InstanceIdentity.self,identityFile)
        identity.generation += 1; try SafeFS.write(identity,to:identityFile)
        denied(.denied) { _ = try self.reserve(ledger) }
    }
    func testReadOnlyRecoveryCanObserveButCannotMutateCapacity() throws {
        let (root,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true); let r = try reserve(ledger)
        let file = try SafeFS.resolve(root,"host-binding/binding.json"); var binding = try SafeFS.read(HostBinding.self,file)
        binding.mode = "read_only_recovery"; try SafeFS.write(binding,to:file); try store.setDefaultReadOnly()
        XCTAssertEqual(try ledger.allocation(r.allocationID),r); XCTAssertEqual(try ledger.totals().allocatedBytes,4)
        denied(.denied) { _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:1) }
    }
    func testReservedPostStateBudgetAllowsOwnedTransitionAfterLegacyMetadataGrows() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let r = try reserve(ledger), armed = try ledger.armMetadataOnly(r.allocationID,revision:1)
        try store.execute("UPDATE macnas.jobs SET checkpoint=jsonb_build_object('large',repeat('x',4001000));")
        let result = try ledger.markOwnedMetadataOnly(r.allocationID,revision:armed.revision,sha256:capacityHash)
        XCTAssertEqual(result.state,.owned); XCTAssertEqual(try ledger.totals().allocatedBytes,4)
        denied(.budgetExceeded) { _ = try store.contentDigest() }
        denied(.budgetExceeded) { _ = try self.reserve(ledger,"over-metadata") }
        XCTAssertEqual(try ledger.totals().historyCount,1)
    }
    func testInvalidInputsAndIDCollisionPreserveEntireDatabase() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let first = try reserve(ledger), before = try store.contentDigest()
        for bytes in [Int64(-1),16_777_217,Int64.max] { denied(.budgetExceeded) { _ = try self.reserve(ledger,"bad",bytes:bytes) } }
        for key in [Data(),Data([0]),Data([255]),Data(repeating:65,count:129),Data(repeating:65,count:257)] {
            XCTAssertThrowsError(try ledger.reserve(origin:.upload,key:key,intentSHA256:capacityHash,bytes:0))
        }
        denied(.collision) { _ = try ledger.reserve(origin:.copy,key:Data("id-collision".utf8),intentSHA256:self.capacityHash,bytes:0,allocationID:first.allocationID) }
        XCTAssertEqual(try store.contentDigest(),before)
    }
    func testFreshLedgerCannotAdoptScopeAfterHostRebinding() throws {
        let (root,store,ledger,scope) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        _ = try reserve(ledger)
        let before = try store.contentDigest(), file = try SafeFS.resolve(root,"host-binding/binding.json")
        var binding = try SafeFS.read(HostBinding.self,file); binding.hostID = "fresh-host"; try SafeFS.write(binding,to:file)
        let fresh = try DurableCapacityLedger(store:store,scope:scope,scopeID:ledger.scopeID,libraryID:Data("metadata-library".utf8))
        denied(.collision) { _ = try fresh.createMetadataScope(confirmed:true) }
        denied(.denied) { _ = try fresh.totals() }
        XCTAssertEqual(try store.contentDigest(),before)
    }
    func testMetadataOnlyMethodsRefusePhysicalRegistrationMarker() throws {
        let (root,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let r = try reserve(ledger), before = try store.contentDigest()
        try Data("{}".utf8).write(to:SafeFS.resolve(root,"host-binding/capacity-registration.json"))
        denied(.unsupported) { _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:r.revision) }
        XCTAssertEqual(try store.contentDigest(),before)
    }
    func testWorstCaseRawSubjectHostLibraryAndBusinessKeyFitReservedRowBudgets() throws {
        let (root,store,_,oldScope) = try capacityFixture()
        let configFile = try SafeFS.resolve(root,"config/platform.json"); var config = try SafeFS.read(PortableConfig.self,configFile)
        config.users[0].id = String(repeating:"o",count:128); try SafeFS.write(config,to:configFile)
        let bindingFile = try SafeFS.resolve(root,"host-binding/binding.json"); var binding = try SafeFS.read(HostBinding.self,bindingFile)
        binding.hostID = String(repeating:"h",count:256); try SafeFS.write(binding,to:bindingFile)
        let scope = FileEffectJournalScope(instanceID:oldScope.instanceID,generation:oldScope.generation,userID:Data(config.users[0].id.utf8),originScopeSHA256:capacityHash)
        let ledger = try DurableCapacityLedger(store:store,scope:scope,scopeID:UUID(),libraryID:Data(repeating:108,count:128))
        _ = try ledger.createMetadataScope(confirmed:true)
        let r = try ledger.reserve(origin:.copy,key:Data(repeating:107,count:128),intentSHA256:capacityHash,bytes:16_777_216)
        let armed = try ledger.armMetadataOnly(r.allocationID,revision:1)
        _ = try ledger.markOwnedMetadataOnly(r.allocationID,revision:armed.revision,sha256:capacityHash)
        XCTAssertEqual(try store.rows("SELECT (SELECT max(octet_length(to_jsonb(s)::text))<=3072 FROM macnas.capacity_scopes s),(SELECT max(octet_length(to_jsonb(a)::text))<=2048 FROM macnas.capacity_allocations a);"),[["t","t"]])
        try store.validate()
    }

    func testConcurrentCapacityAndJournalAdmissionsReserveOneMetadataBudget() throws {
        let (root,store,ledger,scope) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        // These remain separate metadata models; only their shared metadata budget is
        // exercised here. No physical inventory, publication, recycle or restore occurs.
        try store.execute("UPDATE macnas.jobs SET checkpoint=jsonb_build_object('large','');")
        let empty = try XCTUnwrap(Int(store.rows("SELECT (\(StateStore.legacyMetadataBytesSQL));")[0][0]))
        let padding = 3_979_000-empty
        try store.execute("UPDATE macnas.jobs SET checkpoint=jsonb_build_object('large',repeat('x',\(padding)));")
        XCTAssertEqual(try store.rows("SELECT (\(StateStore.legacyMetadataBytesSQL));"),[["3979000"]])
        let results = MetadataConcurrentResults(), group = DispatchGroup(), database = store.databaseName, scopeID = ledger.scopeID
        let intent = journalIntent("metadata-budget"), evidence = journalEvidence(bytes:0), hash = capacityHash
        let volume = journalVolumeID, vault = journalVaultID
        for number in 0..<2 {
            group.enter(); DispatchQueue.global().async {
                defer { group.leave() }
                do {
                    let db = try StateStore(databaseName:database,instanceRoot:root)
                    if number == 0 {
                        let capacity = try DurableCapacityLedger(store:db,scope:scope,scopeID:scopeID,libraryID:Data("metadata-library".utf8))
                        _ = try capacity.reserve(origin:.upload,key:Data("budget-race".utf8),intentSHA256:hash,bytes:0)
                        results.record("capacity")
                    } else {
                        let journal = try DurableFileEffectJournal(store:db,scope:scope)
                        _ = try journal.prepareRecycle(key:Data("budget-race".utf8),intent:intent,volumeID:volume,vaultID:vault,byteCount:0,evidence:evidence)
                        results.record("journal")
                    }
                } catch { results.error(error) }
            }
        }
        XCTAssertEqual(group.wait(timeout:.now()+45),.success)
        XCTAssertEqual(results.successes.count,1); XCTAssertEqual(results.errors,[.budgetExceeded])
        XCTAssertNoThrow(try store.contentDigest()); try store.validate()
    }
}
