import Foundation
import XCTest
@testable import MacNASCore

class RecycleObservationLab: RecycleVaultLab {
    func seed(_ root: URL, _ host: FixtureRecycleAuthority, bytes: Data = Data("keep".utf8), stop: RecycleCheckpoint? = nil) throws -> RecycleFilePreview {
        try bytes.write(to: library(root).appendingPathComponent("source"))
        let coordinator = FixtureRecycleCoordinator(authority: host), grant = try host.approve(.recycle, confirmed: true)
        let p = try coordinator.preview(path: "source", grant: grant)
        let result = try coordinator.commit(previewID: p.previewID, grant: grant, confirmed: true, key: Data(UUID().uuidString.utf8)) { if $0 == stop { throw NASError.interrupted } }
        XCTAssertEqual(result.state, stop == nil ? "completed" : "uncertain"); return p
    }
    func json(_ value: RecycleOperationObservation) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
final class RecycleObservationAPITests: RecycleObservationLab {
    private func cliObservation(root: URL, operationID: String, user: String, approved: Bool, request: Bool = true) throws -> (Int32, Data, String) {
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])).appendingPathComponent("macnas")
        process.arguments = ["bridge", "fixture", "--source", root.path, "--user", user] + (approved ? ["--approve-synthetic-recycle-observation"] : [])
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global()); timer.schedule(deadline: .now() + 120)
        timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume()
        defer { timer.cancel(); if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
        try process.run()
        if request {
            let frame: [String: Any] = ["apiVersion": 1, "requestId": UUID().uuidString, "method": "observeRecycleOperation", "params": ["operationID": operationID]]
            try input.fileHandleForWriting.write(contentsOf: JSONSerialization.data(withJSONObject: frame) + Data([10]))
        }
        try input.fileHandleForWriting.close()
        let bytes = try output.fileHandleForReading.readToEnd() ?? Data(); process.waitUntilExit()
        let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertLessThan(bytes.count, 8192); return (process.terminationStatus, bytes, String(decoding: diagnostics, as: UTF8.self))
    }
    func testMissingApprovalNeverOpensMissingVaultAndApprovedProjectionIsClosedAndReadOnly() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host)
        let preserved = child("preserved-vault"); try FileManager.default.moveItem(at: vault(root), to: preserved)
        let api = try PrototypePlatformAPI(root: root), owner = try api.beginFixtureSession(userID: "fixture-owner"), id = p.operationID.uuidString.lowercased()
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: owner) }
        denied(.denied) { try api.authorizeFixtureRecycleObservation(session: owner, confirmed: false) }
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true)
        denied(.unsafeFile) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: owner) }
        try FileManager.default.moveItem(at: preserved, to: vault(root)); let before = try host.store.contentDigest()
        let value = try api.observeFixtureRecycleOperation(operationID: id, session: owner), encoded = try json(value)
        XCTAssertEqual(value.classification, "matchedPost"); XCTAssertEqual(value.record?.entryID, p.entryID.uuidString.lowercased())
        XCTAssertEqual(Set(encoded.keys), ["observationVersion","operationID","visibility","record","classification"])
        let record = try XCTUnwrap(encoded["record"] as? [String: Any])
        XCTAssertEqual(Set(record.keys), ["operationID","entryID","kind","phase","revision","entryRevision","chargeState","chargedBytes","ownerUserHex","intentSHA256"])
        XCTAssertEqual(record["ownerUserHex"] as? String, FileEffectMetadata.hex(Data("fixture-owner".utf8)))
        let absent = try api.observeFixtureRecycleOperation(operationID: UUID().uuidString.lowercased(), session: owner)
        XCTAssertEqual(absent.visibility, "notVisible"); XCTAssertNil(absent.record); XCTAssertTrue(try json(absent)["record"] is NSNull)
        XCTAssertEqual(try host.store.contentDigest(), before); api.endSession(owner)
    }
    func testDifferentSessionReaderExplicitRevocationAndSessionEndCannotReuseApproval() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host), api = try PrototypePlatformAPI(root: root)
        let a = try api.beginFixtureSession(userID: "fixture-owner"), b = try api.beginFixtureSession(userID: "fixture-owner"), reader = try api.beginFixtureSession(userID: "fixture-family")
        let id = p.operationID.uuidString.lowercased(); try api.authorizeFixtureRecycleObservation(session: a, confirmed: true)
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: b) }
        denied(.denied) { try api.authorizeFixtureRecycleObservation(session: reader, confirmed: true) }
        api.revokeFixtureRecycleObservation(session: a)
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: a) }
        try api.authorizeFixtureRecycleObservation(session: a, confirmed: true); api.endSession(a)
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: a) }
        api.endSession(b); api.endSession(reader)
    }
    func testCurrentAnchorChangesFailBeforeAnyOldVaultAccessOrForeignDatabaseQuery() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"); try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true)
        let identityPath = root.appendingPathComponent("instance.json"), bindingPath = root.appendingPathComponent("host-binding/binding.json")
        let originalIdentity = try SafeFS.read(InstanceIdentity.self, identityPath), originalBinding = try SafeFS.read(HostBinding.self, bindingPath)
        let before = try host.store.contentDigest(), id = p.operationID.uuidString.lowercased()
        for variant in ["instance","generation","host","database"] {
            var identity = originalIdentity, binding = originalBinding
            if variant == "instance" { identity.instanceID = UUID() }
            if variant == "generation" { identity.generation += 1 }
            if variant == "host" { binding.hostID = "different-host" }
            if variant == "database" { binding.databaseName = "macnas_fixture_" + String(repeating: "0", count: 24) }
            try SafeFS.write(identity, to: identityPath); try SafeFS.write(binding, to: bindingPath)
            denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: id, session: owner) }
            try SafeFS.write(originalIdentity, to: identityPath); try SafeFS.write(originalBinding, to: bindingPath)
        }
        XCTAssertEqual(try host.store.contentDigest(), before); api.endSession(owner)
    }
    func testRawUnicodeAliasCannotBorrowTheConfiguredSubjectsApproval() throws {
        let root = child("unicode"); try PortableInstance.createSynthetic(at: root, databaseVersion: 4)
        let path = root.appendingPathComponent("config/platform.json"); var config = try SafeFS.read(PortableConfig.self, path)
        config.users = [.init(id: "é", role: "administrator")]; try SafeFS.write(config, to: path)
        let authority = try FixtureRecycleAuthority(root: root, userID: Data("é".utf8)); _ = try authority.createFreshFixture(confirmed: true)
        let api = try PrototypePlatformAPI(root: root), alias = try api.beginFixtureSession(userID: "e\u{301}"), exact = try api.beginFixtureSession(userID: "é")
        denied(.denied) { try api.authorizeFixtureRecycleObservation(session: alias, confirmed: true) }
        try api.authorizeFixtureRecycleObservation(session: exact, confirmed: true)
        XCTAssertEqual(try api.observeFixtureRecycleOperation(operationID: UUID().uuidString.lowercased(), session: exact).visibility, "notVisible")
        api.endSession(alias); api.endSession(exact)
    }
    func testAmbiguousRawSubjectAndReadOnlyModeDoNotInheritEarlierScope() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"); try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true)
        let path = root.appendingPathComponent("config/platform.json"); var config = try SafeFS.read(PortableConfig.self, path)
        config.users.append(.init(id: "fixture-owner", role: "reader")); try SafeFS.write(config, to: path)
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: p.operationID.uuidString.lowercased(), session: owner) }
        config.users.removeLast(); try SafeFS.write(config, to: path)
        let bindingPath = root.appendingPathComponent("host-binding/binding.json"); var binding = try SafeFS.read(HostBinding.self, bindingPath)
        binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: bindingPath)
        denied(.denied) { _ = try api.observeFixtureRecycleOperation(operationID: p.operationID.uuidString.lowercased(), session: owner) }
        api.endSession(owner)
    }
    func testFreshReadOnlyRecoveryApprovalProjectsUncertainPostWithoutSettlingOrChangingDigest() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host, stop: .observed)
        try host.store.setDefaultReadOnly(); let bindingPath = root.appendingPathComponent("host-binding/binding.json")
        var binding = try SafeFS.read(HostBinding.self, bindingPath); binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: bindingPath)
        let api = try PrototypePlatformAPI(root: root), owner = try api.beginFixtureSession(userID: "fixture-owner")
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true); let before = try host.store.contentDigest()
        let result = try api.observeFixtureRecycleOperation(operationID: p.operationID.uuidString.lowercased(), session: owner)
        XCTAssertEqual(result.classification, "matchedPost"); XCTAssertEqual(result.record?.phase, "uncertain"); XCTAssertEqual(result.record?.chargeState, "reserved")
        XCTAssertEqual(try host.store.contentDigest(), before); api.endSession(owner)
        // The public projection also has to describe an actually completed restore in a fresh read-only host.
        let (restoreRoot, restoreHost, _) = try recycleLab("restored-observation"), original = try seed(restoreRoot, restoreHost)
        let coordinator = FixtureRecycleCoordinator(authority: restoreHost)
        let restoreGrant = try restoreHost.approve(.restore, confirmed: true)
        let targetGrant = try restoreHost.approveRestoreDestination(parentPath: "", confirmed: true)
        let preview = try coordinator.previewRestore(entryID: original.entryID, parentPath: "", name: "restored", grant: restoreGrant, destinationGrant: targetGrant)
        XCTAssertEqual(try coordinator.commit(previewID: preview.previewID, grant: restoreGrant, confirmed: true, key: Data("restore-observation".utf8), destinationGrant: targetGrant).state, "completed")
        try restoreHost.store.setDefaultReadOnly()
        let restoredBinding = restoreRoot.appendingPathComponent("host-binding/binding.json")
        var nextBinding = try SafeFS.read(HostBinding.self, restoredBinding); nextBinding.mode = "read_only_recovery"; try SafeFS.write(nextBinding, to: restoredBinding)
        let restoredAPI = try PrototypePlatformAPI(root: restoreRoot), restoredOwner = try restoredAPI.beginFixtureSession(userID: "fixture-owner")
        try restoredAPI.authorizeFixtureRecycleObservation(session: restoredOwner, confirmed: true)
        let restoredBefore = try restoreHost.store.contentDigest()
        let restored = try restoredAPI.observeFixtureRecycleOperation(operationID: preview.operationID.uuidString.lowercased(), session: restoredOwner)
        XCTAssertEqual(restored.classification, "matchedPost"); XCTAssertEqual(restored.record?.kind, "restore")
        XCTAssertEqual(restored.record?.phase, "completed"); XCTAssertEqual(restored.record?.entryID, original.entryID.uuidString.lowercased())
        XCTAssertEqual(restored.record?.chargeState, "released"); XCTAssertEqual(restored.record?.chargedBytes, 0)
        XCTAssertEqual(try restoreHost.store.contentDigest(), restoredBefore)
        XCTAssertEqual(try Data(contentsOf: library(restoreRoot).appendingPathComponent("restored")), Data("keep".utf8))
        restoredAPI.endSession(restoredOwner)
    }
    func testFinalEncodingCheckRejectsEndedSessionAndChunkCheckStopsAnAlreadyStartedReader() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host, bytes: Data(repeating: 31, count: 128 * 1024)), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"); try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true)
        let before = try host.store.contentDigest()
        denied(.denied) {
            _ = try api.withFixtureRecycleOperationObservation(operationID: p.operationID.uuidString.lowercased(), session: owner) { value in api.endSession(owner); return try self.json(value) }
        }
        let next = try api.beginFixtureSession(userID: "fixture-owner"); try api.authorizeFixtureRecycleObservation(session: next, confirmed: true)
        let entry = try api.recycleObservationReads.entry(api.recycleObservationScope(next))
        let payload = try XCTUnwrap(try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries;").first?.first.flatMap(UUID.init(uuidString:)))
        var chunks = 0
        denied(.denied) {
            try entry.authority.withLockedVault(entry.grant, action: .observe) { permit in
                let source = try RecyclePinnedFile(source: permit.vault.slot(payload), name: "payload", validate: { try permit.check(.observe) })
                _ = try RecyclePinnedFile.digest(source.file, bytes: source.before.bytes) {
                    chunks += 1; if chunks == 3 { api.endSession(next) }; try permit.check(.observe)
                }
            }
        }
        XCTAssertEqual(chunks, 3); XCTAssertEqual(try host.store.contentDigest(), before)
    }
    func testApprovalBudgetIsBoundedAndEndingASessionFreesOnlyItsLocalEntry() throws {
        let (root, _, _) = try recycleLab(), api = try PrototypePlatformAPI(root: root)
        let sessions = try (0..<9).map { _ in try api.beginFixtureSession(userID: "fixture-owner") }
        for session in sessions.prefix(8) { try api.authorizeFixtureRecycleObservation(session: session, confirmed: true) }
        denied(.budgetExceeded) { try api.authorizeFixtureRecycleObservation(session: sessions[8], confirmed: true) }
        api.endSession(sessions[0]); try api.authorizeFixtureRecycleObservation(session: sessions[8], confirmed: true)
        try api.authorizeFixtureRecycleObservation(session: sessions[8], confirmed: true)
        for session in sessions { api.endSession(session) }
    }
    func testSchemaThreeAndNoncanonicalIDsCannotEnterObservation() throws {
        let root = child("schema3"); try PortableInstance.createSynthetic(at: root, databaseVersion: 3)
        let api = try PrototypePlatformAPI(root: root), owner = try api.beginFixtureSession(userID: "fixture-owner")
        denied(.unsupported) { try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true) }
        denied(.unsupported) { _ = try api.observeFixtureRecycleOperation(operationID: UUID().uuidString.lowercased(), session: owner) }
        denied(.invalidSchema) { _ = try api.observeFixtureRecycleOperation(operationID: "AAAAAAAA-0000-4000-8000-000000000001", session: owner) }
        api.endSession(owner)
    }
    func testBridgeAcceptsOnlyOperationIDAndCannotMintApprovalOrSettleAnEffect() throws {
        let (root, host, _) = try recycleLab(), p = try seed(root, host), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"), bridge = try DesktopBridge(api: api, session: owner)
        defer { bridge.close() }
        func request(_ method: String, _ params: [String: Any]) throws -> [String: Any] {
            let frame: [String: Any] = ["apiVersion": 1, "requestId": UUID().uuidString, "method": method, "params": params]
            return try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.handle(JSONSerialization.data(withJSONObject: frame))) as? [String: Any])
        }
        func error(_ value: [String: Any]) -> String? { (value["error"] as? [String: Any])?["code"] as? String }
        let id = p.operationID.uuidString.lowercased(), before = try host.store.contentDigest()
        XCTAssertEqual(error(try request("observeRecycleOperation", ["operationID": id])), "denied")
        XCTAssertEqual(error(try request("observeRecycleOperation", ["operationID": id, "confirmed": true])), "invalidInput")
        XCTAssertEqual(error(try request("observeRecycleOperation", ["operationID": id, "path": "/unapproved"])), "invalidInput")
        XCTAssertEqual(error(try request("authorizeFixtureRecycleObservation", ["confirmed": true])), "unsupported")
        XCTAssertEqual(error(try request("settleRecycleOperation", ["operationID": id])), "unsupported")
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true)
        let data = try XCTUnwrap(try request("observeRecycleOperation", ["operationID": id])["data"] as? [String: Any])
        XCTAssertEqual(Set(data.keys), ["observationEnvelopeVersion","context","observation"])
        let body = try XCTUnwrap(data["observation"] as? [String: Any])
        XCTAssertEqual(body["classification"] as? String, "matchedPost")
        XCTAssertEqual(error(try request("observeRecycleOperation", ["operationID": "AAAAAAAA-0000-4000-8000-000000000001"])), "invalidInput")
        // Exercise fresh CLI-owned sessions; the in-process approval cannot be inherited.
        for approved in [false, true] {
            let (status, bytes, diagnostics) = try cliObservation(root: root, operationID: id, user: "fixture-owner", approved: approved)
            XCTAssertEqual(status, 0, diagnostics)
            let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
            if approved {
                let envelope = try XCTUnwrap(reply["data"] as? [String: Any]), value = try XCTUnwrap(envelope["observation"] as? [String: Any])
                XCTAssertEqual(value["classification"] as? String, "matchedPost")
                XCTAssertEqual((value["record"] as? [String: Any])?["operationID"] as? String, id)
            } else { XCTAssertEqual(error(reply), "denied") }
        }
        let (readerStatus, readerOutput, readerError) = try cliObservation(root: root, operationID: id, user: "fixture-family", approved: true, request: false)
        XCTAssertEqual(readerStatus, 1); XCTAssertTrue(readerOutput.isEmpty); XCTAssertTrue(readerError.contains("macnas: denied"))
        XCTAssertEqual(try host.store.contentDigest(), before)
    }

    func testSourceMarkerRenewsWithinOneApprovalScopeButChangesWithSessionHostOrRegistration() throws {
        let (root, _, _) = try recycleLab(), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"), id = UUID().uuidString.lowercased()
        func context(_ api: PrototypePlatformAPI, _ session: PrototypeSession) throws -> RecycleObservationContext {
            try api.withBoundFixtureRecycleOperationObservation(operationID: id, session: session) { _, context in context }
        }
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true); let first = try context(api, owner)
        XCTAssertNotNil(first.scopeID.range(of: "^[0-9a-f]{64}$", options: .regularExpression))
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true); XCTAssertEqual(try context(api, owner), first)
        let other = try api.beginFixtureSession(userID: "fixture-owner"); try api.authorizeFixtureRecycleObservation(session: other, confirmed: true)
        XCTAssertNotEqual(try context(api, other).scopeID, first.scopeID)
        let restarted = try PrototypePlatformAPI(root: root), next = try restarted.beginFixtureSession(userID: "fixture-owner")
        try restarted.authorizeFixtureRecycleObservation(session: next, confirmed: true); XCTAssertNotEqual(try context(restarted, next).scopeID, first.scopeID)
        let path = root.appendingPathComponent(RecycleVault.registrationPath)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: path)) as? [String: Any])
        object["libraryID"] = "changed-logical-library"
        let registration = try FileEffectMetadata.decode(RecycleVaultRegistration.self, from: JSONSerialization.data(withJSONObject: object))
        let bytes = try FileEffectMetadata.encoded(registration); try bytes.write(to: path)
        try bytes.write(to: vault(root).appendingPathComponent("binding.json"))
        try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true); XCTAssertNotEqual(try context(api, owner).scopeID, first.scopeID)
        api.endSession(owner); api.endSession(other); restarted.endSession(next)
    }

}
