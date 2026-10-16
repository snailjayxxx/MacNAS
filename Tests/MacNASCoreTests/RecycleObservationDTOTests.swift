import Foundation
import XCTest
@testable import MacNASCore

/// Data-only boundary tests: no LabTest, PostgreSQL, filesystem reader or host approval.
final class RecycleObservationDTOTests: XCTestCase {
    let owner = Data("fixture-owner".utf8)
    func snapshot(kind: FileEffectDirection = .recycle, phase: FileEffectPhase = .completed,
                  charge: FileEffectCharge = .retained, bytes: Int64 = 4, revision: Int64 = 4, entryRevision: Int64 = 4) throws -> FileEffectExecutionSnapshot {
        let intent = FileEffectIntent(kind: kind, libraryID: "recycle-fixture", sourcePath: "source", targetParentPath: "", name: "source")
        let object = FileEffectStamp(device: "1", inode: "2", mode: 0o100600, uid: 501, links: 1, bytes: 4,
            mtimeSeconds: "1", mtimeNanos: 0, ctimeSeconds: "1", ctimeNanos: 0)
        var parent = object; parent.inode = "3"; parent.mode = 0o040700; parent.links = 2; parent.bytes = 0
        let evidence = FileEffectEvidence(object: object, sourceParent: parent, targetParent: parent, sha256: String(repeating: "a", count: 64))
        let record = FileEffectJournalRecord(operationID: UUID(), entryID: UUID(), kind: kind, phase: phase, revision: revision, entryRevision: entryRevision,
            chargeState: charge, chargedBytes: bytes, ownerUserHex: FileEffectMetadata.hex(owner), intentSHA256: try TransferEncoding.digest(FileEffectMetadata.encoded(intent)))
        return .init(record: record, intent: intent, preEvidence: evidence, postEvidence: phase == .armed || phase == .prepared || phase == .cancelled ? nil : evidence,
            volumeID: UUID(), vaultID: UUID(), payloadID: UUID(), originScopeSHA256: String(repeating: "b", count: 64), activeOperationID: nil)
    }
    func testUnknownProjectionIsExactNullAndUsesCanonicalID() throws {
        let id = UUID(), value = try RecycleOperationObservation(operationID: id, value: .init(snapshot: nil, classification: "notVisible"), owner: owner)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["observationVersion","operationID","visibility","record","classification"])
        XCTAssertEqual(json["operationID"] as? String, id.uuidString.lowercased()); XCTAssertTrue(json["record"] is NSNull)
        XCTAssertEqual(json["classification"] as? String, "notVisible")
    }
    func testVisibleProjectionContainsOnlyTheC1RecordAndAllowsLaterEntryRelease() throws {
        let s = try snapshot(charge: .released, bytes: 0, entryRevision: 9)
        let value = try RecycleOperationObservation(operationID: s.record.operationID, value: .init(snapshot: s, classification: "ambiguous"), owner: owner)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        let record = try XCTUnwrap(json["record"] as? [String: Any]); XCTAssertEqual(record.count, 10)
        XCTAssertNil(record["postEvidence"]); XCTAssertNil(record["path"]); XCTAssertEqual(record["chargedBytes"] as? Int, 0)
        XCTAssertEqual(value.record?.phase, "completed"); XCTAssertEqual(value.record?.entryRevision, 9)
    }
    func testUnsafeIntegersAndInconsistentChargeStatesCannotBeEncodedAsValidRecords() throws {
        for revision in [Int64.min,0,9_007_199_254_740_992,Int64.max] {
            XCTAssertThrowsError(try RecycleOperationRecord(snapshot(revision: revision, entryRevision: 2).record))
        }
        for entryRevision in [Int64.min,0,9_007_199_254_740_992,Int64.max] {
            XCTAssertThrowsError(try RecycleOperationRecord(snapshot(revision: 4, entryRevision: entryRevision).record))
        }
        XCTAssertNoThrow(try RecycleOperationRecord(snapshot(revision: 4, entryRevision: 2).record))
        XCTAssertThrowsError(try RecycleOperationRecord(snapshot(bytes: 16 * 1024 * 1024 + 1).record))
        XCTAssertThrowsError(try RecycleOperationRecord(snapshot(charge: .released, bytes: 4).record))
        XCTAssertThrowsError(try RecycleOperationRecord(snapshot(kind: .restore, charge: .retained).record))
        XCTAssertThrowsError(try RecycleOperationRecord(snapshot(kind: .restore, phase: .armed, charge: .released, bytes: 0).record))
        XCTAssertThrowsError(try RecycleOperationRecord(snapshot(phase: .cancelled, charge: .retained).record))
    }
    func testClassificationOwnershipAndOperationMustMatchTheClosedProjection() throws {
        let s = try snapshot(phase: .armed, charge: .reserved, revision: 2, entryRevision: 2)
        XCTAssertThrowsError(try RecycleOperationObservation(operationID: UUID(), value: .init(snapshot: s, classification: "sourceOnly"), owner: owner))
        XCTAssertThrowsError(try RecycleOperationObservation(operationID: s.record.operationID, value: .init(snapshot: s, classification: "sourceOnly"), owner: Data("other".utf8)))
        for classification in ["matchedPost","notObserved","changed","notVisible","unexpected"] {
            XCTAssertThrowsError(try RecycleOperationObservation(operationID: s.record.operationID, value: .init(snapshot: s, classification: classification), owner: owner))
        }
        let uncertain = try snapshot(phase: .uncertain, charge: .reserved, revision: 3, entryRevision: 3)
        let missingPost = FileEffectExecutionSnapshot(record: uncertain.record, intent: uncertain.intent, preEvidence: uncertain.preEvidence, postEvidence: nil,
            volumeID: uncertain.volumeID, vaultID: uncertain.vaultID, payloadID: uncertain.payloadID, originScopeSHA256: uncertain.originScopeSHA256, activeOperationID: uncertain.activeOperationID)
        XCTAssertThrowsError(try RecycleOperationObservation(operationID: missingPost.record.operationID, value: .init(snapshot: missingPost, classification: "matchedPost"), owner: owner))
        XCTAssertThrowsError(try RecycleOperationObservation(operationID: UUID(), value: .init(snapshot: nil, classification: "ambiguous"), owner: owner))
        XCTAssertEqual(try RecycleOperationObservation(operationID: s.record.operationID, value: .init(snapshot: s, classification: "candidateMoved"), owner: owner).record?.phase, "armed")
    }
    func testEnvelopeKeepsSourceContextSeparateFromTheUnchangedC1Body() throws {
        let body = try RecycleOperationObservation(operationID: UUID(), value: .init(snapshot: nil, classification: "notVisible"), owner: owner)
        let context = RecycleObservationContext(scopeID: String(repeating: "c", count: 64), userID: "fixture-owner", role: "administrator", mode: "read_only_recovery")
        let value = RecycleOperationObservationEnvelope(context: context, observation: body)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
        XCTAssertEqual(Set(json.keys), ["observationEnvelopeVersion","context","observation"])
        let encodedContext = try XCTUnwrap(json["context"] as? [String: Any]); XCTAssertEqual(Set(encodedContext.keys), ["contextVersion","source","scopeID","userID","role","mode"])
        XCTAssertNil(encodedContext["databaseName"]); XCTAssertNil(encodedContext["hostID"])
        let encodedBody = try XCTUnwrap(json["observation"] as? [String: Any]); XCTAssertEqual(encodedBody["observationVersion"] as? Int, 1); XCTAssertTrue(encodedBody["record"] is NSNull)
    }

}
