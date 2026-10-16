import Foundation
import XCTest
@testable import MacNASCore

final class RecycleObservationPipeTests: RecycleObservationLab {
    func testActualTypedNodeReadRequiresHostApprovalAndPreservesDatabaseAndPayload() throws {
        for (index, bytes) in [Data(), Data("keep".utf8), Data(repeating: 31, count: 16 * 1024 * 1024)].enumerated() {
        let databaseVersion = index == 0 ? 4 : 5
        let (root, host, _) = try recycleLab("pipe-\(index)", databaseVersion: databaseVersion), p = try seed(root, host, bytes: bytes), api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner"), bridge = try DesktopBridge(api: api, session: owner)
        defer { bridge.close() }
        let repo = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let before = try host.store.contentDigest(); var requestCounts: [String: Int] = [:]
        for mode in ["denied", "approved"] {
            if mode == "approved" { try api.authorizeFixtureRecycleObservation(session: owner, confirmed: true) }
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = URL(fileURLWithPath: try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"]))
            process.arguments = [repo.appendingPathComponent("scripts/test_recycle_observation_bridge.cjs").path, mode,
                p.operationID.uuidString.lowercased(), p.entryID.uuidString.lowercased(), String(bytes.count), String(databaseVersion)]
            process.currentDirectoryURL = repo; process.environment = ["LANG": "C", "LC_ALL": "C"]
            process.standardInput = input; process.standardOutput = output; process.standardError = errors
            let timer = DispatchSource.makeTimerSource(queue: DispatchQueue.global()); timer.schedule(deadline: .now() + 120)
            timer.setEventHandler { if process.isRunning { process.terminate() } }; timer.resume()
            defer { timer.cancel(); if process.isRunning { process.terminate() }; try? input.fileHandleForWriting.close() }
            try process.run(); var frame = Data(), requests = 0
            while true {
                let block = output.fileHandleForReading.availableData; if block.isEmpty { break }; frame.append(block)
                try require(frame.count <= 65536, .budgetExceeded)
                while let end = frame.firstIndex(of: 10) {
                    requests += 1; try require(requests <= 16, .budgetExceeded)
                    let reply = bridge.handle(Data(frame[..<end])); frame.removeSubrange(...end)
                    try input.fileHandleForWriting.write(contentsOf: reply + Data([10]))
                }
            }
            process.waitUntilExit(); let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
            XCTAssertTrue(frame.isEmpty); XCTAssertEqual(process.terminationStatus, 0, String(decoding: diagnostics, as: UTF8.self))
            requestCounts[mode] = requests
            XCTAssertGreaterThanOrEqual(requests, mode == "approved" ? 4 : 2)
            XCTAssertTrue(String(decoding: diagnostics, as: UTF8.self).contains("recycle-observation-pipe: PASS " + mode))
            XCTAssertEqual(try host.store.contentDigest(), before)
        }
        let read = try host.approve(.observe, confirmed: true)
        let observation = try FixtureRecycleCoordinator(authority: host).observe(operationID: p.operationID, grant: read)
        let snapshot = try XCTUnwrap(observation.snapshot)
        XCTAssertEqual(try Data(contentsOf: vault(root).appendingPathComponent("entries/" + snapshot.payloadID.uuidString.lowercased() + "/payload")), bytes)
        let after = try host.store.contentDigest()
        let proof: [String: String] = ["databaseSchema": String(databaseVersion), "bytes": String(bytes.count), "operationID": p.operationID.uuidString.lowercased(),
            "entryID": p.entryID.uuidString.lowercased(), "readOnlyDigestBefore": before, "readOnlyDigestAfter": after,
            "deniedRequests": String(requestCounts["denied"] ?? 0), "approvedRequests": String(requestCounts["approved"] ?? 0),
            "state": snapshot.record.phase.rawValue, "classification": observation.classification]
        print("Recycle observation pipe proof: " + String(decoding: try JSONSerialization.data(withJSONObject: proof, options: [.sortedKeys]), as: UTF8.self))
        }
    }
}
