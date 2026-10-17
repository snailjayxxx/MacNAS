import Foundation
import XCTest
@testable import MacNASCore

final class CapacityLedgerListDTOTests: XCTestCase {
    let scope = UUID(), owner = Data("e\u{301}".utf8), source = String(repeating:"a",count:64)
    func record(_ n: Int = 1, scopeID: UUID? = nil, origin: CapacityOrigin = .upload, bytes: Int64 = 0,
                state: CapacityAllocationState = .reserved, revision: Int64 = 1, sha256: String? = nil) -> CapacityAllocation {
        .init(allocationID:UUID(uuidString:String(format:"00000000-0000-4000-8000-%012d",n))!,scopeID:scopeID ?? scope,
              origin:origin,intentSHA256:source,declaredBytes:bytes,state:state,revision:revision,sha256:sha256)
    }
    func project(_ records: [CapacityAllocation]) throws -> CapacityLedgerListView {
        try .init(scopeID:scope,ownerUserID:owner,sourceID:source,records:records)
    }
    func testExactPublicFieldsAndExplicitNullsNeverExposePhysicalAuthority() throws {
        let v = try project([record(),record(2,bytes:4,state:.owned,revision:3,sha256:source)])
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with:JSONEncoder().encode(v)) as? [String:Any])
        XCTAssertEqual(Set(object.keys),["listVersion","scopeID","ownerUserHex","sourceID","evidence","limitBytes","totals","items"])
        XCTAssertEqual(object["evidence"] as? String,"ledgerOnly"); XCTAssertEqual(v.ownerUserHex,"65cc81")
        let items = try XCTUnwrap(object["items"] as? [[String:Any]])
        XCTAssertEqual(Set(items[0].keys),["allocationID","origin","intentSHA256","declaredBytes","state","revision","sha256"])
        XCTAssertTrue(items[0]["sha256"] is NSNull); XCTAssertEqual(v.totals.ownedBytes,4)
        XCTAssertEqual(Set(try XCTUnwrap(object["totals"] as? [String:Any]).keys),["reservedBytes","unresolvedBytes","ownedBytes","allocatedBytes","historyCount","unresolvedCount"])
    }
    func testCompleteHistoryOrderScopeStateAndHashesAreMandatory() throws {
        for records in [[record(),record()], [record(2),record()], [record(scopeID:UUID())], [record(origin:.initial)],
            [record(bytes:-1)], [record(bytes:16*1024*1024+1)], [record(revision:2)], [record(state:.armed)],
            [record(state:.owned,revision:3)], [record(sha256:source)], [record(state:.cancelled,revision:2,sha256:source)],
            [record(state:.owned,revision:3,sha256:"bad")]] {
            XCTAssertThrowsError(try project(records))
        }
        XCTAssertThrowsError(try CapacityLedgerListView(scopeID:scope,ownerUserID:Data([0xff]),sourceID:source,records:[]))
        XCTAssertThrowsError(try CapacityLedgerListView(scopeID:scope,ownerUserID:owner,sourceID:"bad",records:[]))
    }
    func testZeroByteSlotsHistoryAndFullBudgetAreStillBounded() throws {
        XCTAssertEqual(try project((1...8).map{record($0)}).totals.historyCount,8)
        XCTAssertThrowsError(try project((1...9).map{record($0)}))
        XCTAssertEqual(try project((1...64).map{record($0,state:.cancelled,revision:2)}).totals.historyCount,64)
        XCTAssertThrowsError(try project((1...65).map{record($0,state:.cancelled,revision:2)}))
        let full = (1...4).map{record($0,bytes:16*1024*1024,state:.owned,revision:3,sha256:source)}
        XCTAssertEqual(try project(full+[record(5,state:.armed,revision:2)]).totals.allocatedBytes,64*1024*1024)
        XCTAssertEqual(try project(full+[record(5,state:.armed,revision:2)]).totals.unresolvedCount,1)
        XCTAssertThrowsError(try project(full+[record(5,bytes:1)]))
    }
}
