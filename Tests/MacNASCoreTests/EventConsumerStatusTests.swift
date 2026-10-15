import Foundation
import XCTest
@testable import MacNASCore

final class EventConsumerStatusTests:DurableLab {
    func host(_ api:PrototypePlatformAPI,user:String="fixture-owner",bytes:Int=1_048_576) throws -> DesktopBridge {
        try DesktopBridge(api:api,session:api.beginFixtureSession(userID:user),limits:BridgeLimits(responseBytes:bytes))
    }
    func message(_ bridge:DesktopBridge,params:[String:Any]=["consumerID":"consumer"]) throws -> [String:Any] {
        let request=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":"eventConsumerStatus","params":params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:bridge.handle(request)) as? [String:Any])
    }
    func error(_ response:[String:Any]) -> String? { (response["error"] as? [String:Any])?["code"] as? String }
    func testMissingForeignUserAndAppRowsAreIndistinguishableWithoutWrites() throws {
        let (_,db,q)=try fixture(),id="private-consumer"
        let before=try db.contentDigest(),missing=try q.consumerStatus(consumerID:id,audience:audience)
        XCTAssertEqual(missing.visibility,.notVisible);XCTAssertNil(missing.acknowledgedThrough);XCTAssertNil(missing.deliveredThrough)
        XCTAssertEqual(try db.contentDigest(),before)
        _=try q.poll(consumerID:id,audience:.user("fixture-family"))
        _=try q.poll(consumerID:"app-consumer",audience:.app(.diagnostics))
        let seeded=try db.contentDigest()
        XCTAssertEqual(try q.consumerStatus(consumerID:id,audience:audience),missing)
        XCTAssertEqual(try q.consumerStatus(consumerID:"app-consumer",audience:audience).visibility,.notVisible)
        XCTAssertEqual(try q.consumerStatus(consumerID:id,audience:.app(.diagnostics)).visibility,.notVisible)
        XCTAssertEqual(try q.consumerStatus(consumerID:"app-consumer",audience:.app(.diagnostics)).visibility,.visible)
        XCTAssertEqual(try db.contentDigest(),seeded)
    }
    func testDeliveryPartialACKAndRestartReturnPersistedPositionsWithoutMutation() throws {
        let (root,db,q)=try fixture();try submit(q,id:"a");try submit(q,id:"b")
        _=try q.cancel(id:"b",audience:audience)
        let first=try XCTUnwrap(q.poll(consumerID:"consumer",audience:audience,limit:1).last)
        var result=try q.consumerStatus(consumerID:"consumer",audience:audience)
        XCTAssertEqual(result.acknowledgedThrough,0);XCTAssertEqual(result.deliveredThrough,first.sequence)
        try q.acknowledge(consumerID:"consumer",through:first.sequence,audience:audience)
        let last=try XCTUnwrap(q.poll(consumerID:"consumer",audience:audience).last),before=try db.contentDigest()
        result=try q.consumerStatus(consumerID:"consumer",audience:audience)
        XCTAssertEqual(result.acknowledgedThrough,first.sequence);XCTAssertEqual(result.deliveredThrough,last.sequence)
        XCTAssertEqual(try db.contentDigest(),before)
        try q.acknowledge(consumerID:"consumer",through:last.sequence,audience:audience)
        let restarted=try DurableJobQueue(store:StateStore(databaseName:db.databaseName,instanceRoot:root))
        result=try restarted.consumerStatus(consumerID:"consumer",audience:audience)
        XCTAssertEqual(result.acknowledgedThrough,last.sequence);XCTAssertEqual(result.deliveredThrough,last.sequence)
    }
    func testOwnEmptyConsumerIsVisibleAtZeroAndQueryDoesNotCreateAnother() throws {
        let (_,db,q)=try fixture();XCTAssertTrue(try q.poll(consumerID:"empty",audience:audience).isEmpty)
        let before=try db.contentDigest(),result=try q.consumerStatus(consumerID:"empty",audience:audience)
        XCTAssertEqual(result.visibility,.visible);XCTAssertEqual(result.acknowledgedThrough,0);XCTAssertEqual(result.deliveredThrough,0)
        XCTAssertEqual(try q.consumerStatus(consumerID:"absent",audience:audience).visibility,.notVisible)
        XCTAssertEqual(try db.contentDigest(),before);XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.event_consumers;"),[["1"]])
    }
    func testConsumerByteBudgetsAndQuotedUnicodeIDsStayData() throws {
        let (_,db,q)=try fixture()
        for id in ["",String(repeating:"x",count:129),String(repeating:"中",count:43),"nul\0id","line\nend","line\rend"] {
            denied(.invalidSchema) { _=try q.consumerStatus(consumerID:id,audience:self.audience) }
        }
        for id in [String(repeating:"x",count:128),String(repeating:"中",count:42),"o'hara🐚'; SELECT 'data'--"] {
            XCTAssertEqual(try q.consumerStatus(consumerID:id,audience:audience).visibility,.notVisible)
            _=try q.poll(consumerID:id,audience:audience)
            XCTAssertEqual(try q.consumerStatus(consumerID:id,audience:audience).consumerID,id)
        }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.event_consumers;"),[["3"]])
    }
    func testRecoveryQueriesWorkOnDatabaseEnforcedReadOnlyAndLeaveDigestUnchanged() throws {
        let (root,db,q)=try fixture();try submit(q)
        _=try q.poll(consumerID:"consumer",audience:audience)
        let api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        let path=try SafeFS.resolve(root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,path)
        binding.mode="unknown_mode";try SafeFS.write(binding,to:path)
        denied(.denied) { _=try api.jobEventConsumerStatus(consumerID:"consumer",session:session) }
        try db.setDefaultReadOnly()
        let before=try db.contentDigest()
        for mode in ["read_only_recovery","rolled_back_recovery"] {
            binding.mode=mode;try SafeFS.write(binding,to:path)
            let result=try api.jobEventConsumerStatus(consumerID:"consumer",session:session)
            XCTAssertEqual(result.visibility,.visible);XCTAssertEqual(result.acknowledgedThrough,0)
            XCTAssertEqual(try api.jobEventConsumerStatus(consumerID:"absent",session:session).visibility,.notVisible)
            denied(.denied) { _=try api.jobEvents(consumerID:"consumer",session:session) }
            denied(.denied) { try api.acknowledgeJobEvents(consumerID:"consumer",through:0,session:session) }
        }
        XCTAssertEqual(try db.contentDigest(),before)
        XCTAssertEqual(try db.rows("SHOW default_transaction_read_only;"),[["on"]])
    }
    func testSessionsAudiencesAndDifferentInstancesCannotRevealConsumerState() throws {
        let (root,_,q)=try fixture();_=try q.poll(consumerID:"consumer",audience:audience)
        let api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner"),reader=try api.beginFixtureSession(userID:"fixture-family")
        XCTAssertEqual(try api.jobEventConsumerStatus(consumerID:"consumer",session:owner).visibility,.visible)
        XCTAssertEqual(try api.jobEventConsumerStatus(consumerID:"consumer",session:reader).visibility,.notVisible)
        api.endSession(owner);denied(.denied) { _=try api.jobEventConsumerStatus(consumerID:"consumer",session:owner) }
        let restarted=try PrototypePlatformAPI(root:root),fresh=try restarted.beginFixtureSession(userID:"fixture-owner")
        denied(.denied) { _=try restarted.jobEventConsumerStatus(consumerID:"consumer",session:reader) }
        XCTAssertEqual(try restarted.jobEventConsumerStatus(consumerID:"consumer",session:fresh).visibility,.visible)
        let (other,_,_)=try fixture("other"),otherAPI=try PrototypePlatformAPI(root:other),otherSession=try otherAPI.beginFixtureSession(userID:"fixture-owner")
        XCTAssertEqual(try otherAPI.jobEventConsumerStatus(consumerID:"consumer",session:otherSession).visibility,.notVisible)
    }
    func testSessionRevocationDuringFinalProjectionPreventsReturningObservation() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in api.endSession(session);return result } }
    }
    func testRoleAndModeChangesDuringProjectionAreRejected() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        let configPath=try SafeFS.resolve(root,"config/platform.json"),config=try SafeFS.read(PortableConfig.self,configPath)
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in
            var changed=config;changed.users[0].role="reader";try SafeFS.write(changed,to:configPath);return result
        } }
        try SafeFS.write(config,to:configPath)
        let path=try SafeFS.resolve(root,"host-binding/binding.json"),original=try SafeFS.read(HostBinding.self,path)
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in
            var changed=original;changed.mode="read_only_recovery";try SafeFS.write(changed,to:path);return result
        } }
    }
    func testInstanceAndDatabaseChangesDuringProjectionAreRejected() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        let identityPath=try SafeFS.resolve(root,"instance.json"),identity=try SafeFS.read(InstanceIdentity.self,identityPath)
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in
            var changed=identity;changed.instanceID=UUID();try SafeFS.write(changed,to:identityPath);return result
        } }
        try SafeFS.write(identity,to:identityPath)
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in
            var changed=identity;changed.generation+=1;try SafeFS.write(changed,to:identityPath);return result
        } }
        try SafeFS.write(identity,to:identityPath)
        let next=try StateStore.createSynthetic(schemaVersion:3),path=try SafeFS.resolve(root,"host-binding/binding.json"),binding=try SafeFS.read(HostBinding.self,path)
        denied(.denied) { _=try api.withJobEventConsumerStatus(consumerID:"absent",session:session) { result in
            var changed=binding;changed.databaseName=next.databaseName;try SafeFS.write(changed,to:path);return result
        } }
    }
    func testWireHasExactVersionedFieldsAndHidesForeignOwnership() throws {
        let (root,db,q)=try fixture();_=try q.poll(consumerID:"consumer",audience:audience)
        let api=try PrototypePlatformAPI(root:root),owner=try host(api),reader=try host(api,user:"fixture-family");defer { owner.close();reader.close() }
        let before=try db.contentDigest(),known=try XCTUnwrap(message(owner)["data"] as? [String:Any])
        XCTAssertEqual(Set(known.keys),["statusVersion","consumerID","visibility","acknowledgedThrough","deliveredThrough"])
        XCTAssertEqual(known["statusVersion"] as? Int,1);XCTAssertEqual(known["visibility"] as? String,"visible")
        let hidden=try XCTUnwrap(message(reader)["data"] as? [String:Any])
        XCTAssertEqual(hidden["visibility"] as? String,"notVisible");XCTAssertTrue(hidden["acknowledgedThrough"] is NSNull);XCTAssertTrue(hidden["deliveredThrough"] is NSNull)
        XCTAssertEqual(try db.contentDigest(),before)
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:hidden),as:UTF8.self)
        for value in [root.path,db.databaseName,"owner_user","app_id"] { XCTAssertFalse(encoded.contains(value)) }
    }
    func testWireRejectsUnknownParametersUnsafeNumbersAndEncodingBudgetWithoutChangingData() throws {
        let (root,db,q)=try fixture();_=try q.poll(consumerID:"consumer",audience:audience)
        let api=try PrototypePlatformAPI(root:root),bridge=try host(api);defer { bridge.close() }
        for params:[String:Any] in [[:],["consumerID":NSNull()],["consumerID":true],["consumerID":""],["consumerID":"consumer","through":0],["consumerID":"consumer","user":"fixture-owner"],["consumerID":"consumer","database":"other"]] {
            XCTAssertEqual(error(try message(bridge,params:params)),"invalidInput")
        }
        let small=try host(api,bytes:128);defer { small.close() };let before=try db.contentDigest()
        XCTAssertEqual(error(try message(small)),"budgetExceeded");XCTAssertEqual(try db.contentDigest(),before)
        try db.execute("UPDATE macnas.event_consumers SET delivered_sequence=9007199254740991 WHERE id='consumer';")
        XCTAssertNotNil(try message(bridge)["data"])
        try db.execute("UPDATE macnas.event_consumers SET delivered_sequence=9007199254740992 WHERE id='consumer';")
        XCTAssertEqual(error(try message(bridge)),"invalidResponse")
    }
    func testMissingDatabaseFailsWithoutFallbackOrCreatingConsumer() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        let path=try SafeFS.resolve(root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,path)
        binding.databaseName="macnas_fixture_absent_consumer";try SafeFS.write(binding,to:path)
        denied(.database) { _=try api.jobEventConsumerStatus(consumerID:"consumer",session:session) }
    }
}
