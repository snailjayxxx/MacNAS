import Foundation
import XCTest
@testable import MacNASCore

final class JobPageRegistryTests:XCTestCase {
    func scope(session:UUID=UUID(),database:String="macnas_fixture_page",user:String="owner",role:String="administrator",mode:String="synthetic_development",instance:UUID=UUID()) -> JobPageScope {
        JobPageScope(sessionID:session,instanceID:instance,databaseName:database,userID:Data(user.utf8),role:role,mode:mode)
    }
    func slice(_ more:Bool=true) -> DurableJobSlice {
        DurableJobSlice(items:[DurableJob(id:"a",idempotency_key:"key",kind:.label,owner_user:"owner",payload:JobPayload(target:"label",value:"fixture"),state:"queued",attempts:0,max_attempts:3,effects:0,revision:1,checkpoint:[:])],hasMore:more)
    }
    func page(_ registry:JobPageRegistry,_ scope:JobPageScope,_ cursor:String?=nil,size:Int=1,more:Bool=true) throws -> DurableJobPage {
        try registry.page(scope:scope,size:size,cursor:cursor,query:{ _ in self.slice(more) },validate:{},render:{$0})
    }
    func denied(_ code:NASError,_ body:() throws -> Void) {
        XCTAssertThrowsError(try body()) {XCTAssertEqual($0 as? NASError,code)}
    }
    func testScopeAndPageSizeMismatchDoNotConsumeTheOwnersCursor() throws {
        let r=JobPageRegistry(),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor)
        let variants=[scope(session:s.sessionID,database:s.databaseName,user:"other",instance:s.instanceID),
                      scope(session:s.sessionID,database:"macnas_fixture_other",instance:s.instanceID),
                      scope(session:s.sessionID,database:s.databaseName,role:"reader",instance:s.instanceID),
                      scope(session:s.sessionID,database:s.databaseName,mode:"read_only_recovery",instance:s.instanceID),
                      scope(session:s.sessionID,database:s.databaseName),scope(instance:s.instanceID)]
        for other in variants {denied(.denied){_ = try self.page(r,other,token)}}
        denied(.denied){_ = try self.page(r,s,token,size:2)}
        XCTAssertNil(try page(r,s,token,more:false).nextCursor)
        denied(.replay){_ = try self.page(r,s,token)}
    }
    func testMonotonicExpiryCoversTheWholeChainAndSlowQueries() throws {
        var time:TimeInterval=10
        let r=JobPageRegistry(lifetime:60,now:{time}),s=scope()
        let first=try XCTUnwrap(page(r,s).nextCursor);time=69
        let second=try XCTUnwrap(page(r,s,first).nextCursor);time=70
        denied(.expired){_ = try self.page(r,s,second)}
        time=100
        denied(.expired){_ = try r.page(scope:s,size:1,cursor:nil,query:{_ in time=160;return self.slice()},validate:{},render:{$0})}
    }
    func testFailedQueryValidationOrEncodingLeavesCursorRetryable() throws {
        let r=JobPageRegistry(),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor)
        denied(.database){_ = try r.page(scope:s,size:1,cursor:token,query:{_ in throw NASError.database},validate:{},render:{$0})}
        denied(.denied){_ = try r.page(scope:s,size:1,cursor:token,query:{_ in self.slice()},validate:{throw NASError.denied},render:{$0})}
        denied(.budgetExceeded){_ = try r.page(scope:s,size:1,cursor:token,query:{_ in self.slice()},validate:{},render:{_ -> DurableJobPage in throw NASError.budgetExceeded})}
        XCTAssertNotNil(try page(r,s,token).nextCursor)
    }
    func testCapacityReplacesConsumedCursorAndExpiredSlotsAreReclaimed() throws {
        var time:TimeInterval=0
        let r=JobPageRegistry(capacity:2,now:{time}),s=scope()
        let first=try XCTUnwrap(page(r,s).nextCursor),second=try XCTUnwrap(page(r,s).nextCursor)
        denied(.budgetExceeded){_ = try self.page(r,s)}
        XCTAssertNotNil(try page(r,s,first).nextCursor)
        _ = try page(r,s,second,more:false)
        XCTAssertNotNil(try page(r,s).nextCursor)
        time=60;XCTAssertNotNil(try page(r,s).nextCursor)
    }
    func testLogoutUnknownTokensAndMalformedInputsAreRejectedBeforeQuery() throws {
        let r=JobPageRegistry(),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor)
        r.endSession(s.sessionID);denied(.denied){_ = try self.page(r,s,token)}
        denied(.denied){_ = try self.page(r,s,UUID().uuidString.lowercased())}
        for cursor in ["","../sql",String(repeating:"a",count:37),"AAAAAAAA-0000-0000-0000-000000000000"] {
            denied(.invalidSchema){_ = try r.page(scope:s,size:1,cursor:cursor,query:{_ in XCTFail("query must not run");return self.slice()},validate:{},render:{$0})}
        }
        for size in [0,101] {denied(.invalidSchema){_ = try self.page(r,s,size:size)}}
    }
}

