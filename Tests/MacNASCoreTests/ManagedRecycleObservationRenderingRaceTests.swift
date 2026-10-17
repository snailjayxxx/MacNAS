import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class ManagedRecycleObservationRenderingRaceTests: PhysicalCapacityLab {
    func testPayloadChangedDuringEncodingCannotReturnTheEarlierMatchedPost() throws {
        for mutation in ["named-replacement","same-length-restored-mtime","extra-slot-child"] {
            let (root,host) = try physicalLab("render-"+mutation), owned = try receive(host)
            let recycled = try host.recycle(grant:host.approveRecycle(allocationID:owned.allocationID,confirmed:true),key:Data("recycle".utf8))
            XCTAssertEqual(recycled.state,"completed")
            let api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner")
            try api.authorizeFixtureManagedRecycleObservation(session:session,confirmed:true)
            let c = try api.fixtureManagedRecycleObservationContext(session:session)
            let rows = try host.store.rows("SELECT payload_id::text FROM macnas.recycle_entries WHERE entry_id=\(FileEffectMetadata.uuidSQL(recycled.entryID));")
            let id = try XCTUnwrap(rows.first?.first), path = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/entries/"+id+"/payload")
            let fd = open(path.path,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK); XCTAssertGreaterThanOrEqual(fd,0)
            defer { if fd >= 0 { close(fd) } }
            let before = try host.store.contentDigest()
            denied(.staleState) {
                _ = try api.withFixtureManagedRecycleOperationObservation(scopeID:c.scopeID,sourceID:c.sourceID,operationID:recycled.operationID.uuidString.lowercased(),session:session) { view in
                    XCTAssertEqual(view.observation.classification,"matchedPost")
                    if mutation == "named-replacement" {
                        let replacement = path.deletingLastPathComponent().appendingPathComponent("replacement")
                        try Data("evil".utf8).write(to:replacement)
                        try require(rename(replacement.path,path.path) == 0,.unsafeFile)
                    } else if mutation == "same-length-restored-mtime" {
                        let attributes = try TransferIO.attributes(fd)
                        try Data("evil".utf8).withUnsafeBytes { try require(pwrite(fd,$0.baseAddress,4,0) == 4,.unsafeFile) }
                        let times = [attributes.st_atimespec,attributes.st_mtimespec]
                        try times.withUnsafeBufferPointer { try require(futimens(fd,$0.baseAddress) == 0,.unsafeFile) }
                        let after = try TransferIO.attributes(fd)
                        XCTAssertEqual(after.st_size,attributes.st_size)
                        XCTAssertEqual(after.st_mtimespec.tv_sec,attributes.st_mtimespec.tv_sec)
                        XCTAssertEqual(after.st_mtimespec.tv_nsec,attributes.st_mtimespec.tv_nsec)
                    } else {
                        try Data("unexpected".utf8).write(to:path.deletingLastPathComponent().appendingPathComponent("other"))
                    }
                    return try JSONEncoder().encode(view)
                }
            }
            let after = try host.store.contentDigest(); XCTAssertEqual(after,before)
            XCTAssertEqual(try Data(contentsOf:path),Data((mutation == "extra-slot-child" ? "data":"evil").utf8))
            let proof = ["mutation":mutation,"readOnlyDigestBefore":before,"readOnlyDigestAfter":after]
            print("Managed observation rendering fence proof: "+String(decoding:try JSONSerialization.data(withJSONObject:proof,options:[.sortedKeys]),as:UTF8.self))
        }
    }
}
