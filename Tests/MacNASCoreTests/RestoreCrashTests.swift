import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class RestoreCrashTests: RestoreLab {
    private func killAt(_ point: String, expected: String, settle: Bool) throws {
        let (root, host, _) = try recycleLab(); try destination(root)
        let content = Data("actual-restore-sigkill".utf8), coordinator = FixtureRecycleCoordinator(authority: host)
        let entry = try retained(root, host, coordinator, bytes: content)
        let payload = try XCTUnwrap(try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries;").first?.first)
        let source = vault(root).appendingPathComponent("entries/" + payload + "/payload"), target = library(root).appendingPathComponent("dest/out")
        let binary = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary).appendingPathComponent("macnas")
        process.arguments = ["fixture", "restore-crash-probe", "--source", root.path, "--entry", entry.uuidString,
            "--parent", "dest", "--name", "out", "--stop-after", point, "--confirm-synthetic-effect", "--confirm-synthetic-destination"]
        var environment = ProcessInfo.processInfo.environment; environment["MACNAS_RECYCLE_PROBE_ENABLED"] = "1"
        process.environment = environment; process.standardOutput = output; process.standardError = errors
        defer { if process.isRunning { ChildControl.stop(process) } }
        try process.run()
        let marker = root.appendingPathComponent("host-binding/recycle-test-checkpoint.json")
        let deadline = ProcessInfo.processInfo.systemUptime + 90
        var checkpoint: [String: String]?
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
            if let bytes = try? SafeFS.readData(marker, maximumBytes: 4096),
               let value = try? JSONDecoder().decode([String: String].self, from: bytes), value["point"] == point {
                checkpoint = value; break
            }
            Thread.sleep(forTimeInterval: 0.01)
        }
        guard let checkpoint else {
            ChildControl.stop(process)
            XCTFail("Restore worker did not reach " + point + ": " + String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
            return
        }
        XCTAssertEqual(checkpoint["pid"], String(process.processIdentifier)); XCTAssertEqual(checkpoint["direction"], "restore")
        XCTAssertEqual(checkpoint["entryID"], entry.uuidString)
        let operation = try XCTUnwrap(checkpoint["operationID"].flatMap(UUID.init(uuidString:)))
        let oldRead = try host.approve(.observe, confirmed: true)
        denied(.busy) { try host.withLockedVault(oldRead, action: .observe) { _ in XCTFail("second process entered restore vault") } }
        denied(.busy) { _ = try InstanceLock(root, mode: .exclusive) }
        XCTAssertEqual(kill(process.processIdentifier, SIGKILL), 0)
        process.waitUntilExit(); XCTAssertEqual(process.terminationReason, .uncaughtSignal); XCTAssertEqual(process.terminationStatus, SIGKILL)
        let fresh = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8)), next = FixtureRecycleCoordinator(authority: fresh)
        denied(.denied) { try fresh.withLockedVault(oldRead, action: .observe) { _ in XCTFail("old host approval reused") } }
        let read = try fresh.approve(.observe, confirmed: true), before = try host.store.contentDigest()
        let observed = try next.observe(operationID: operation, grant: read), after = try host.store.contentDigest()
        XCTAssertEqual(observed.classification, expected); XCTAssertEqual(after, before)
        let snapshot = try XCTUnwrap(observed.snapshot)
        XCTAssertEqual(snapshot.record.kind, .restore); XCTAssertEqual(snapshot.record.entryID, entry)
        XCTAssertEqual(snapshot.record.phase, settle ? .observed : .armed)
        XCTAssertEqual(snapshot.record.chargeState, .retained); XCTAssertEqual(snapshot.record.chargedBytes, Int64(content.count))
        if point == "beforeRename" {
            XCTAssertEqual(try Data(contentsOf: source), content); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
        } else {
            XCTAssertFalse(FileManager.default.fileExists(atPath: source.path)); XCTAssertEqual(try Data(contentsOf: target), content)
        }
        let write = try fresh.approve(.settle, confirmed: true), destination = try fresh.approveRestoreDestination(parentPath: "dest", confirmed: true)
        if settle {
            let parent = try RecycleDirectory(library(root).appendingPathComponent("dest"))
            let stamp = try XCTUnwrap(parent.named("out"))
            let done = try next.settle(operationID: operation, grant: write, destinationGrant: destination)
            XCTAssertEqual(done.operationID, operation); XCTAssertEqual(done.entryID, entry)
            XCTAssertEqual(done.phase, .completed); XCTAssertEqual(done.chargeState, .released); XCTAssertEqual(done.chargedBytes, 0)
            XCTAssertTrue(RecycleDirectory.sameStamp(stamp, try XCTUnwrap(parent.named("out"))))
            XCTAssertEqual(try host.store.rows("SELECT count(*) FROM macnas.file_effect_operations;"), [["2"]])
            try host.store.validate(expectedVersion: 4)
        } else {
            denied(.staleState) { _ = try next.settle(operationID: operation, grant: write, destinationGrant: destination) }
            XCTAssertEqual(try host.store.contentDigest(), before)
        }
        let proof = ["point": point, "pid": String(process.processIdentifier), "terminationStatus": String(process.terminationStatus),
            "operationID": operation.uuidString, "entryID": entry.uuidString, "classification": observed.classification,
            "persistedPhase": snapshot.record.phase.rawValue, "chargeBeforeSettlement": snapshot.record.chargeState.rawValue,
            "readOnlyDigestBefore": before, "readOnlyDigestAfter": after, "settled": settle ? "released-original-entry" : "refused-no-post"]
        print("Restore crash proof: " + String(decoding: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), as: UTF8.self))
    }
    func testActualRestoreSIGKILLBeforeRenameKeepsVaultPayloadAndRetainedCharge() throws {
        try killAt("beforeRename", expected: "sourceOnly", settle: false)
    }
    func testActualRestoreSIGKILLAfterRenameWithoutPostCannotReleaseCharge() throws {
        try killAt("afterRename", expected: "candidateMoved", settle: false)
    }
    func testActualRestoreSIGKILLAfterObservedSettlesOriginalEntryOnlyWithNewApprovals() throws {
        try killAt("observed", expected: "matchedPost", settle: true)
    }
    func testProbeWithoutHarnessOrEitherConfirmationRefusesBeforeOpeningMissingRoot() throws {
        let binary = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        let lab = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_TESTLAB"])
        let missing = URL(fileURLWithPath: lab).appendingPathComponent("not-created-" + UUID().uuidString)
        for (enabled, sourceConfirmed, destinationConfirmed) in [(false, true, true), (true, false, true), (true, true, false)] {
            let worker = Process(), output = Pipe(), errors = Pipe()
            worker.executableURL = URL(fileURLWithPath: binary).appendingPathComponent("macnas")
            worker.arguments = ["fixture", "restore-crash-probe", "--source", missing.path, "--entry", UUID().uuidString,
                "--parent", "dest", "--name", "out", "--stop-after", "beforeRename"]
                + (sourceConfirmed ? ["--confirm-synthetic-effect"] : [])
                + (destinationConfirmed ? ["--confirm-synthetic-destination"] : [])
            var environment = ProcessInfo.processInfo.environment
            if enabled { environment["MACNAS_RECYCLE_PROBE_ENABLED"] = "1" } else { environment.removeValue(forKey: "MACNAS_RECYCLE_PROBE_ENABLED") }
            worker.environment = environment; worker.standardOutput = output; worker.standardError = errors
            try worker.run(); worker.waitUntilExit()
            XCTAssertEqual(worker.terminationReason, .exit); XCTAssertEqual(worker.terminationStatus, 1)
            XCTAssertTrue(output.fileHandleForReading.readDataToEndOfFile().isEmpty)
            XCTAssertEqual(String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self), "macnas: denied\n")
            XCTAssertFalse(FileManager.default.fileExists(atPath: missing.path))
        }
    }

}
