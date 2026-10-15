import Foundation
import XCTest
@testable import MacNASCore

final class BridgeJSONTests: XCTestCase {
    func denied(_ code: NASError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? NASError, code, file: file, line: line) }
    }
    func parse(_ text: String) throws -> BridgeJSON { try BridgeJSON.decode(Data(text.utf8)) }
    func testUnicodeEscapesAndNestedJSONRemainData() throws {
        let value = try parse(#"{"text":"中文\n日本語\uD83D\uDC1A","values":[true,false,null,-1,1.5,1e2]}"#)
        let fields = try value.fields(required: ["text","values"])
        XCTAssertEqual(try fields["text"]!.text(maximumBytes: 100), "中文\n日本語🐚")
    }
    func testDuplicateRawEscapedAndNestedKeysAreRejected() {
        for value in [#"{"x":1,"x":2}"#, #"{"x":1,"\u0078":2}"#, #"{"outer":{"role":"reader","role":"administrator"}}"#] {
            denied(.invalidSchema) { _ = try self.parse(value) }
        }
    }
    func testTrailingTokensCommasMissingValuesAndNonObjectShapesAreRejected() throws {
        for value in ["{}", "{} {}", "{", "[1,]", "{\"x\":}", "{\"x\":1,}", "true false"] {
            if value == "{}" { _ = try parse(value) } else { denied(.invalidSchema) { _ = try self.parse(value) } }
        }
        denied(.invalidSchema) { _ = try self.parse("[]").fields(required: []) }
    }
    func testNumbersHaveStrictGrammar() {
        for value in ["01", "-01", "+1", ".1", "1.", "1e", "1e+", "NaN", "Infinity", "--1"] {
            denied(.invalidSchema) { _ = try self.parse(value) }
        }
    }
    func testProtocolIntegersRejectBooleanFractionExponentAndUnsafeRange() throws {
        for value in ["true", "1.0", "1e0", "-1", "9007199254740992"] {
            denied(.invalidSchema) { _ = try self.parse(value).integer(in: 0...Int64.max) }
        }
        XCTAssertEqual(try parse("9007199254740991").integer(in: 0...Int64.max), 9_007_199_254_740_991)
    }
    func testByteDepthAndNodeBudgetsAreIndependent() {
        denied(.budgetExceeded) { _ = try BridgeJSON.decode(Data(repeating: 32, count: 65537)) }
        denied(.budgetExceeded) { _ = try self.parse(String(repeating: "[", count: 18) + "0" + String(repeating: "]", count: 18)) }
        denied(.budgetExceeded) { _ = try self.parse("[" + String(repeating: "0,", count: 4096) + "0]") }
    }
    func testInvalidUTF8BOMAndLiteralControlAreRejected() {
        for bytes: [UInt8] in [[255], [239,187,191,123,125], [34,10,34]] {
            denied(.invalidSchema) { _ = try BridgeJSON.decode(Data(bytes)) }
        }
        denied(.invalidSchema) { _ = try BridgeJSON.decode(Data()) }
    }
    func testInvalidSurrogateAndUnknownEscapeAreRejected() {
        for value in [#""\uD800""#, #""\uDC00""#, #""\uD800\u0041""#, #""\q""#, #""\uXXXX""#] {
            denied(.invalidSchema) { _ = try self.parse(value) }
        }
    }
    func testUnknownMissingAndNullTypedFieldsAreRejected() throws {
        denied(.invalidSchema) { _ = try self.parse(#"{"x":1,"role":"administrator"}"#).fields(required: ["x"]) }
        denied(.invalidSchema) { _ = try self.parse("{}").fields(required: ["x"]) }
        denied(.invalidSchema) { _ = try self.parse("null").text(maximumBytes: 10) }
    }
    func testStringBudgetEmptyAndNullByteAreChecked() {
        for value in [#""""#, #""\u0000""#, #""12345""#] {
            denied(.invalidSchema) { _ = try self.parse(value).text(maximumBytes: 4) }
        }
    }
}

final class DesktopBridgeTests: LabTest {
    func service(schema: Int = 3) throws -> PrototypePlatformAPI {
        let root = child("bridge-source")
        try PortableInstance.createSynthetic(at: root, databaseVersion: schema)
        return try PrototypePlatformAPI(root: root)
    }
    func bridge(_ api: PrototypePlatformAPI, user: String = "fixture-owner") throws -> DesktopBridge {
        try DesktopBridge(api: api, session: api.beginFixtureSession(userID: user))
    }
    func request(_ bridge: DesktopBridge, _ method: String, _ params: [String: Any] = [:], id: String = UUID().uuidString) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: ["apiVersion":1,"requestId":id,"method":method,"params":params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.handle(data)) as? [String: Any])
    }
    func code(_ response: [String: Any]) -> String? { (response["error"] as? [String: Any])?["code"] as? String }
    func testOverviewRouteAuthorizationAndLibraryMetadataHaveExplicitFixtureSource() throws {
        let api = try service(), owner = try bridge(api), reader = try bridge(api, user: "fixture-family")
        let overview = try XCTUnwrap(request(owner, "overview")["data"] as? [String: Any])
        XCTAssertEqual(overview["source"] as? String, "fixture-host")
        XCTAssertEqual(overview["physicalPool"] as? String, "unbound")
        XCTAssertEqual(overview["taskTimestampsAvailable"] as? Bool, false)
        XCTAssertEqual((overview["libraries"] as? [[String:Any]])?.count, 1)
        XCTAssertEqual((try request(reader, "listLibraries")["data"] as? [Any])?.count, 0)
        XCTAssertEqual(code(try request(reader, "authorizeApp", ["id":"settings"])), "denied")
        XCTAssertEqual(try request(reader, "authorizeApp", ["id":"preferences"])["data"] as? Bool, true)
        let text = String(decoding: try JSONSerialization.data(withJSONObject: overview), as: UTF8.self)
        XCTAssertFalse(text.contains(api.root.path)); XCTAssertFalse(text.contains("databaseName"))
    }
    func testActualJobIdempotencyCancellationEventReplayAndAcknowledgement() throws {
        let api = try service(), owner = try bridge(api)
        let submitted = try XCTUnwrap(request(owner, "submitLabelJob", ["id":"message-job","key":"message-key","value":"<script>data</script>"])["data"] as? [String:Any])
        XCTAssertEqual(submitted["state"] as? String, "queued"); XCTAssertNil(submitted["payload"])
        let repeated = try XCTUnwrap(request(owner, "submitLabelJob", ["id":"another-id","key":"message-key","value":"<script>data</script>"])["data"] as? [String:Any])
        XCTAssertEqual(repeated["id"] as? String, "message-job")
        XCTAssertEqual(code(try request(owner, "submitLabelJob", ["id":"collision","key":"message-key","value":"different"])), "collision")
        let cancelled = try XCTUnwrap(request(owner, "cancelJob", ["id":"message-job"])["data"] as? [String:Any])
        XCTAssertEqual(cancelled["state"] as? String, "cancelled")
        let first = try XCTUnwrap(request(owner, "pollEvents", ["consumerID":"bridge-consumer"])["data"] as? [[String:Any]])
        let second = try XCTUnwrap(request(owner, "pollEvents", ["consumerID":"bridge-consumer"])["data"] as? [[String:Any]])
        XCTAssertEqual(first.count, second.count)
        let through = try XCTUnwrap(first.last?["sequence"] as? Int64)
        XCTAssertEqual(try request(owner, "acknowledgeEvents", ["consumerID":"bridge-consumer","through":through])["data"] as? Bool, true)
        XCTAssertEqual((try request(owner, "pollEvents", ["consumerID":"bridge-consumer"])["data"] as? [Any])?.count, 0)
        XCTAssertEqual(code(try request(owner, "acknowledgeEvents", ["consumerID":"bridge-consumer","through":through+100])), "denied")
    }
    func testReaderCannotSeeOrCancelAnotherUsersTaskOrCreateLabels() throws {
        let api = try service(), owner = try bridge(api), reader = try bridge(api, user: "fixture-family")
        _ = try request(owner, "submitLabelJob", ["id":"private-job","key":"private-key","value":"private synthetic"])
        XCTAssertEqual((try request(reader, "listJobs")["data"] as? [Any])?.count, 0)
        XCTAssertEqual(code(try request(reader, "cancelJob", ["id":"private-job"])), "denied")
        XCTAssertEqual(code(try request(reader, "submitLabelJob", ["id":"no","key":"no","value":"no"])), "denied")
        XCTAssertEqual(code(try request(reader, "overview", ["role":"administrator"])), "invalidInput")
    }
    func testUnknownFieldsMethodsTypesAndDuplicateMessagesDoNotReachBusinessActions() throws {
        let api = try service(), host = try bridge(api)
        for method in ["executeSQL","beginFixtureSession","updateFixtureVolumeInventory","setFixtureLibraryReaders","runSample"] {
            XCTAssertEqual(code(try request(host, method, ["path":api.root.path,"sql":"DROP DATABASE"])), "unsupported")
        }
        for params: [String:Any] in [["consumerID":"x","limit":true],["consumerID":"x","limit":1.5],["consumerID":"x","limit":101],["consumerID":"x","role":"administrator"]] {
            XCTAssertEqual(code(try request(host, "pollEvents", params)), "invalidInput")
        }
        let raw = #"{"apiVersion":1,"requestId":"duplicate-key","method":"overview","params":{"user":"a","user":"b"}}"#
        let rejected = try XCTUnwrap(JSONSerialization.jsonObject(with: host.handle(Data(raw.utf8))) as? [String:Any])
        XCTAssertEqual(code(rejected), "invalidInput")
        _ = try request(host, "authorizeApp", ["id":"overview"], id: "once")
        XCTAssertEqual(code(try request(host, "authorizeApp", ["id":"overview"], id: "once")), "replay")
        let response = try request(host, "listFiles", ["libraryID":"unknown","root":api.root.path])
        XCTAssertEqual(code(response), "invalidInput")
        XCTAssertFalse(String(decoding: try JSONSerialization.data(withJSONObject: response), as: UTF8.self).contains(api.root.path))
    }
    func testCloseEndedSessionsAndUnsupportedDatabaseSchemaAreRejected() throws {
        let api = try service(), session = try api.beginFixtureSession(userID: "fixture-owner"), host = try DesktopBridge(api: api, session: session)
        host.close(); XCTAssertEqual(code(try request(host, "overview")), "denied")
        denied(.denied) { _ = try api.overview(session: session) }
        let ended = try api.beginFixtureSession(userID: "fixture-owner"), otherHost = try DesktopBridge(api: api, session: ended)
        api.endSession(ended); XCTAssertEqual(code(try request(otherHost, "listJobs")), "denied")
        let oldRoot = child("old-schema"); try PortableInstance.createSynthetic(at: oldRoot)
        let old = try PrototypePlatformAPI(root: oldRoot), user = try old.beginFixtureSession(userID: "fixture-owner")
        denied(.unsupported) { _ = try DesktopBridge(api: old, session: user) }
    }
    func testRequestAndResponseBudgetsReturnErrorsWithoutPartialData() throws {
        let api = try service()
        let session = try api.beginFixtureSession(userID: "fixture-owner")
        let host = try DesktopBridge(api: api, session: session, limits: BridgeLimits(requests: 2, responseBytes: 128))
        XCTAssertEqual(code(try request(host, "overview")), "budgetExceeded")
        _ = try request(host, "authorizeApp", ["id":"overview"])
        XCTAssertEqual(code(try request(host, "authorizeApp", ["id":"overview"])), "budgetExceeded")
        let oversized = try XCTUnwrap(JSONSerialization.jsonObject(with: host.handle(Data(repeating:32,count:65537))) as? [String:Any])
        XCTAssertEqual(code(oversized), "budgetExceeded"); XCTAssertNil(oversized["data"])
        let root = child("unsafe-library-integer")
        try PortableInstance.createSynthetic(at: root, databaseVersion: 3)
        let refs = try SafeFS.resolve(root, "logical-storage/references.json")
        var references = try SafeFS.read([VolumeReference].self, refs)
        references[0].estimatedBytes = 9_007_199_254_740_992
        try SafeFS.write(references, to: refs)
        let unsafeHost = try bridge(PrototypePlatformAPI(root: root))
        XCTAssertEqual(code(try request(unsafeHost, "listLibraries")), "invalidResponse")
        XCTAssertEqual(code(try request(unsafeHost, "overview")), "invalidResponse")
    }
    func testFileMessagesKeepLibraryPermissionsAndNeverAcceptHostRootParameters() throws {
        let api = try service(), owner = try api.beginFixtureSession(userID:"fixture-owner")
        let reader = try api.beginFixtureSession(userID:"fixture-family")
        let reference = try XCTUnwrap(api.fixtureVolumes.references.first)
        let observation = FixtureVolumeObservation(volumeID:reference.volumeID,displayName:"fixture",authorized:true)
        let root = api.root.appendingPathComponent("host-binding/fixtures/volumes/" + observation.mountID.uuidString.lowercased()).appendingPathComponent(reference.relativePath)
        try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true)
        try Data("plain <script>text</script>".utf8).write(to:root.appendingPathComponent("note.txt"))
        try api.updateFixtureVolumeInventory([observation],session:owner)
        let preview = try api.previewFixtureVolumeBinding(libraryID:reference.libraryID,access:.readOnly,session:owner)
        try api.commitFixtureVolumeBinding(preview,confirmed:true,session:owner)
        try api.authorizeFixtureLibraryContent(libraryID:reference.libraryID,session:owner)
        let ownerHost = try DesktopBridge(api:api,session:owner), readerHost = try DesktopBridge(api:api,session:reader)
        XCTAssertEqual(code(try request(readerHost,"listFiles",["libraryID":reference.libraryID])), "denied")
        try api.setFixtureLibraryReaders(["fixture-family"],libraryID:reference.libraryID,session:owner)
        XCTAssertEqual((try request(readerHost,"listLibraries")["data"] as? [Any])?.count,1)
        let files = try XCTUnwrap(request(readerHost,"listFiles",["libraryID":reference.libraryID])["data"] as? [[String:Any]])
        XCTAssertEqual(files.first?["relativePath"] as? String,"note.txt"); XCTAssertNil(files.first?["nameKey"])
        let text = try XCTUnwrap(request(readerHost,"previewFile",["libraryID":reference.libraryID,"relativePath":"note.txt"])["data"] as? [String:Any])
        XCTAssertEqual(text["text"] as? String,"plain <script>text</script>")
        XCTAssertEqual(code(try request(ownerHost,"previewFile",["libraryID":reference.libraryID,"relativePath":"../outside.txt"])), "unsafePath")
        try api.setFixtureLibraryReaders([],libraryID:reference.libraryID,session:owner)
        XCTAssertEqual(code(try request(readerHost,"previewFile",["libraryID":reference.libraryID,"relativePath":"note.txt"])), "denied")
    }
    func testReadOnlyModeStillListsJobsButRefusesMutatingMessages() throws {
        let api = try service(), host = try bridge(api)
        var binding = try SafeFS.read(HostBinding.self,SafeFS.resolve(api.root,"host-binding/binding.json"))
        binding.mode = "read_only_recovery"; try SafeFS.write(binding,to:SafeFS.resolve(api.root,"host-binding/binding.json"))
        XCTAssertNotNil(try request(host,"listJobs")["data"])
        for (method,params): (String,[String:Any]) in [
            ("submitLabelJob",["id":"x","key":"x","value":"x"]),("cancelJob",["id":"x"]),
            ("pollEvents",["consumerID":"x"]),("acknowledgeEvents",["consumerID":"x","through":0])] {
            XCTAssertEqual(code(try request(host,method,params)),"readOnly")
        }
    }
}
