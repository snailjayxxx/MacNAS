import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class PhysicalCapacityCrashTests: PhysicalCapacityLab {
    private func killAt(_ point: String, expected: CapacityAllocationState) throws {
        let (root,host) = try physicalLab(), bin = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        let process = Process(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath:bin).appendingPathComponent("macnas")
        process.arguments = ["fixture","capacity-crash-probe","--source",root.path,"--stop-after",point,"--confirm-synthetic-effect"]
        var env = ProcessInfo.processInfo.environment; env["MACNAS_CAPACITY_PROBE_ENABLED"] = "1"
        process.environment = env; process.standardOutput = FileHandle.nullDevice; process.standardError = errors
        defer { if process.isRunning { ChildControl.stop(process) } }
        try process.run()
        let marker = root.appendingPathComponent("host-binding/capacity-test-checkpoint.json")
        let deadline = ProcessInfo.processInfo.systemUptime+90
        var reached: [String:String]?
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if let bytes = try? SafeFS.readData(marker,maximumBytes:4096),
               let value = try? JSONDecoder().decode([String:String].self,from:bytes), value["point"] == point {
                reached = value; break
            }
            Thread.sleep(forTimeInterval:0.01)
        }
        guard let reached else {
            ChildControl.stop(process)
            XCTFail("Capacity worker did not reach "+point+": "+String(decoding:errors.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self))
            return
        }
        XCTAssertEqual(reached["pid"],String(process.processIdentifier)); XCTAssertEqual(reached["persistedState"],expected.rawValue)
        let id = try XCTUnwrap(reached["allocationID"].flatMap(UUID.init(uuidString:)))
        let read = try host.approveInspect(confirmed:true)
        denied(.busy) { _ = try host.inspect(read) }
        XCTAssertEqual(kill(process.processIdentifier,SIGKILL),0); process.waitUntilExit()
        XCTAssertEqual(process.terminationReason,.uncaughtSignal); XCTAssertEqual(process.terminationStatus,SIGKILL)
        let restarted = try FixturePhysicalCapacityNamespace(root:root,userID:owner), before = try host.store.contentDigest()
        denied(.denied) { _ = try restarted.inspect(read) }
        let observed = try inventory(restarted), after = try host.store.contentDigest(), data = Data("physical-capacity-sigkill".utf8)
        XCTAssertEqual(before,after); XCTAssertEqual(observed.declared.allocatedBytes,Int64(data.count))
        XCTAssertEqual(try host.store.rows("SELECT state FROM macnas.capacity_allocations;"),[[expected.rawValue]])
        let file = library(root).appendingPathComponent(id.uuidString.lowercased())
        if ["afterPublish","owned"].contains(point) { XCTAssertEqual(try Data(contentsOf:file),data) }
        else { XCTAssertFalse(FileManager.default.fileExists(atPath:file.path)) }
        if expected == .reserved {
            XCTAssertTrue(observed.clean)
            let cancelled = try restarted.cancelUnarmed(grant:restarted.approveCancelIncoming(allocationID:id,confirmed:true))
            XCTAssertEqual(cancelled.state,.cancelled); XCTAssertEqual(try inventory(restarted).declared.allocatedBytes,0)
        } else if expected == .armed {
            XCTAssertFalse(observed.clean)
            let grant = try restarted.approveReceive(key:Data("crash-probe".utf8),bytes:Int64(data.count),sha256:TransferEncoding.digest(data),confirmed:true)
            denied(.staleState) { _ = try restarted.receive(data,grant:grant) }
            denied(.staleState) { _ = try restarted.cancelUnarmed(grant:restarted.approveCancelIncoming(allocationID:id,confirmed:true)) }
            XCTAssertEqual(try host.store.contentDigest(),before)
            XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.capacity_file_ownership WHERE baseline_stamp IS NOT NULL;"),[["0"]])
        } else {
            XCTAssertTrue(observed.clean); XCTAssertEqual(observed.visible,[id])
            let original = try XCTUnwrap(RecycleDirectory(library(root)).named(id.uuidString.lowercased()))
            let grant = try restarted.approveReceive(key:Data("crash-probe".utf8),bytes:Int64(data.count),sha256:TransferEncoding.digest(data),confirmed:true)
            let result = try restarted.receive(data,grant:grant)
            XCTAssertEqual(result.allocationID,id); XCTAssertEqual(result.state,"owned"); XCTAssertNil(result.error)
            XCTAssertEqual(try host.store.contentDigest(),before)
            XCTAssertEqual(try RecycleDirectory(library(root)).named(id.uuidString.lowercased()),original)
        }
        try host.store.validate(expectedVersion:6)
        let proof = ["point":point,"pid":String(process.processIdentifier),"terminationStatus":String(process.terminationStatus),
            "allocationID":id.uuidString,"persistedState":expected.rawValue,"readOnlyDigestBefore":before,"readOnlyDigestAfter":after,
            "chargedBytes":String(observed.declared.allocatedBytes),"matchingFileAdopted":"false"]
        print("Physical capacity crash proof: "+String(decoding:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),as:UTF8.self))
    }
    func testSIGKILLReservedAllowsOnlyFreshPositiveAbsenceCancellation() throws { try killAt("reserved",expected:.reserved) }
    func testSIGKILLArmedBeforeStageKeepsFullChargeWithoutCancellation() throws { try killAt("armed",expected:.armed) }
    func testSIGKILLAfterPublishKeepsArmedAndRefusesMatchingFileAdoption() throws { try killAt("afterPublish",expected:.armed) }
    func testSIGKILLAfterOwnedPreservesProofAndIdempotentOriginalResult() throws { try killAt("owned",expected:.owned) }
}
