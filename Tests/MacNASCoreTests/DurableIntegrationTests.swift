import Foundation
import XCTest
@testable import MacNASCore

final class DurableMigrationTests:DurableLab {
    func testSchemaTwoToThreeUsesIsolatedCandidateAndPreservesRevisionAndSource() throws {
        let source=child("schema2");try PortableInstance.createSynthetic(at:source,databaseVersion:2)
        let db=try PortableInstance.store(source)
        try db.execute("UPDATE app_hello_diagnostics.state SET revision=7;")
        let digest=try db.contentDigest(),target=child("schema3-readonly")
        let record=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3)
        XCTAssertEqual(record.phase,.publishedReadOnly);XCTAssertNotEqual(record.databaseName,db.databaseName)
        XCTAssertEqual(try db.schemaVersion(),2);XCTAssertEqual(try db.contentDigest(),digest)
        let candidate=try PortableInstance.store(target)
        XCTAssertEqual(try candidate.schemaVersion(),3)
        XCTAssertEqual(try candidate.contentDigest(asVersion:2),digest)
        XCTAssertEqual(try candidate.rows("SELECT revision FROM app_hello_diagnostics.state;"),[["7"]])
        XCTAssertEqual(try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3).databaseName,record.databaseName)
    }
    func testSchemaThreeDDLFailureRollsBackAndCrashAfterCommitResumes() throws {
        let source=child("schema2");try PortableInstance.createSynthetic(at:source,databaseVersion:2)
        let target=child("failed")
        denied(.database) { _=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3,fault:.failSchemaSQL) }
        let journal=try MigrationCoordinator.status(destination:target),candidate=try StateStore(databaseName:journal.databaseName)
        XCTAssertEqual(try candidate.schemaVersion(),2);XCTAssertEqual(try candidate.tableCount(),5)
        denied(.interrupted) { _=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3,fault:.at(.afterSchemaCommit)) }
        XCTAssertEqual(try candidate.schemaVersion(),3)
        let done=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3)
        XCTAssertEqual(done.databaseName,journal.databaseName)
        XCTAssertEqual(done.phase,.publishedReadOnly)
    }
    func testCandidateNewJobMetadataTamperingIsRejectedAfterMigration() throws {
        let source=child("schema2");try PortableInstance.createSynthetic(at:source,databaseVersion:2)
        let target=child("tampered")
        denied(.interrupted) { _=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3,fault:.at(.afterSchemaCommit)) }
        let record=try MigrationCoordinator.status(destination:target),candidate=try StateStore(databaseName:record.databaseName)
        try candidate.execute("UPDATE macnas.jobs SET attempts=1;")
        denied(.integrity) { _=try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new",targetVersion:3) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:target.path))
    }
    func testSchemaThreeSnapshotPreservesJobsEventsAndConsumerCursorsButRefusesWriters() throws {
        let (root,db,q)=try fixture();try submit(q)
        let lease=try self.lease(q);try q.prepare(lease)
        let events=try q.poll(consumerID:"portable-desktop",audience:audience)
        try q.acknowledge(consumerID:"portable-desktop",through:try XCTUnwrap(events.first?.sequence),audience:audience)
        let export=child("export3"),target=child("restored3")
        try PortableInstance.export(from:root,to:export)
        try PortableInstance.restore(from:export,to:target,hostID:"new",confirmCreate:true)
        let restored=try PortableInstance.store(target),restoredQueue=try DurableJobQueue(store:restored)
        XCTAssertEqual(try restored.contentDigest(),try db.contentDigest())
        XCTAssertEqual(try restoredQueue.jobs(audience:audience).first?.checkpoint,["step":"prepared"])
        denied(.denied) { _=try restoredQueue.claim() }
        denied(.denied) { _=try restoredQueue.poll(consumerID:"portable-desktop",audience:audience) }
        denied(.denied) { try restoredQueue.finish(lease) }
        // Snapshot content normalizes timestamps independently of the database's display timezone.
        _=try db.tools.sql("ALTER DATABASE \(db.databaseName) SET timezone='Asia/Tokyo';",database:"postgres",admin:true)
        XCTAssertEqual(try db.contentDigest(),try restored.contentDigest())
    }
    func testAllNewPersistentTablesParticipateInDatabaseFreeze() throws {
        let (_,db,q)=try fixture();try submit(q)
        var writers:[Process]=[]
        defer { for p in writers where p.isRunning { ChildControl.stop(p) } }
        do {
            let barrier=try DatabaseSnapshotBarrier(store:db)
            for (index,item) in [("job_steps","step"),("job_events","revision"),("event_clock","next_sequence"),("event_consumers","ack_sequence"),("event_receipts","sequence")].enumerated() {
                let app="fixture-new-table-\(index)"
                let p=try sqlProcess(db,"UPDATE macnas.\(item.0) SET \(item.1)=\(item.1);",app:app);writers.append(p)
                let deadline=ProcessInfo.processInfo.systemUptime+3
                var blocked=false
                while ProcessInfo.processInfo.systemUptime<deadline {
                    blocked=try db.tools.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='\(app)' AND wait_event_type='Lock';",database:"postgres",admin:true)=="1"
                    if blocked { break };Thread.sleep(forTimeInterval:0.01)
                }
                XCTAssertTrue(blocked,item.0)
            }
            XCTAssertFalse(try q.jobs(audience:audience).isEmpty)
            try db.snapshot(to:child("new-tables.pgdump"));try barrier.check()
        }
        for p in writers { p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0) }
    }
    func testLeaseCannotBeUsedAgainstAnotherDatabase() throws {
        let (_,_,first)=try fixture("first");try submit(first)
        let l=try lease(first),(_,_,second)=try fixture("second");try submit(second)
        denied(.denied) { try second.finish(l) }
        denied(.denied) { try second.renew(l) }
    }
}

