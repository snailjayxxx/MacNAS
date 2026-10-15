import Foundation
import CryptoKit
import Darwin
import XCTest
@testable import MacNASCore

private final class JobThreadResult:@unchecked Sendable {
    let lock=NSLock()
    var errors:[Error]=[]
    var jobs:[String]=[]
    func add(_ job:String?) { lock.lock();defer { lock.unlock() };if let job { jobs.append(job) } }
    func fail(_ error:Error) { lock.lock();defer { lock.unlock() };errors.append(error) }
    func check() throws { lock.lock();defer { lock.unlock() };if let error=errors.first { throw error } }
}
class DurableLab:LabTest {
    let audience=JobAudience.user("fixture-owner")
    func fixture(_ name:String="schema3",version:Int=3) throws -> (URL,StateStore,DurableJobQueue) {
        let root=child(name);try PortableInstance.createSynthetic(at:root,databaseVersion:version)
        let db=try PortableInstance.store(root)
        return (root,db,try DurableJobQueue(store:db))
    }
    @discardableResult func submit(_ queue:DurableJobQueue,id:String="durable",attempts:Int=3) throws -> DurableJob {
        try queue.submit(id:id,key:id,kind:.label,payload:JobPayload(target:id,value:"中日・'quoted'"),audience:audience,maxAttempts:attempts)
    }
    func lease(_ queue:DurableJobQueue,seconds:TimeInterval=5) throws -> JobLease { try XCTUnwrap(queue.claim(leaseSeconds:seconds)) }
    func sqlProcess(_ db:StateStore,_ sql:String,app:String="fixture-event-writer") throws -> Process {
        let process=Process();process.executableURL=db.tools.bin.appendingPathComponent("psql")
        process.arguments=try db.tools.connection(db.databaseName)+["-X","-q","--set","ON_ERROR_STOP=1","-c",sql]
        process.environment=db.tools.environment(application:app)
        process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
        try process.run();return process
    }
    func waitForSleep(_ db:StateStore,app:String="fixture-event-writer") throws {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while ProcessInfo.processInfo.systemUptime<deadline {
            if try db.tools.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='\(app)' AND wait_event='PgSleep';",database:"postgres",admin:true)=="1" { return }
            Thread.sleep(forTimeInterval:0.01)
        }
        XCTFail("fixture transaction never reached its observable checkpoint")
    }
}

