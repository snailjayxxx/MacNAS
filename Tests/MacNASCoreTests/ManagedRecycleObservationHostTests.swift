import Foundation
import Darwin
import XCTest
@testable import MacNASCore

/// Independent host boundaries and typed physical observations using TestLab only.
final class ManagedRecycleObservationHostTests: PhysicalCapacityLab {
    func context(_ api: PrototypePlatformAPI, _ session: PrototypeSession) throws -> CapacityLedgerReadContext {
        try api.fixtureManagedRecycleObservationContext(session: session)
    }
    func observe(_ api: PrototypePlatformAPI, _ session: PrototypeSession, _ c: CapacityLedgerReadContext,
                 _ id: UUID = UUID()) throws -> ManagedRecycleObservationView {
        try api.observeFixtureManagedRecycleOperation(scopeID: c.scopeID, sourceID: c.sourceID,
            operationID: id.uuidString.lowercased(), session: session)
    }
    func testSeparateApprovalCannotCreateOrAdoptScopeAndLedgerGrantDoesNotSubstitute() throws {
        let root = child("no-scope"); try PortableInstance.createSynthetic(at: root, databaseVersion: 6)
        let noScope = try PrototypePlatformAPI(root: root), s = try noScope.beginFixtureSession(userID: "fixture-owner")
        XCTAssertThrowsError(try noScope.authorizeFixtureManagedRecycleObservation(session: s, confirmed: true))
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(FixturePhysicalCapacityNamespace.markerPath).path))
        let (physical, host) = try physicalLab(), api = try PrototypePlatformAPI(root: physical)
        let session = try api.beginFixtureSession(userID: "fixture-owner"), before = try host.store.contentDigest()
        denied(.denied) { _ = try self.context(api, session) }
        denied(.denied) { try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: false) }
        try api.authorizeFixtureCapacityLedgerRead(session: session, confirmed: true)
        denied(.denied) { _ = try self.context(api, session) }
        let ledger = try host.approveLedgerRead(confirmed: true), inspect = try host.approveInspect(confirmed: true)
        for grant in [ledger, inspect] {
            denied(.denied) { _ = try host.withManagedObservationContext(grant) { true } }
            denied(.denied) { _ = try host.withManagedObservation(grant, operationID: UUID()) { _,_,_ in true } }
        }
        XCTAssertEqual(try host.store.contentDigest(), before)
    }
    func testFreshSourcePinsAPISessionAndGrantWhileUnknownRemainsExplicitNull() throws {
        let (root, host) = try physicalLab(), api = try PrototypePlatformAPI(root: root)
        let session = try api.beginFixtureSession(userID: "fixture-owner"), other = try api.beginFixtureSession(userID: "fixture-owner")
        let before = try host.store.contentDigest()
        try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true)
        let first = try context(api, session); XCTAssertEqual(try context(api, session), first)
        let unknown = try observe(api, session, first); XCTAssertNil(unknown.allocation); XCTAssertEqual(unknown.observation.visibility, "notVisible")
        denied(.denied) { _ = try self.observe(api, other, first) }
        try api.authorizeFixtureCapacityLedgerRead(session: session, confirmed: true)
        let ledger = try api.fixtureCapacityLedgerContext(session: session); XCTAssertNotEqual(first.sourceID, ledger.sourceID)
        denied(.denied) { _ = try self.observe(api, session, ledger) }
        try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true)
        let renewed = try context(api, session); XCTAssertNotEqual(first.sourceID, renewed.sourceID)
        denied(.denied) { _ = try self.observe(api, session, first) }
        api.revokeFixtureManagedRecycleObservation(session: session); denied(.denied) { _ = try self.context(api, session) }
        try api.authorizeFixtureManagedRecycleObservation(session: other, confirmed: true); api.endSession(other)
        denied(.denied) { _ = try self.context(api, other) }; XCTAssertEqual(try host.store.contentDigest(), before)
    }
    func testActualZeroAndSixteenMiBRecycleRestoreKeepOwnedChargeAndReadOnlyDigests() throws {
        for count in [0, 16 * 1024 * 1024] {
            let (root, host) = try physicalLab("bytes-\(count)"), data = Data(repeating: 0x61, count: count)
            let owned = try receive(host, data: data), recycle = try host.recycle(
                grant: host.approveRecycle(allocationID: owned.allocationID, confirmed: true), key: Data("recycle".utf8))
            XCTAssertEqual(recycle.state, "completed")
            let api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
            try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true); let c = try context(api, session)
            var before = try host.store.contentDigest(); let retained = try observe(api, session, c, recycle.operationID)
            XCTAssertEqual(retained.observation.classification, "matchedPost"); XCTAssertEqual(retained.allocation?.declaredBytes, Int64(count))
            XCTAssertEqual(retained.observation.record?.chargeState, "retained"); XCTAssertEqual(try host.store.contentDigest(), before)
            let restore = try host.restore(grant: host.approveRestore(entryID: recycle.entryID, confirmed: true), key: Data("restore".utf8))
            XCTAssertEqual(restore.state, "completed"); before = try host.store.contentDigest()
            for id in [recycle.operationID, restore.operationID] {
                let released = try observe(api, session, c, id)
                XCTAssertEqual(released.observation.record?.chargeState, "released"); XCTAssertEqual(released.observation.record?.chargedBytes, 0)
                XCTAssertEqual(released.allocation?.declaredBytes, Int64(count)); XCTAssertEqual(released.allocation?.state, "owned")
            }
            XCTAssertEqual(try host.store.contentDigest(), before)
            XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent(owned.allocationID.uuidString.lowercased())), data)
        }
    }
    func testChangedPayloadIsAmbiguousAndNeverAdoptedOrWritten() throws {
        let (root, host) = try physicalLab(), owned = try receive(host)
        let recycled = try host.recycle(grant: host.approveRecycle(allocationID: owned.allocationID, confirmed: true), key: Data("recycle".utf8))
        let api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
        try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true); let c = try context(api, session)
        let rows = try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries WHERE entry_id=\(FileEffectMetadata.uuidSQL(recycled.entryID));")
        let payloadID = try XCTUnwrap(rows.first?.first), path = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/entries/"+payloadID+"/payload")
        try Data("evil".utf8).write(to: path); let before = try host.store.contentDigest()
        let view = try observe(api, session, c, recycled.operationID)
        XCTAssertEqual(view.observation.classification, "ambiguous"); XCTAssertEqual(view.allocation?.sha256, owned.record?.sha256)
        XCTAssertEqual(try host.store.contentDigest(), before); XCTAssertEqual(try Data(contentsOf: path), Data("evil".utf8))
    }
    func testReadPurposeRejectsAllWritesSettlementInspectionAndLedgerList() throws {
        let (_, host) = try physicalLab(), read = try host.approveManagedObserve(confirmed: true)
        let access = try host.legacyAccess(read); try access.check(.observe)
        for action in [RecycleHostAction.recycle, .restore, .settle, .cancelPrepared, .restoreDestination] { denied(.denied) { try access.check(action) } }
        denied(.denied) { _ = try host.inspect(read) }; denied(.denied) { _ = try host.cancelUnarmed(grant: read) }
        denied(.denied) { _ = try host.withLedgerRead(read) { _ in true } }
        try host.withPermit(read) { permit in
            denied(.denied) { try permit.check(write: true) }
            denied(.denied) { _ = try permit.ledger().completeReadOnlyList(sourceID: String(repeating: "a", count: 64)) }
        }
    }
    func testRecoveryAllowsFreshObserveAndRejectsThePreviousModeAndReader() throws {
        let (root, host) = try physicalLab(), api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
        try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true); let old = try context(api, session)
        let path = root.appendingPathComponent("host-binding/binding.json"); var binding = try PortableInstance.strictRead(HostBinding.self, path)
        for mode in ["read_only_recovery", "rolled_back_recovery"] {
            binding.mode = mode; try SafeFS.write(binding, to: path); denied(.denied) { _ = try self.observe(api, session, old) }
            try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true)
            let c = try context(api, session), before = try host.store.contentDigest(); XCTAssertEqual(c.mode, mode)
            XCTAssertEqual(try observe(api, session, c).observation.visibility, "notVisible"); XCTAssertEqual(try host.store.contentDigest(), before)
        }
        let reader = try api.beginFixtureSession(userID: "fixture-family")
        denied(.denied) { try api.authorizeFixtureManagedRecycleObservation(session: reader, confirmed: true) }
    }
    func testFinalRenderingRevocationDatabaseBindingAndLockReplacementRefuseEncodedReply() throws {
        let (root, host) = try physicalLab(), api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
        for mutation in ["revoke", "binding", "lock"] {
            try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true); let c = try context(api, session)
            let lock = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/execution.lock"), saved = child("saved-"+mutation)
            XCTAssertThrowsError(try api.withFixtureManagedRecycleOperationObservation(scopeID: c.scopeID, sourceID: c.sourceID, operationID: UUID().uuidString.lowercased(), session: session) { view in
                if mutation == "revoke" { api.revokeFixtureManagedRecycleObservation(session: session) }
                if mutation == "binding" { try host.store.execute("UPDATE macnas.physical_capacity_scopes SET owner_uid=owner_uid+1;") }
                if mutation == "lock" { try FileManager.default.moveItem(at: lock, to: saved); try Data().write(to: lock); XCTAssertEqual(chmod(lock.path, 0o600), 0) }
                return try JSONEncoder().encode(view)
            }, mutation)
            if mutation == "binding" { try host.store.execute("UPDATE macnas.physical_capacity_scopes SET owner_uid=\(getuid());") }
            if mutation == "lock" { try FileManager.default.removeItem(at: lock); try FileManager.default.moveItem(at: saved, to: lock) }
        }
    }
    func testExpiredAndCrossScopeSourceRefuseWithoutChangingAnyTable() throws {
        let (root, host) = try physicalLab(), api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
        var now: TimeInterval = 10; try api.authorizeManagedRecycleObservation(session: session, confirmed: true, now: { now })
        let c = try context(api, session), before = try host.store.contentDigest()
        denied(.denied) { _ = try api.observeFixtureManagedRecycleOperation(scopeID: UUID().uuidString.lowercased(), sourceID: c.sourceID, operationID: UUID().uuidString.lowercased(), session: session) }
        denied(.denied) { _ = try api.observeFixtureManagedRecycleOperation(scopeID: c.scopeID, sourceID: String(repeating: "0", count: 64), operationID: UUID().uuidString.lowercased(), session: session) }
        now = 1811; denied(.expired) { _ = try self.observe(api, session, c) }; XCTAssertEqual(try host.store.contentDigest(), before)
    }
    func testPostgreSQLCanonicalIntentDigestIsVerifiedWithoutCompactSwiftRehash() throws {
        let (root,host) = try physicalLab(), owned = try receive(host)
        let recycled = try host.recycle(grant:host.approveRecycle(allocationID:owned.allocationID,confirmed:true),key:Data("recycle".utf8))
        XCTAssertEqual(recycled.state,"completed")
        let rows = try host.store.rows("SELECT intent_sha256,encode(sha256(convert_to(intent::text,'UTF8')),'hex'),intent::text FROM macnas.file_effect_operations WHERE operation_id=\(FileEffectMetadata.uuidSQL(recycled.operationID));")
        let row = try XCTUnwrap(rows.first); XCTAssertEqual(row.count,3); XCTAssertEqual(row[0],row[1])
        let intent = try JSONDecoder().decode(FileEffectIntent.self,from:Data(row[2].utf8)), compact = try TransferEncoding.digest(FileEffectMetadata.encoded(intent))
        XCTAssertNotEqual(row[0],compact)
        print("Managed canonical intent proof: "+String(decoding:try JSONSerialization.data(withJSONObject:["stored":row[0],"postgresCanonical":row[1],"swiftCompact":compact],options:[.sortedKeys]),as:UTF8.self))
        let api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner")
        try api.authorizeFixtureManagedRecycleObservation(session:session,confirmed:true); let c = try context(api,session), before = try host.store.contentDigest()
        XCTAssertEqual(try observe(api,session,c,recycled.operationID).observation.record?.intentSHA256,row[0])
        XCTAssertEqual(try host.store.contentDigest(),before)
        XCTAssertThrowsError(try host.store.execute("UPDATE macnas.file_effect_operations SET intent_sha256=repeat('0',64) WHERE operation_id=\(FileEffectMetadata.uuidSQL(recycled.operationID));"))
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testStrictDesktopMessagesCannotIssueApprovalOrAcceptExtraParams() throws {
        let (root, _) = try physicalLab(), api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
        let bridge = try DesktopBridge(api: api, session: session); defer { bridge.close() }
        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.handle(JSONSerialization.data(withJSONObject:
                ["apiVersion": 1, "requestId": UUID().uuidString, "method": method, "params": params]))) as? [String: Any])
        }
        for (method, params) in [("managedRecycleObservationContext", ["confirmed": true]), ("observeManagedRecycleOperation", ["operationID": UUID().uuidString.lowercased()]), ("authorizeFixtureManagedRecycleObservation", [:])] { XCTAssertNotNil(try request(method, params)["error"]) }
        XCTAssertEqual((try request("managedRecycleObservationContext", [:])["error"] as? [String: Any])?["code"] as? String, "denied")
        try api.authorizeFixtureManagedRecycleObservation(session: session, confirmed: true)
        let c = try context(api, session), response = try request("observeManagedRecycleOperation", ["scopeID": c.scopeID, "sourceID": c.sourceID, "operationID": UUID().uuidString.lowercased()])
        XCTAssertEqual((response["data"] as? [String: Any])?["managedObservationVersion"] as? Int, 1)
    }
}