final class DurableAPITests:DurableLab {
    func testUserTaskAndNotificationScopesAndSessionRevocation() throws {
        let (root,_,q)=try fixture(),api=try PrototypePlatformAPI(root:root)
        let owner=try api.beginFixtureSession(userID:"fixture-owner"),family=try api.beginFixtureSession(userID:"fixture-family")
        _=try api.submitLabelJob(id:"private",key:"private",label:"label",value:"secret",session:owner)
        XCTAssertTrue(try api.durableJobs(session:family).isEmpty)
        denied(.denied) { _=try api.submitLabelJob(id:"escalate",key:"escalate",label:"bad",value:"bad",session:family) }
        denied(.denied) { _=try api.cancelJob(id:"private",session:family) }
        XCTAssertTrue(try api.jobEvents(consumerID:"family",session:family).isEmpty)
        let events=try api.jobEvents(consumerID:"owner",session:owner)
        XCTAssertEqual(events.map(\.job_id),["private"])
        denied(.denied) { _=try api.jobEvents(consumerID:"owner",session:family) }
        denied(.denied) { try api.acknowledgeJobEvents(consumerID:"owner",through:1,session:family) }
        _=try q.submit(id:"family-owned",key:"family-owned",kind:.label,payload:JobPayload(target:"fixture"),audience:.user("fixture-family"))
        XCTAssertEqual(try api.durableJobs(session:family).map(\.id),["family-owned"])
        XCTAssertEqual(try api.cancelJob(id:"family-owned",session:family).state,"cancelled")
        api.endSession(owner)
        denied(.denied) { _=try api.durableJobs(session:owner) }
    }
    func testAppGrantScopesRevocationAndPrivateEffect() throws {
        let (root,db,q)=try fixture(),api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner")
        let diag=try api.issueAppGrant(app:.diagnostics,session:owner),index=try api.issueAppGrant(app:.fileIndex,session:owner)
        _=try api.submitAppValueJob(id:"app-private",key:"app-private",valueID:"job-result",value:"own",grant:diag)
        XCTAssertTrue(try api.appJobs(grant:index).isEmpty)
        denied(.denied) { _=try api.cancelAppJob(id:"app-private",grant:index) }
        XCTAssertEqual(try api.appJobEvents(consumerID:"diag",grant:diag).map(\.job_id),["app-private"])
        denied(.denied) { _=try api.appJobEvents(consumerID:"diag",grant:index) }
        denied(.denied) { try api.acknowledgeAppJobEvents(consumerID:"diag",through:1,grant:index) }
        _=try q.workOne()
        XCTAssertEqual(try db.rows("SELECT value FROM app_hello_diagnostics.state WHERE id='job-result';"),[["own"]])
        XCTAssertEqual(try db.rows("SELECT count(*) FROM app_sample_file_index.state WHERE id='job-result';"),[["0"]])
        api.registry.disable(SampleApp.diagnostics.rawValue)
        denied(.denied) { _=try api.appJobs(grant:diag) }
        denied(.denied) { _=try api.submitAppValueJob(id:"no",key:"no",valueID:"no",value:"no",grant:diag) }
    }
    func testNativeAppDatabaseRoleCannotAccessCoreJobsOrOutbox() throws {
        let (_,db,_)=try fixture()
        for app in SampleApp.allCases {
            for table in ["jobs","job_steps","event_clock","job_events","event_consumers","event_receipts"] {
                denied(.database) { _=try db.tools.sql("SELECT * FROM macnas.\(table);",database:db.databaseName,principal:.app(app)) }
            }
        }
    }
    func testDollarQuotedTextAndSQLSyntaxAreStoredAsData() throws {
        let (_,db,q)=try fixture()
        let value="'; END $job$; DROP SCHEMA macnas CASCADE; --"
        _=try q.submit(id:"quotes",key:"quotes",kind:.label,payload:JobPayload(target:"quote",value:value),audience:audience)
        _=try q.workOne()
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id='quote';"),[[value]])
        try db.validate(expectedVersion:3)
    }
}
