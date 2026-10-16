import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class RecycleCrashTests: RecycleVaultLab {
    private func killAt(_ point: String, expected: String, settle: Bool) throws {
        let (root, host, _) = try recycleLab(), content = Data("actual-sigkill-payload".utf8)
        try content.write(to: library(root).appendingPathComponent("source"))
        let binary = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary).appendingPathComponent("macnas")
        process.arguments = ["fixture", "recycle-crash-probe", "--source", root.path, "--path", "source",
            "--stop-after", point, "--confirm-synthetic-effect"]
        var environment = ProcessInfo.processInfo.environment; environment["MACNAS_RECYCLE_PROBE_ENABLED"] = "1"
        process.environment = environment; process.standardOutput = output; process.standardError = errors
        defer { if process.isRunning { ChildControl.stop(process) } }
        try process.run()
        let marker = root.appendingPathComponent("host-binding/recycle-test-checkpoint.json")
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var checkpoint: [String: String]?
        while ProcessInfo.processInfo.systemUptime < deadline && process.isRunning {
            if let bytes = try? SafeFS.readData(marker, maximumBytes: 4096),
               let value = try? JSONDecoder().decode([String: String].self, from: bytes), value["point"] == point {
                checkpoint = value; break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let checkpoint else {
            ChildControl.stop(process)
            XCTFail("Worker did not reach " + point + ": " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            return
        }
        XCTAssertEqual(checkpoint["pid"], String(process.processIdentifier))
        let operation = try XCTUnwrap(checkpoint["operationID"].flatMap(UUID.init(uuidString:)))
        let read = try host.approve(.observe, confirmed: true)
        denied(.busy) { try host.withLockedVault(read, action: .observe) { _ in XCTFail("second process entered held vault") } }
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit(); XCTAssertEqual(process.terminationReason, .uncaughtSignal); XCTAssertEqual(process.terminationStatus, SIGKILL)
        let restarted = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        // Parent-host grants cannot authorize a newly-created host even though they name the same DB/vault.
        denied(.denied) { try restarted.withLockedVault(read, action: .observe) { _ in XCTFail("inherited approval") } }
        let coordinator = FixtureRecycleCoordinator(authority: restarted), fresh = try restarted.approve(.observe, confirmed: true)
        let before = try host.store.contentDigest()
        let observed = try coordinator.observe(operationID: operation, grant: fresh)
        let after = try host.store.contentDigest()
        XCTAssertEqual(observed.classification, expected); XCTAssertEqual(after, before)
        let snapshot = try XCTUnwrap(observed.snapshot)
        XCTAssertEqual(snapshot.record.phase, settle ? .observed : .armed)
        XCTAssertEqual(snapshot.record.chargeState, .reserved); XCTAssertEqual(snapshot.record.chargedBytes, Int64(content.count))
        let target = vault(root).appendingPathComponent("entries/" + snapshot.payloadID.uuidString.lowercased() + "/payload")
        if point == "beforeRename" {
            XCTAssertEqual(try Data(contentsOf: library(root).appendingPathComponent("source")), content)
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: library(root).appendingPathComponent("source").path))
            XCTAssertEqual(try Data(contentsOf: target), content)
        }
        let write = try restarted.approve(.settle, confirmed: true)
        if settle {
            let pinned = try RecycleDirectory(vault(root)).child("entries").child(snapshot.payloadID.uuidString.lowercased())
            let original = try XCTUnwrap(pinned.named("payload"))
            let done = try coordinator.settle(operationID: operation, grant: write)
            XCTAssertEqual(done.operationID, operation); XCTAssertEqual(done.phase, .completed); XCTAssertEqual(done.chargeState, .retained)
            XCTAssertTrue(RecycleDirectory.sameStamp(original, try XCTUnwrap(pinned.named("payload"))))
            XCTAssertEqual(try Data(contentsOf: target), content)
            XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["1"]])
            try host.store.validate(expectedVersion: 4)
        } else {
            denied(.staleState) { _ = try coordinator.settle(operationID: operation, grant: write) }
            XCTAssertEqual(try host.store.contentDigest(), before)
        }
        let proof = ["point": point, "pid": String(process.processIdentifier), "terminationStatus": String(process.terminationStatus),
            "operationID": operation.uuidString, "classification": observed.classification, "persistedPhase": snapshot.record.phase.rawValue,
            "readOnlyDigestBefore": before, "readOnlyDigestAfter": after, "settled": settle ? "completed-original-id" : "refused-no-post"]
        print("Recycle crash proof: " + String(decoding: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), as: UTF8.self))
    }
    func testActualSIGKILLBeforeRenameKeepsSourceAndArmedChargeWithoutReplay() throws {
        try killAt("beforeRename", expected: "sourceOnly", settle: false)
    }
    func testActualSIGKILLAfterRenameWithoutPostCannotBeAdopted() throws {
        try killAt("afterRename", expected: "candidateMoved", settle: false)
    }
    func testActualSIGKILLAfterObservedAllowsOnlyFreshApprovedSettlement() throws {
        try killAt("observed", expected: "matchedPost", settle: true)
    }
}
