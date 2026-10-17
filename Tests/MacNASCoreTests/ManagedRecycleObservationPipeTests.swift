import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class ManagedRecycleObservationPipeTests: PhysicalCapacityLab {
    func payloadSHA256(_ root: URL) throws -> [String:String] {
        var hashes: [String:String] = [:]
        for (prefix,base) in [("visible",library(root)),("retained",root.appendingPathComponent(RecycleVault.fixturePath+"/vault/entries")),("staging",staging(root))] {
            for relative in try SafeFS.files(base) { hashes[prefix+"/"+relative] = try SafeFS.digest(base.appendingPathComponent(relative)) }
        }
        return hashes
    }
    func runPipe(_ root: URL, _ host: FixturePhysicalCapacityNamespace, _ api: PrototypePlatformAPI,
                 _ session: PrototypeSession, _ bridge: DesktopBridge, operationID: UUID, approved: Bool, label: String) throws {
        let before = try host.store.contentDigest(), payloadBefore = try payloadSHA256(root)
        var expected: [String:Any] = [:]
        if approved {
            let c = try api.fixtureManagedRecycleObservationContext(session: session)
            let v = try api.observeFixtureManagedRecycleOperation(scopeID: c.scopeID, sourceID: c.sourceID, operationID: operationID.uuidString.lowercased(), session: session)
            let classifications = ["unknown-explicit-null":"notVisible", "zero-retained":"matchedPost", "16MiB-retained":"matchedPost", "64MiB-scope-retained":"matchedPost", "released-entry-owned-still-charged":"matchedPost", "fresh-recovery-observation":"matchedPost", "changed-payload-is-ambiguous":"ambiguous", "candidateMoved-not-settled":"candidateMoved"]
            XCTAssertEqual(v.observation.classification, try XCTUnwrap(classifications[label]), label)
            XCTAssertEqual(c.scopeID, host.registration.scopeID.uuidString.lowercased())
            let recovery = ["fresh-recovery-observation","changed-payload-is-ambiguous"].contains(label)
            XCTAssertEqual(c.mode, recovery ? "read_only_recovery":"synthetic_development", label)
            if label == "unknown-explicit-null" {
                XCTAssertEqual(v.observation.visibility,"notVisible"); XCTAssertNil(v.observation.record); XCTAssertNil(v.allocation)
            } else {
                let amounts: [String:(Int64,String,Int64)] = ["zero-retained":(0,"retained",0), "16MiB-retained":(16777216,"retained",16777216), "64MiB-scope-retained":(16777216,"retained",16777216), "released-entry-owned-still-charged":(16777216,"released",0), "fresh-recovery-observation":(16777216,"released",0), "changed-payload-is-ambiguous":(0,"retained",0), "candidateMoved-not-settled":(4,"reserved",4)]
                let a = try XCTUnwrap(amounts[label]), allocation = try XCTUnwrap(v.allocation), record = try XCTUnwrap(v.observation.record)
                XCTAssertEqual(v.observation.visibility,"visible"); XCTAssertEqual(allocation.declaredBytes,a.0,label)
                XCTAssertEqual(record.chargeState,a.1,label); XCTAssertEqual(record.chargedBytes,a.2,label)
                XCTAssertEqual(allocation.origin,label == "64MiB-scope-retained" ? "copy":"upload",label)
                XCTAssertEqual(record.phase,label == "candidateMoved-not-settled" ? "uncertain":"completed",label)
                XCTAssertEqual(record.kind,["released-entry-owned-still-charged","fresh-recovery-observation"].contains(label) ? "restore":"recycle",label)
            }
            expected = ["scopeID": c.scopeID, "sourceID": c.sourceID, "mode": c.mode, "operationID": operationID.uuidString.lowercased(), "visibility": v.observation.visibility, "classification": v.observation.classification]
            if let row = v.allocation, let r = v.observation.record {
                expected.merge(["allocationID": row.allocationID, "entryID": r.entryID, "ownedBytes": row.declaredBytes, "origin": row.origin, "entryChargeState": r.chargeState, "entryChargedBytes": r.chargedBytes]) { _, b in b }
            }
        }
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"]))
        process.arguments = [repo.appendingPathComponent("scripts/test_managed_recycle_observation_bridge.cjs").path, approved ? "approved":"denied", String(decoding:try JSONSerialization.data(withJSONObject:expected,options:[.sortedKeys]),as:UTF8.self)]
        process.currentDirectoryURL = repo; process.environment = ["LANG":"C","LC_ALL":"C"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        // Keep a closed child pipe observable as EPIPE on this one descriptor.
        // Do not change process-wide SIGPIPE behavior or client/test deadlines.
        try require(fcntl(input.fileHandleForWriting.fileDescriptor,F_SETNOSIGPIPE,1) == 0,.unsafeFile)
        let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global()); timer.schedule(deadline:.now()+120)
        timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume()
        defer { timer.cancel(); if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
        try process.run(); var frame = Data(), requests = 0, pumpError: Error?, timings: [[String:Any]] = []
        do {
            while true {
                let block = output.fileHandleForReading.availableData; if block.isEmpty { break }; frame.append(block)
                try require(frame.count <= 65536, .budgetExceeded)
                while let end = frame.firstIndex(of:10) {
                    requests += 1; try require(requests <= 16, .budgetExceeded)
                    let request = Data(frame[..<end]), started = ProcessInfo.processInfo.systemUptime
                    let method = (try? JSONSerialization.jsonObject(with:request) as? [String:Any])?["method"] as? String ?? "invalid"
                    let reply = bridge.handle(request); frame.removeSubrange(...end)
                    let timing: [String:Any] = ["scenario":label,"request":requests,"method":method,"seconds":ProcessInfo.processInfo.systemUptime-started]
                    timings.append(timing)
                    try input.fileHandleForWriting.write(contentsOf:reply+Data([10]))
                }
            }
        } catch {
            pumpError = error
            if process.isRunning { process.terminate() }
        }
        process.waitUntilExit(); let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
        let diagnosticText = String(decoding:diagnostics,as:UTF8.self)
        XCTAssertTrue(frame.isEmpty); XCTAssertEqual(process.terminationStatus, 0, label+": "+diagnosticText)
        if let pumpError {
            FileHandle.standardError.write(Data(("Managed pipe child failure: "+label+"\n"+diagnosticText+"\n"+String(decoding:try JSONSerialization.data(withJSONObject:timings,options:[.sortedKeys]),as:UTF8.self)+"\n").utf8))
            throw pumpError
        }
        XCTAssertEqual(requests, approved ? 5:2)
        XCTAssertTrue(String(decoding:diagnostics,as:UTF8.self).contains("managed-observation-pipe: PASS "+(approved ? "approved":"denied")))
        let after = try host.store.contentDigest(), payloadAfter = try payloadSHA256(root)
        XCTAssertEqual(after, before); XCTAssertEqual(payloadBefore, payloadAfter)
        let proof: [String:Any] = ["scenario":label,"approved":approved,"requests":requests,"databaseSchema":6,"readOnlyDigestBefore":before,"readOnlyDigestAfter":after,"payloadSHA256Before":payloadBefore,"payloadSHA256After":payloadAfter,"expected":expected,"requestTimings":timings]
        print("Managed observation pipe proof: "+String(decoding:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),as:UTF8.self))
    }
    func testActualNodeSwiftUnknownZeroSixteenMiBFullBudgetReleasedChangedAndRecovery() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner")
        let bridge = try DesktopBridge(api:api,session:session); defer { bridge.close() }
        let unknown = UUID()
        try runPipe(root,host,api,session,bridge,operationID:unknown,approved:false,label:"unapproved")
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
        try runPipe(root,host,api,session,bridge,operationID:unknown,approved:false,label:"ledger-approval-does-not-substitute")
        try api.authorizeFixtureManagedRecycleObservation(session:session,confirmed:true)
        try runPipe(root,host,api,session,bridge,operationID:unknown,approved:true,label:"unknown-explicit-null")
        let zero = try receive(host,data:Data(),key:"zero"), zeroRecycle = try host.recycle(grant:host.approveRecycle(allocationID:zero.allocationID,confirmed:true),key:Data("zero-recycle".utf8)); XCTAssertEqual(zeroRecycle.state,"completed"); host.revokeAll()
        try runPipe(root,host,api,session,bridge,operationID:zeroRecycle.operationID,approved:true,label:"zero-retained")
        let data = Data(repeating:0x35,count:16*1024*1024), first = try receive(host,data:data,key:"16m")
        let recycled = try host.recycle(grant:host.approveRecycle(allocationID:first.allocationID,confirmed:true),key:Data("recycle".utf8)); XCTAssertEqual(recycled.state,"completed"); host.revokeAll()
        try runPipe(root,host,api,session,bridge,operationID:recycled.operationID,approved:true,label:"16MiB-retained")
        let second = try receive(host,data:data,key:"full-second"); XCTAssertEqual(second.state,"owned"); host.revokeAll()
        let copied = try host.copy(grant:host.approveCopy(source:second.allocationID,key:Data("full-copy".utf8),confirmed:true)); XCTAssertEqual(copied.state,"owned"); host.revokeAll()
        XCTAssertEqual(try receive(host,data:data,key:"full-fourth").state,"owned"); host.revokeAll()
        XCTAssertEqual(try host.store.rows("SELECT sum(declared_bytes)::text FROM macnas.capacity_allocations WHERE state='owned';"),[["67108864"]])
        let copiedRecycle = try host.recycle(grant:host.approveRecycle(allocationID:copied.allocationID,confirmed:true),key:Data("copy-recycle".utf8)); XCTAssertEqual(copiedRecycle.state,"completed"); host.revokeAll()
        try runPipe(root,host,api,session,bridge,operationID:copiedRecycle.operationID,approved:true,label:"64MiB-scope-retained")
        let restored = try host.restore(grant:host.approveRestore(entryID:recycled.entryID,confirmed:true),key:Data("restore".utf8)); XCTAssertEqual(restored.state,"completed"); host.revokeAll()
        try runPipe(root,host,api,session,bridge,operationID:restored.operationID,approved:true,label:"released-entry-owned-still-charged")
        let bindingPath = root.appendingPathComponent("host-binding/binding.json"); var binding = try PortableInstance.strictRead(HostBinding.self,bindingPath); binding.mode = "read_only_recovery"; try SafeFS.write(binding,to:bindingPath)
        try api.authorizeFixtureManagedRecycleObservation(session:session,confirmed:true)
        try runPipe(root,host,api,session,bridge,operationID:restored.operationID,approved:true,label:"fresh-recovery-observation")
        let rows = try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries WHERE entry_id=\(FileEffectMetadata.uuidSQL(zeroRecycle.entryID));")
        let payloadID = try XCTUnwrap(rows.first?.first), path = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/entries/"+payloadID+"/payload")
        try Data("evil".utf8).write(to:path)
        try runPipe(root,host,api,session,bridge,operationID:zeroRecycle.operationID,approved:true,label:"changed-payload-is-ambiguous")
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(first.allocationID.uuidString.lowercased())),data)
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(second.allocationID.uuidString.lowercased())),data)
    }
    func testActualNodeSwiftUncertainCandidateRemainsUnsettledAndOwned() throws {
        let (root,host) = try physicalLab(), owned = try receive(host)
        let recycled = try host.recycle(grant:host.approveRecycle(allocationID:owned.allocationID,confirmed:true),key:Data("interrupted".utf8)) { if $0 == .afterRename { throw NASError.interrupted } }
        XCTAssertEqual(recycled.state,"uncertain"); host.revokeAll()
        let api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner"), bridge = try DesktopBridge(api:api,session:session); defer { bridge.close() }
        try api.authorizeFixtureManagedRecycleObservation(session:session,confirmed:true)
        try runPipe(root,host,api,session,bridge,operationID:recycled.operationID,approved:true,label:"candidateMoved-not-settled")
        XCTAssertEqual(try host.store.rows("SELECT phase FROM macnas.file_effect_operations WHERE operation_id=\(FileEffectMetadata.uuidSQL(recycled.operationID));"),[["uncertain"]])
    }
}
