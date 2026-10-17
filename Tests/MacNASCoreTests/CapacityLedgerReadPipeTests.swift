import Foundation
import XCTest
@testable import MacNASCore

final class CapacityLedgerReadPipeTests: PhysicalCapacityLab {
    // Test-only byte evidence. The host ledger endpoint itself never reads payloads.
    func payloadSHA256(_ root: URL) throws -> [String:String] {
        var hashes: [String:String] = [:]
        for (prefix,base) in [("visible",library(root)),("retained",root.appendingPathComponent(RecycleVault.fixturePath+"/vault/entries")),("staging",staging(root))] {
            for relative in try SafeFS.files(base) {hashes[prefix+"/"+relative] = try SafeFS.digest(base.appendingPathComponent(relative))}
        }
        return hashes
    }
    func runPipe(_ root: URL, _ host: FixturePhysicalCapacityNamespace, _ api: PrototypePlatformAPI,
                 _ session: PrototypeSession, _ bridge: DesktopBridge, approved: Bool, label: String) throws {
        let before = try host.store.contentDigest(), payloadBefore = try payloadSHA256(root)
        var expected: [String:Any] = [:]
        if approved {
            let ctx = try api.fixtureCapacityLedgerContext(session:session)
            let value = try api.listFixtureCapacityLedger(scopeID:ctx.scopeID,sourceID:ctx.sourceID,session:session)
            expected = ["scopeID":ctx.scopeID,"totals":try JSONSerialization.jsonObject(with:JSONEncoder().encode(value.totals)),
                "items":value.items.map{[$0.allocationID,$0.state,$0.declaredBytes] as [Any]}]
        }
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"]))
        process.arguments = [repo.appendingPathComponent("scripts/test_capacity_ledger_bridge.cjs").path,approved ? "approved":"denied",
            String(decoding:try JSONSerialization.data(withJSONObject:expected,options:[.sortedKeys]),as:UTF8.self)]
        process.currentDirectoryURL = repo; process.environment = ["LANG":"C","LC_ALL":"C"]
        process.standardInput = input; process.standardOutput = output; process.standardError = errors
        let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global());timer.schedule(deadline:.now()+120)
        timer.setEventHandler{if process.isRunning{process.terminate()}};timer.resume()
        defer{timer.cancel();if process.isRunning{process.terminate()};try? input.fileHandleForWriting.close()}
        try process.run();var frame = Data(), requests = 0
        while true {
            let block = output.fileHandleForReading.availableData;if block.isEmpty{break};frame.append(block)
            try require(frame.count<=65536,.budgetExceeded)
            while let end = frame.firstIndex(of:10) {
                requests += 1;try require(requests<=16,.budgetExceeded)
                let reply = bridge.handle(Data(frame[..<end]));frame.removeSubrange(...end)
                try input.fileHandleForWriting.write(contentsOf:reply+Data([10]))
            }
        }
        process.waitUntilExit();let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertTrue(frame.isEmpty);XCTAssertEqual(process.terminationStatus,0,String(decoding:diagnostics,as:UTF8.self))
        XCTAssertEqual(requests,approved ? 5:2)
        XCTAssertTrue(String(decoding:diagnostics,as:UTF8.self).contains("capacity-ledger-pipe: PASS "+(approved ? "approved":"denied")))
        let after = try host.store.contentDigest(), payloadAfter = try payloadSHA256(root)
        XCTAssertEqual(after,before);XCTAssertEqual(payloadBefore,payloadAfter)
        let proof: [String:Any] = ["scenario":label,"approved":approved,"requests":requests,"databaseSchema":6,
            "readOnlyDigestBefore":before,"readOnlyDigestAfter":after,"payloadSHA256Before":payloadBefore,"payloadSHA256After":payloadAfter,"expected":expected]
        print("Capacity ledger pipe proof: "+String(decoding:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),as:UTF8.self))
    }
    func testRealNodeSwiftReadsEmptyZeroExactLimitFullBudgetAndRetainedUnknownHistory() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root)
        let session = try api.beginFixtureSession(userID:"fixture-owner")
        let bridge = try DesktopBridge(api:api,session:session)
        defer{bridge.close()}
        try runPipe(root,host,api,session,bridge,approved:false,label:"unapproved")
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
        try runPipe(root,host,api,session,bridge,approved:true,label:"empty")
        let zero = try receive(host,data:Data(),key:"zero");XCTAssertEqual(zero.state,"owned");host.revokeAll()
        try runPipe(root,host,api,session,bridge,approved:true,label:"zero-owned")
        let data = Data(repeating:0x35,count:16*1024*1024)
        let first = try receive(host,data:data,key:"16m");XCTAssertEqual(first.state,"owned");host.revokeAll()
        try runPipe(root,host,api,session,bridge,approved:true,label:"16MiB-owned")
        let copy = try host.approveCopy(source:first.allocationID,key:Data("copy-16m".utf8),confirmed:true)
        XCTAssertEqual(try host.copy(grant:copy).state,"owned");host.revokeAll()
        for n in 2..<4 {XCTAssertEqual(try receive(host,data:data,key:"full-\(n)").state,"owned");host.revokeAll()}
        try runPipe(root,host,api,session,bridge,approved:true,label:"64MiB-owned")
        let recycled = try host.recycle(grant:host.approveRecycle(allocationID:first.allocationID,confirmed:true),key:Data("recycle".utf8))
        XCTAssertEqual(recycled.state,"completed");host.revokeAll()
        try runPipe(root,host,api,session,bridge,approved:true,label:"64MiB-retained")
        let entry = try XCTUnwrap(recycled.record).entryID
        XCTAssertEqual(try host.restore(grant:host.approveRestore(entryID:entry,confirmed:true),key:Data("restore".utf8)).state,"completed");host.revokeAll()
        try runPipe(root,host,api,session,bridge,approved:true,label:"64MiB-released-still-owned")
        let reserved = try receive(host,data:Data(),key:"cancelled"){if $0 == .reserved{throw NASError.interrupted}}
        XCTAssertEqual(reserved.state,"reserved");host.revokeAll()
        XCTAssertEqual(try host.cancelUnarmed(grant:host.approveCancelIncoming(allocationID:reserved.allocationID,confirmed:true)).state,.cancelled);host.revokeAll()
        let pending = try receive(host,data:Data(),key:"reserved"){if $0 == .reserved{throw NASError.interrupted}}
        XCTAssertEqual(pending.state,"reserved");host.revokeAll()
        let armed = try receive(host,data:Data(),key:"armed"){if $0 == .armed{throw NASError.interrupted}}
        XCTAssertEqual(armed.state,"armed");host.revokeAll()
        try runPipe(root,host,api,session,bridge,approved:true,label:"full-with-cancelled-reserved-armed-zero")
        // Exact source and restored payload remain intact; a list never adopts the unknown allocation.
        XCTAssertEqual(try Data(contentsOf:library(root).appendingPathComponent(first.allocationID.uuidString.lowercased())),data)
        XCTAssertEqual(try host.store.rows("SELECT state,declared_bytes FROM macnas.capacity_allocations WHERE allocation_id='\(armed.allocationID)';"),[["armed","0"]])
    }
}