final class JobPageTests:LabTest {
    func service() throws -> PrototypePlatformAPI {
        let root=child("page-source");try PortableInstance.createSynthetic(at:root,databaseVersion:3)
        return try PrototypePlatformAPI(root:root)
    }
    func bridge(_ api:PrototypePlatformAPI) throws -> DesktopBridge {
        try DesktopBridge(api:api,session:api.beginFixtureSession(userID:"fixture-owner"))
    }
    func request(_ host:DesktopBridge,_ method:String,_ params:[String:Any]=[:]) throws -> [String:Any] {
        let input=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":method,"params":params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:host.handle(input)) as? [String:Any])
    }
    func code(_ value:[String:Any]) -> String? {(value["error"] as? [String:Any])?["code"] as? String}
    // Direct fixture inserts keep boundary tests fast; this is not an exposed API or worker path.
    func seed(_ db:StateStore,ids:[String],user:String="fixture-owner",state:String="queued") throws {
        for (index,id) in ids.enumerated() {
            try db.execute("INSERT INTO macnas.jobs(id,idempotency_key,state,kind,owner_user,payload,revision) VALUES(\(StateStore.quote(id)),\(StateStore.quote(user+"-"+String(index)+"-"+id)),\(StateStore.quote(state)),'label',\(StateStore.quote(user)),'{\"target\":\"label\",\"value\":\"fixture\"}',1);")
        }
    }
    func testKeysetUsesUTF8ByteOrderWithoutUnicodeNormalizationOrSQLInterpretation() throws {
        let api=try service(),db=try PortableInstance.store(api.root),q=try DurableJobQueue(store:db)
        let ids=["z","é","e\u{301}","中","🐚","a' OR true --","A","a"]
        try seed(db,ids:ids)
        let expected=ids.sorted{$0.utf8.lexicographicallyPrecedes($1.utf8)}.map{Data($0.utf8)}
        var result:[Data]=[],after:String?
        repeat {
            let page=try q.page(audience:.user("fixture-owner"),afterID:after,pageSize:2)
            result += page.items.map{Data($0.id.utf8)};after=page.items.last?.id
            if !page.hasMore {break}
        } while true
        XCTAssertEqual(result,expected)
        XCTAssertTrue(try q.page(audience:.user("fixture-owner"),afterID:"🐚",pageSize:1).items.isEmpty)
        for size in [0,101] {denied(.invalidSchema){_ = try q.page(audience:.user("fixture-owner"),pageSize:size)}}
        for after in ["",String(repeating:"x",count:129)] {denied(.invalidSchema){_ = try q.page(audience:.user("fixture-owner"),afterID:after)}}
    }
    func testPageBoundaryEmptyExactLimitAndLiveChanges() throws {
        let api=try service(),db=try PortableInstance.store(api.root),s=try api.beginFixtureSession(userID:"fixture-owner")
        let empty=try api.jobPage(pageSize:2,session:s);XCTAssertTrue(empty.items.isEmpty);XCTAssertNil(empty.nextCursor)
        try seed(db,ids:["b","d"])
        XCTAssertNil(try api.jobPage(pageSize:2,session:s).nextCursor)
        try seed(db,ids:["f"])
        let first=try api.jobPage(pageSize:2,session:s),cursor=try XCTUnwrap(first.nextCursor)
        try seed(db,ids:["a","e"])
        _ = try api.cancelJob(id:"f",session:s)
        let second=try api.jobPage(pageSize:2,cursor:cursor,session:s)
        XCTAssertEqual(second.items.map(\.id),["e","f"]);XCTAssertEqual(second.items.last?.state,"cancelled");XCTAssertNil(second.nextCursor)
        XCTAssertEqual(try api.jobPage(pageSize:2,session:s).items.map(\.id),["a","b"])
    }
    func testAggregateAndLegacyCapKeepLargeOverviewUsableAndAudiencePrivate() throws {
        let api=try service(),db=try PortableInstance.store(api.root),q=try DurableJobQueue(store:db),host=try bridge(api)
        try db.execute("""
        INSERT INTO macnas.jobs(id,idempotency_key,state,kind,owner_user,payload,revision)
        SELECT 'bulk-'||lpad(n::text,5,'0'),'bulk-key-'||n,'queued','label','fixture-owner','{"target":"label","value":"fixture"}',1 FROM generate_series(1,4096) n;
        INSERT INTO macnas.jobs(id,idempotency_key,state,kind,owner_user,payload,revision)
        VALUES('private','private-key','completed','label','fixture-family','{"target":"label","value":"private"}',1);
        INSERT INTO macnas.jobs(id,idempotency_key,state,kind,app_id,payload,revision)
        VALUES('app-job','app-key','queued','appValue','hello-diagnostics','{"target":"label","value":"app"}',1);
        """)
        XCTAssertEqual(try q.jobs(audience:.user("fixture-owner")).count,4096)
        try seed(db,ids:["overflow"])
        denied(.budgetExceeded){_ = try q.jobs(audience:.user("fixture-owner"))}
        XCTAssertEqual(code(try request(host,"listJobs")),"budgetExceeded")
        let info=try XCTUnwrap(request(host,"overview")["data"] as? [String:Any])
        XCTAssertEqual(info["active"] as? Int,4097);XCTAssertEqual(info["completed"] as? Int,0)
        XCTAssertEqual(try q.statistics(audience:.user("fixture-owner")),DurableJobStatistics(active:4097,completed:0,total:4097))
        XCTAssertEqual(try q.statistics(audience:.user("fixture-family")),DurableJobStatistics(active:0,completed:1,total:1))
        XCTAssertEqual(try q.page(audience:.app(.diagnostics),pageSize:1).items.map(\.id),["app-job"])
        XCTAssertEqual(try q.page(audience:.user("fixture-owner"),pageSize:100).items.count,100)
    }
    func testCursorCannotCrossSessionsHostsDatabasesOrEndedSession() throws {
        let api=try service(),db=try PortableInstance.store(api.root),s=try api.beginFixtureSession(userID:"fixture-owner")
        try seed(db,ids:["a","b","c"])
        let token=try XCTUnwrap(api.jobPage(pageSize:1,session:s).nextCursor)
        for id in ["fixture-owner","fixture-family"] {
            let other=try api.beginFixtureSession(userID:id)
            denied(.denied){_ = try api.jobPage(pageSize:1,cursor:token,session:other)}
        }
        let otherAPI=try PrototypePlatformAPI(root:api.root),other=try otherAPI.beginFixtureSession(userID:"fixture-owner")
        denied(.denied){_ = try otherAPI.jobPage(pageSize:1,cursor:token,session:other)}
        let path=try SafeFS.resolve(api.root,"host-binding/binding.json"),original=try SafeFS.read(HostBinding.self,path)
        var changed=original;changed.databaseName=try StateStore.createSynthetic(schemaVersion:3).databaseName;try SafeFS.write(changed,to:path)
        denied(.denied){_ = try api.jobPage(pageSize:1,cursor:token,session:s)}
        try SafeFS.write(original,to:path)
        XCTAssertNotNil(try api.jobPage(pageSize:1,cursor:token,session:s).nextCursor)
        let last=try XCTUnwrap(api.jobPage(pageSize:1,session:s).nextCursor)
        api.endSession(s);denied(.denied){_ = try api.jobPage(pageSize:1,cursor:last,session:s)}
    }
    func testInstanceIdentityChangeAndMissingDatabaseNeverFallBack() throws {
        let api=try service(),db=try PortableInstance.store(api.root),s=try api.beginFixtureSession(userID:"fixture-owner")
        try seed(db,ids:["a","b"])
        let token=try XCTUnwrap(api.jobPage(pageSize:1,session:s).nextCursor)
        let identityPath=try SafeFS.resolve(api.root,"instance.json"),identity=try SafeFS.read(InstanceIdentity.self,identityPath)
        var changed=identity;changed.instanceID=UUID();try SafeFS.write(changed,to:identityPath)
        denied(.denied){_ = try api.jobPage(pageSize:1,cursor:token,session:s)}
        try SafeFS.write(identity,to:identityPath)
        let path=try SafeFS.resolve(api.root,"host-binding/binding.json")
        var binding=try SafeFS.read(HostBinding.self,path);binding.databaseName="macnas_fixture_absent_page";try SafeFS.write(binding,to:path)
        XCTAssertThrowsError(try api.jobPage(pageSize:1,session:s));XCTAssertThrowsError(try api.jobStatistics(session:s))
    }
    func testWireVersionStrictParametersReplayAndReadOnlyQueries() throws {
        let api=try service(),db=try PortableInstance.store(api.root),host=try bridge(api)
        try seed(db,ids:["a","b"])
        for p:[String:Any] in [["pageSize":true],["pageSize":0],["pageSize":101],["pageSize":1.5],["pageSize":NSNull()],["cursor":NSNull()],["cursor":"sql"],["sort":"state"],["database":"other"]] {
            XCTAssertEqual(code(try request(host,"listJobsPage",p)),"invalidInput")
        }
        let page=try XCTUnwrap(request(host,"listJobsPage",["pageSize":1])["data"] as? [String:Any]),token=try XCTUnwrap(page["nextCursor"] as? String)
        XCTAssertEqual(page["pageVersion"] as? Int,1);XCTAssertEqual(page["order"] as? String,"id-utf8");XCTAssertEqual(page["consistency"] as? String,"live")
        XCTAssertEqual(code(try request(host,"listJobsPage",["pageSize":2,"cursor":token])),"denied")
        let terminal=try XCTUnwrap(request(host,"listJobsPage",["pageSize":1,"cursor":token])["data"] as? [String:Any])
        XCTAssertTrue(terminal["nextCursor"] is NSNull)
        XCTAssertEqual(code(try request(host,"listJobsPage",["pageSize":1,"cursor":token])),"replay")
        let path=try SafeFS.resolve(api.root,"host-binding/binding.json")
        var binding=try SafeFS.read(HostBinding.self,path);binding.mode="read_only_recovery";try SafeFS.write(binding,to:path)
        XCTAssertNotNil(try request(host,"listJobsPage")["data"])
        XCTAssertNotNil(try request(host,"overview")["data"])
    }
    func testBridgeEncodingFailureDoesNotConsumeCursor() throws {
        let api=try service(),db=try PortableInstance.store(api.root),s=try api.beginFixtureSession(userID:"fixture-owner")
        try seed(db,ids:["a","b"])
        let token=try XCTUnwrap(api.jobPage(pageSize:1,session:s).nextCursor)
        let host=try DesktopBridge(api:api,session:s,limits:BridgeLimits(responseBytes:128))
        XCTAssertEqual(code(try request(host,"listJobsPage",["pageSize":1,"cursor":token])),"budgetExceeded")
        XCTAssertEqual(try api.jobPage(pageSize:1,cursor:token,session:s).items.map(\.id),["b"])
    }
}