final class DurableJobTests:DurableLab {
    func testSubmissionIdempotencyBindsPayloadAndAudience() throws {
        let (_,db,q)=try fixture()
        let first=try submit(q),repeatJob=try q.submit(id:"different-id",key:"durable",kind:.label,payload:first.payload,audience:audience)
        XCTAssertEqual(first,repeatJob)
        denied(.collision) { _=try q.submit(id:"different-id",key:"durable",kind:.label,payload:JobPayload(target:"secret",value:"changed"),audience:audience) }
        denied(.collision) { _=try q.submit(id:"different-id",key:"durable",kind:.label,payload:first.payload,audience:.user("fixture-family")) }
        XCTAssertEqual(try db.rows("SELECT count(*),max(sequence) FROM macnas.job_events;"),[["1","1"]])
        XCTAssertEqual(try db.rows("SELECT next_sequence FROM macnas.event_clock;"),[["2"]])
    }
    func testPreparedCheckpointAndEffectAreAtomicWithEventsAndCounter() throws {
        let (_,db,q)=try fixture();try submit(q)
        let l=try lease(q)
        denied(.database) { try q.prepare(l,injectFailure:true) }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.job_steps;"),[["0"]])
        XCTAssertEqual(try db.rows("SELECT next_sequence FROM macnas.event_clock;"),[["3"]])
        try q.prepare(l)
        denied(.database) { try q.finish(l,injectFailure:true) }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.labels WHERE id='durable';"),[["0"]])
        XCTAssertEqual(try db.rows("SELECT step FROM macnas.job_steps;"),[["0"]])
        XCTAssertEqual(try db.rows("SELECT next_sequence FROM macnas.event_clock;"),[["4"]])
        try q.finish(l)
        denied(.staleState) { try q.finish(l) }
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id='durable';"),[["中日・'quoted'"]])
        XCTAssertEqual(try db.rows("SELECT effects,state FROM macnas.jobs WHERE id='durable';"),[["1","completed"]])
        XCTAssertEqual(try db.rows("SELECT type FROM macnas.job_events ORDER BY sequence;"),[["queued"],["claimed"],["checkpoint"],["completed"]])
    }
    func testConcurrentClaimersCannotOwnTheSameJob() throws {
        let (root,db,q)=try fixture();try submit(q)
        let done=DispatchGroup(),result=JobThreadResult(),name=db.databaseName
        for _ in 0..<2 {
            done.enter()
            DispatchQueue.global().async {
                defer { done.leave() }
                do { let queue=try DurableJobQueue(store:StateStore(databaseName:name,instanceRoot:root));result.add(try queue.claim()?.job.id) }
                catch { result.fail(error) }
            }
        }
        XCTAssertEqual(done.wait(timeout:.now()+10),.success);try result.check()
        XCTAssertEqual(result.jobs,["durable"])
        XCTAssertEqual(try db.rows("SELECT attempts FROM macnas.jobs WHERE id='durable';"),[["1"]])
    }
    func testSkipLockedJobDoesNotBlockOtherRunnableJob() throws {
        let (_,db,q)=try fixture();try submit(q,id:"a");try submit(q,id:"b")
        let p=try sqlProcess(db,"BEGIN; SELECT id FROM macnas.jobs WHERE id='a' FOR UPDATE; SELECT pg_sleep(5); COMMIT;")
        defer { ChildControl.stop(p) };try waitForSleep(db)
        XCTAssertEqual(try lease(q).job.id,"b")
    }
    func testExpiredLeaseCannotRenewCheckpointOrPublishAfterReclaim() throws {
        let (_,db,q)=try fixture();try submit(q)
        let old=try lease(q,seconds:0.3);Thread.sleep(forTimeInterval:0.35)
        let next=try lease(q)
        XCTAssertNotEqual(old.token,next.token)
        denied(.staleState) { try q.renew(old) };denied(.staleState) { try q.prepare(old) };denied(.staleState) { try q.finish(old) }
        try q.renew(next);try q.prepare(next);try q.finish(next)
        XCTAssertEqual(try db.rows("SELECT attempts,effects FROM macnas.jobs WHERE id='durable';"),[["2","1"]])
    }
    func testRetryBackoffAndAttemptLimitPersistAcrossQueueRestart() throws {
        let (root,db,q)=try fixture();try submit(q,attempts:2)
        let first=try lease(q);try q.prepare(first);try q.deferWork(first,error:.timedOut,backoff:3)
        XCTAssertNil(try q.claim())
        XCTAssertEqual(try db.rows("SELECT state,attempts,next_run_at>clock_timestamp() FROM macnas.jobs WHERE id='durable';"),[["queued","1","t"]])
        try db.execute("UPDATE macnas.jobs SET next_run_at='epoch' WHERE id='durable';")
        let restart=try DurableJobQueue(store:StateStore(databaseName:db.databaseName,instanceRoot:root)),second=try lease(restart)
        try restart.deferWork(second,error:.database,backoff:0.1)
        XCTAssertEqual(try restart.jobs(audience:audience).first?.state,"failed")
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.job_steps WHERE step=0;"),[["1"]])
        XCTAssertNil(try restart.claim())
    }
    func testExpiredFinalAttemptIsFailedWithoutApplyingEffect() throws {
        let (_,db,q)=try fixture();try submit(q,attempts:1)
        _=try lease(q,seconds:0.1);Thread.sleep(forTimeInterval:0.15)
        XCTAssertNil(try q.claim())
        XCTAssertEqual(try db.rows("SELECT state,last_error,effects FROM macnas.jobs WHERE id='durable';"),[["failed","attemptsExhausted","0"]])
    }
    func testCancellationInvalidatesLeaseAndIsIdempotent() throws {
        let (_,db,q)=try fixture();try submit(q)
        let l=try lease(q);try q.prepare(l)
        XCTAssertEqual(try q.cancel(id:l.job.id,audience:audience).state,"cancelled")
        let digest=try db.contentDigest()
        _=try q.cancel(id:l.job.id,audience:audience)
        XCTAssertEqual(try db.contentDigest(),digest)
        denied(.staleState) { try q.finish(l) }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.labels WHERE id='durable';"),[["0"]])
        denied(.denied) { _=try q.cancel(id:l.job.id,audience:.user("fixture-family")) }
    }
    func testMissingVolumeWaitsWithoutBurningAttemptsAndResumesUsingLogicalID() throws {
        let (root,db,q)=try fixture(),volume=UUID()
        let library=root.appendingPathComponent("host-binding/fixtures")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let bytes=Data("own synthetic file only".utf8);try bytes.write(to:library.appendingPathComponent("合成.txt"))
        _=try q.submit(id:"hash",key:"hash",kind:.fixtureHash,payload:JobPayload(target:"fixture-hash",relativePath:"合成.txt",volumeID:volume),audience:audience)
        denied(.missingVolume) { _=try q.workOne() }
        XCTAssertEqual(try db.rows("SELECT state,attempts FROM macnas.jobs WHERE id='hash';"),[["waiting_for_volume","0"]])
        try db.execute("UPDATE macnas.jobs SET next_run_at='epoch' WHERE id='hash';")
        _=try q.workOne(inventory:[MountedVolume(id:volume,displayName:"renamed fixture",authorized:true)])
        let expected=SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined()
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id='fixture-hash';"),[[expected]])
    }
    func testPreparedFileDigestSurvivesRestartWithoutReadingFileAgain() throws {
        let (root,db,q)=try fixture(),volume=UUID(),library=root.appendingPathComponent("host-binding/fixtures")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        let file=library.appendingPathComponent("own.txt");try Data("checkpoint".utf8).write(to:file)
        _=try q.submit(id:"hash",key:"hash",kind:.fixtureHash,payload:JobPayload(target:"hash",relativePath:"own.txt",volumeID:volume),audience:audience)
        let l=try lease(q,seconds:1)
        try q.prepare(l,inventory:[MountedVolume(id:volume,displayName:"fixture",authorized:true)])
        try FileManager.default.removeItem(at:file)
        try db.execute("UPDATE macnas.jobs SET lease_until='epoch' WHERE id='hash';")
        XCTAssertEqual(try q.workOne(),"hash")
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.job_steps WHERE job_id='hash';"),[["2"]])
    }
    func testFixtureWorkerRejectsUnauthorizedVolumeAndEscapePaths() throws {
        let (_,db,q)=try fixture(),volume=UUID()
        denied(.unsafePath) { _=try q.submit(id:"bad",key:"bad",kind:.fixtureHash,payload:JobPayload(target:"bad",relativePath:"../outside",volumeID:volume),audience:audience) }
        _=try q.submit(id:"denied-volume",key:"volume",kind:.fixtureHash,payload:JobPayload(target:"bad",relativePath:"file",volumeID:volume),audience:audience)
        denied(.denied) { _=try q.workOne(inventory:[MountedVolume(id:volume,displayName:"not authorized")]) }
        XCTAssertEqual(try db.rows("SELECT state FROM macnas.jobs WHERE id='denied-volume';"),[["failed"]])
    }
    func testWorkerProcessSIGKILLBeforeAndAfterEffectDoesNotDuplicateEffect() throws {
        let bin=try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        for point in ["prepared","completed"] {
            let (root,db,q)=try fixture(point);try submit(q)
            let p=Process();p.executableURL=URL(fileURLWithPath:bin).appendingPathComponent("macnas")
            p.arguments=["jobs","work-once","--source",root.path,"--lease-seconds","1","--synthetic-test-hold-after",point]
            p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice;try p.run()
            defer { if p.isRunning { ChildControl.stop(p) } }
            let marker=root.appendingPathComponent("host-binding/job-test-checkpoint"),deadline=ProcessInfo.processInfo.systemUptime+5
            while !FileManager.default.fileExists(atPath:marker.path) && p.isRunning && ProcessInfo.processInfo.systemUptime<deadline { Thread.sleep(forTimeInterval:0.01) }
            XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
            XCTAssertNil(try q.claim(),"a live unexpired worker owns the job")
            kill(p.processIdentifier,SIGKILL);p.waitUntilExit();XCTAssertEqual(p.terminationReason,.uncaughtSignal)
            if point=="prepared" { Thread.sleep(forTimeInterval:1.05) }
            let restarted=try DurableJobQueue(store:StateStore(databaseName:db.databaseName,instanceRoot:root))
            _=try restarted.workOne()
            XCTAssertEqual(try db.rows("SELECT state,effects FROM macnas.jobs WHERE id='durable';"),[["completed","1"]])
            XCTAssertEqual(try db.rows("SELECT type,count(*) FROM macnas.job_events WHERE type IN ('checkpoint','completed') GROUP BY type ORDER BY type;"),[["checkpoint","1"],["completed","1"]])
        }
    }
}

