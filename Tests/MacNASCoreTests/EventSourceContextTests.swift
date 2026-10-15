import Foundation
import XCTest
@testable import MacNASCore

final class EventSourceContextTests:DurableLab {
    func request(_ bridge:DesktopBridge,_ method:String="eventConsumerObservation",_ params:[String:Any]=["consumerID":"consumer"]) throws -> [String:Any] {
        let bytes=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":method,"params":params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:bridge.handle(bytes)) as? [String:Any])
    }
    func bridge(_ api:PrototypePlatformAPI,bytes:Int=1_048_576) throws -> DesktopBridge {
        try DesktopBridge(api:api,session:api.beginFixtureSession(userID:"fixture-owner"),limits:BridgeLimits(responseBytes:bytes))
    }
    func code(_ response:[String:Any]) -> String? { (response["error"] as? [String:Any])?["code"] as? String }
    func testSameDatabaseNewAPIAndSessionRetainContextWithoutCreatingConsumers() throws {
        let (root,db,_)=try fixture(),api=try PrototypePlatformAPI(root:root),session=try api.beginFixtureSession(userID:"fixture-owner")
        let before=try db.contentDigest(),first=try api.jobEventConsumerObservation(consumerID:"consumer",session:session)
        api.endSession(session)
        let next=try PrototypePlatformAPI(root:root),fresh=try next.beginFixtureSession(userID:"fixture-owner")
        let second=try next.jobEventConsumerObservation(consumerID:"different-consumer",session:fresh)
        XCTAssertEqual(first.context,second.context);XCTAssertEqual(first.context.scopeID.count,64)
        XCTAssertEqual(first.status.visibility,.notVisible);XCTAssertEqual(second.status.visibility,.notVisible)
        XCTAssertEqual(try db.contentDigest(),before)
    }
    func testInstanceDatabaseGenerationRoleModeAndUserAllSeparateContext() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner")
        func context() throws -> EventSourceContext { try api.jobEventConsumerObservation(consumerID:"consumer",session:owner).context }
        let original=try context(),family=try api.beginFixtureSession(userID:"fixture-family")
        XCTAssertNotEqual(original,try api.jobEventConsumerObservation(consumerID:"consumer",session:family).context)
        let configPath=try SafeFS.resolve(root,"config/platform.json"),config=try SafeFS.read(PortableConfig.self,configPath)
        var reader=config;reader.users[0].role="reader";try SafeFS.write(reader,to:configPath)
        XCTAssertNotEqual(original,try context());try SafeFS.write(config,to:configPath)
        let identityPath=try SafeFS.resolve(root,"instance.json"),identity=try SafeFS.read(InstanceIdentity.self,identityPath)
        var generated=identity;generated.generation+=1;try SafeFS.write(generated,to:identityPath)
        XCTAssertNotEqual(original,try context());try SafeFS.write(identity,to:identityPath)
        let bindingPath=try SafeFS.resolve(root,"host-binding/binding.json"),binding=try SafeFS.read(HostBinding.self,bindingPath)
        var recovery=binding;recovery.mode="read_only_recovery";try SafeFS.write(recovery,to:bindingPath)
        XCTAssertNotEqual(original,try context())
        let alternate=try StateStore.createSynthetic(schemaVersion:3);var rebound=binding;rebound.databaseName=alternate.databaseName
        try SafeFS.write(rebound,to:bindingPath);XCTAssertNotEqual(original,try context())
        try SafeFS.write(binding,to:bindingPath)
        let (other,_,_)=try fixture("other"),different=try PrototypePlatformAPI(root:other)
        XCTAssertNotEqual(original,try different.jobEventConsumerObservation(consumerID:"consumer",session:different.beginFixtureSession(userID:"fixture-owner")).context)
    }
    func testReadOnlyObservationPreservesDigestAndHidesForeignConsumers() throws {
        let (root,db,q)=try fixture();try submit(q);_=try q.poll(consumerID:"consumer",audience:audience)
        let api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner"),family=try api.beginFixtureSession(userID:"fixture-family")
        let p=try SafeFS.resolve(root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,p)
        binding.mode="read_only_recovery";try SafeFS.write(binding,to:p);try db.setDefaultReadOnly()
        let before=try db.contentDigest()
        XCTAssertEqual(try api.jobEventConsumerObservation(consumerID:"consumer",session:owner).status.visibility,.visible)
        let hidden=try api.jobEventConsumerObservation(consumerID:"consumer",session:family)
        XCTAssertEqual(hidden.status.visibility,.notVisible);XCTAssertNil(hidden.status.acknowledgedThrough)
        XCTAssertEqual(try db.contentDigest(),before)
    }
    func testProjectionRevocationAndBindingChangesDoNotReturnOldObservation() throws {
        let (root,_,_)=try fixture(),api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner")
        denied(.denied) { _=try api.withJobEventConsumerObservation(consumerID:"consumer",session:owner) { value in api.endSession(owner);return value } }
        let fresh=try api.beginFixtureSession(userID:"fixture-owner"),other=try StateStore.createSynthetic(schemaVersion:3)
        let p=try SafeFS.resolve(root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,p)
        denied(.denied) { _=try api.withJobEventConsumerObservation(consumerID:"consumer",session:fresh) { value in binding.databaseName=other.databaseName;try SafeFS.write(binding,to:p);return value } }
    }
    func testBridgePinsSourceBeforeDeliveryAndRefusesACKAfterRebindingWithoutMutation() throws {
        let (root,originalDB,q)=try fixture();try submit(q)
        let api=try PrototypePlatformAPI(root:root),host=try bridge(api);defer { host.close() }
        let delivered=try XCTUnwrap(request(host,"pollEvents",["consumerID":"consumer"])["data"] as? [[String:Any]])
        let through=try XCTUnwrap(delivered.last?["sequence"] as? Int)
        let initial=try XCTUnwrap(request(host)["data"] as? [String:Any])
        let other=try StateStore.createSynthetic(schemaVersion:3),otherQ=try DurableJobQueue(store:other)
        try submit(otherQ);_=try otherQ.poll(consumerID:"consumer",audience:audience)
        let before=try other.contentDigest(),p=try SafeFS.resolve(root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,p)
        let originalBinding=binding,source=try api.jobEventConsumerObservation(consumerID:"consumer",session:api.beginFixtureSession(userID:"fixture-owner")).context
        let writeSession=try api.beginFixtureSession(userID:"fixture-owner")
        denied(.denied) { _=try api.withBoundJobEventQueue(context:source,session:writeSession) { captured,audience in
            binding.databaseName=other.databaseName;try SafeFS.write(binding,to:p)
            try captured.acknowledge(consumerID:"consumer",through:Int64(through),audience:audience)
        } }
        XCTAssertEqual(try other.contentDigest(),before)
        XCTAssertEqual(try originalDB.rows("SELECT ack_sequence FROM macnas.event_consumers WHERE id='consumer';"),[[String(through)]])
        try SafeFS.write(originalBinding,to:p)
        binding.databaseName=other.databaseName;try SafeFS.write(binding,to:p)
        XCTAssertEqual(code(try request(host)),"denied")
        XCTAssertEqual(code(try request(host,"acknowledgeEvents",["consumerID":"consumer","through":through])),"denied")
        XCTAssertEqual(try other.contentDigest(),before)
        let fresh=try bridge(PrototypePlatformAPI(root:root));defer { fresh.close() }
        let next=try XCTUnwrap(request(fresh)["data"] as? [String:Any])
        XCTAssertNotEqual((initial["context"] as? [String:Any])?["scopeID"] as? String,(next["context"] as? [String:Any])?["scopeID"] as? String)
    }
    func testOpaqueVersionedWireRejectsExtraParametersAndEncodingFailureIsReadOnly() throws {
        let (root,db,_)=try fixture(),host=try bridge(PrototypePlatformAPI(root:root));defer { host.close() }
        let before=try db.contentDigest(),value=try XCTUnwrap(request(host)["data"] as? [String:Any])
        XCTAssertEqual(Set(value.keys),["observationVersion","context","status"])
        let context=try XCTUnwrap(value["context"] as? [String:Any])
        XCTAssertEqual(Set(context.keys),["contextVersion","source","scopeID","userID","role","mode"])
        XCTAssertEqual(context["contextVersion"] as? Int,1);XCTAssertEqual(context["source"] as? String,"fixture-host")
        let encoded=String(decoding:try JSONSerialization.data(withJSONObject:value),as:UTF8.self)
        for secret in [root.path,db.databaseName,db.tools.socket.path,"databaseOID","relationOID"] { XCTAssertFalse(encoded.contains(secret)) }
        for params:[String:Any] in [[:],["consumerID":"consumer","scopeID":"chosen"],["consumerID":"consumer","userID":"fixture-family"],["consumerID":"consumer","through":0]] {
            XCTAssertEqual(code(try request(host,"eventConsumerObservation",params)),"invalidInput")
        }
        let small=try bridge(PrototypePlatformAPI(root:root),bytes:128);defer { small.close() }
        XCTAssertEqual(code(try request(small)),"budgetExceeded");XCTAssertEqual(try db.contentDigest(),before)
    }
    func testRecreatedConsumerRelationInvalidatesPinnedHostContext() throws {
        let (root,db,_)=try fixture(),host=try bridge(PrototypePlatformAPI(root:root));defer { host.close() }
        XCTAssertNotNil(try request(host)["data"])
        // A new event-log incarnation must not inherit an old equality context merely by reusing its name.
        try db.execute("ALTER TABLE macnas.event_consumers RENAME TO old_event_consumers; CREATE TABLE macnas.event_consumers (LIKE macnas.old_event_consumers INCLUDING ALL);")
        XCTAssertEqual(code(try request(host)),"denied")
    }
}
