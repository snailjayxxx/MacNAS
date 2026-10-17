import Foundation
import XCTest
@testable import MacNASCore

final class ManagedRecycleObservationCLITests: PhysicalCapacityLab {
    func testOnlyExplicitManagedHostFlagApprovesContextAndReaderAlwaysRefuses() throws {
        let (root,host) = try physicalLab(), before = try host.store.contentDigest()
        let binary = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])).appendingPathComponent("macnas")
        for (user,flag,status,approved) in [("fixture-owner","",Int32(0),false),("fixture-owner","--approve-synthetic-capacity-ledger-read",Int32(0),false),("fixture-owner","--approve-synthetic-managed-recycle-observation",Int32(0),true),("fixture-family","--approve-synthetic-managed-recycle-observation",Int32(1),false)] {
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = binary; process.arguments = ["bridge","fixture","--source",root.path,"--user",user]+(flag.isEmpty ? []:[flag])
            process.environment = ProcessInfo.processInfo.environment; process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global()); timer.schedule(deadline:.now()+120)
            timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume()
            defer { timer.cancel(); if process.isRunning { process.terminate() } }
            try process.run()
            if user == "fixture-owner" { try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":"cli-managed","method":"managedRecycleObservationContext","params":[:]])+Data([10])) }
            try input.fileHandleForWriting.close(); let bytes = try output.fileHandleForReading.readToEnd() ?? Data(); process.waitUntilExit()
            let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data(); XCTAssertEqual(process.terminationStatus,status,String(decoding:diagnostics,as:UTF8.self))
            if user == "fixture-owner" {
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
                if approved { XCTAssertEqual((reply["data"] as? [String:Any])?["scopeID"] as? String,host.registration.scopeID.uuidString.lowercased()) }
                else { XCTAssertEqual((reply["error"] as? [String:Any])?["code"] as? String,"denied") }
            } else { XCTAssertTrue(bytes.isEmpty) }
        }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
}