final class JobOutboxTests:DurableLab {
    func testRedeliveryAcknowledgementRollbackAndReceiptDeduplication() throws {
        let (root,db,q)=try fixture();try submit(q);_=try q.workOne()
        let first=try q.poll(consumerID:"desktop",audience:audience,limit:2)
        XCTAssertEqual(first.map(\.sequence),[1,2])
        XCTAssertEqual(try q.poll(consumerID:"desktop",audience:audience,limit:2),first)
        denied(.denied) { try q.acknowledge(consumerID:"desktop",through:4,audience:audience) }
        denied(.database) { try q.acknowledge(consumerID:"desktop",through:2,audience:audience,injectFailure:true) }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.event_receipts;"),[["0"]])
        let restarted=try DurableJobQueue(store:StateStore(databaseName:db.databaseName,instanceRoot:root))
        XCTAssertEqual(try restarted.poll(consumerID:"desktop",audience:audience,limit:2),first)
        try restarted.acknowledge(consumerID:"desktop",through:2,audience:audience)
        try restarted.acknowledge(consumerID:"desktop",through:2,audience:audience)
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.event_receipts;"),[["2"]])
        let rest=try restarted.poll(consumerID:"desktop",audience:audience)
        XCTAssertEqual(rest.map(\.sequence),[3,4])
        try restarted.acknowledge(consumerID:"desktop",through:4,audience:audience)
        XCTAssertTrue(try restarted.poll(consumerID:"desktop",audience:audience).isEmpty)
        denied(.denied) { try restarted.acknowledge(consumerID:"desktop",through:2,audience:audience) }
    }
    func testSequenceCommitOrderDoesNotSkipUncommittedEvent() throws {
        let (root,db,q)=try fixture();try submit(q,id:"a")
        let p=try sqlProcess(db,"""
        BEGIN;
        UPDATE macnas.event_clock SET next_sequence=next_sequence+1 WHERE singleton;
        UPDATE macnas.jobs SET revision=revision+1 WHERE id='a';
        INSERT INTO macnas.job_events SELECT next_sequence-1,'a',2,'fixture-owner',NULL,'held','queued' FROM macnas.event_clock;
        SELECT pg_sleep(2); COMMIT;
        """)
        defer { if p.isRunning { ChildControl.stop(p) } };try waitForSleep(db)
        let done=DispatchSemaphore(value:0),result=JobThreadResult(),name=db.databaseName
        DispatchQueue.global().async {
            defer { done.signal() }
            do { let queue=try DurableJobQueue(store:StateStore(databaseName:name,instanceRoot:root));_=try queue.submit(id:"b",key:"b",kind:.label,payload:JobPayload(target:"b"),audience:.user("fixture-owner"));result.add("b") }
            catch { result.fail(error) }
        }
        XCTAssertEqual(try q.poll(consumerID:"ordered",audience:audience).map(\.sequence),[1])
        try q.acknowledge(consumerID:"ordered",through:1,audience:audience)
        XCTAssertEqual(done.wait(timeout:.now()+8),.success);try result.check();p.waitUntilExit()
        XCTAssertEqual(try q.poll(consumerID:"ordered",audience:audience).map(\.sequence),[2,3])
    }
    func testUserAppAndConsumerScopesNeverLeakAcrossAudiences() throws {
        let (_,_,q)=try fixture()
        try submit(q,id:"owner")
        _=try q.submit(id:"family",key:"family",kind:.label,payload:JobPayload(target:"family"),audience:.user("fixture-family"))
        _=try q.submit(id:"app",key:"app",kind:.appValue,payload:JobPayload(target:"state"),audience:.app(.diagnostics))
        XCTAssertEqual(try q.jobs(audience:audience).map(\.id),["owner"])
        XCTAssertEqual(try q.jobs(audience:.app(.diagnostics)).map(\.id),["app"])
        XCTAssertTrue(try q.jobs(audience:.app(.fileIndex)).isEmpty)
        XCTAssertEqual(try q.poll(consumerID:"private",audience:audience).map(\.job_id),["owner"])
        denied(.denied) { _=try q.poll(consumerID:"private",audience:.user("fixture-family")) }
        denied(.denied) { try q.acknowledge(consumerID:"private",through:1,audience:.app(.diagnostics)) }
        denied(.denied) { _=try q.cancel(id:"app",audience:audience) }
        denied(.denied) { _=try q.submit(id:"escalate",key:"escalate",kind:.label,payload:JobPayload(target:"core"),audience:.app(.diagnostics)) }
    }
}
