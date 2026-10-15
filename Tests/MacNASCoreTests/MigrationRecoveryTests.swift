import XCTest
import Foundation
import Darwin
@testable import MacNASCore

final class MigrationRecoveryTests: LabTest {
    func testSchemaUpgradeUsesIsolatedDatabaseAndPreservesOldData() throws {
        let s=try source(), original=try PortableInstance.store(s), hash=try original.contentDigest(), d=child("升级后的实例")
        let record=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new-host")
        XCTAssertEqual(record.phase,.publishedReadOnly)
        let target=try PortableInstance.store(d)
        XCTAssertNotEqual(target.databaseName,original.databaseName)
        try target.validate(expectedVersion:2);try original.validate(expectedVersion:1)
        XCTAssertEqual(try original.contentDigest(),hash)
        XCTAssertEqual(try target.rows("SELECT id,value,revision FROM app_sample_file_index.state;"),[["sample-state","synthetic:sample-file-index","1"]])
        XCTAssertEqual(try target.baseDataDigest(),try original.baseDataDigest())
        XCTAssertEqual(try target.rows("SHOW default_transaction_read_only;"),[["on"]])
        XCTAssertThrowsError(try target.label("new","refused"))
        XCTAssertEqual(try PortableInstance.databaseDescriptor(d).version(),2)
        XCTAssertNotNil(try PortableInstance.verify(d).parentExportID)
    }
    func testRepeatedUpgradeDoesNotCreateAnotherDatabaseOrRepeatMigration() throws {
        let s=try source(),d=child("target")
        let first=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"same")
        let second=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"same")
        XCTAssertEqual(first.transactionID,second.transactionID);XCTAssertEqual(first.databaseName,second.databaseName)
        XCTAssertEqual(try PortableInstance.store(d).rows("SELECT version FROM macnas.schema_migrations ORDER BY version;"),[["1"],["2"]])
        XCTAssertEqual(second.resumeCount,1)
    }
    func testFailedMigrationRollsBackDDLAndResumesFromPreservedSchemaOne() throws {
        let s=try source(),d=child("target"), original=try PortableInstance.store(s).contentDigest()
        denied(.database) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new",fault:.failSchemaSQL) }
        let interrupted=try MigrationCoordinator.status(destination:d)
        XCTAssertEqual(interrupted.phase,.imported);XCTAssertEqual(interrupted.failureCode,"database")
        let candidate=try StateStore(databaseName:interrupted.databaseName);try candidate.validate(expectedVersion:1)
        XCTAssertEqual(try PortableInstance.store(s).contentDigest(),original)
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.path))
        let recovered=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new")
        XCTAssertEqual(recovered.databaseName,candidate.databaseName);try PortableInstance.store(d).validate(expectedVersion:2)
    }
    func testFutureTargetVersionRefusedBeforeJournalOrDatabaseCreation() throws {
        let s=try source(),d=child("target")
        denied(.unsupported) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new",targetVersion:99) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:try JournalStore.url(d).path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.path))
    }
    func testFutureSourceSchemaRefusedWithoutTouchingSource() throws {
        let s=try source(), db=try PortableInstance.store(s),d=child("target")
        try db.execute("UPDATE macnas.schema_migrations SET version=99;")
        denied(.invalidSchema) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new") }
        XCTAssertEqual(try db.rows("SELECT version FROM macnas.schema_migrations;"),[["99"]])
        XCTAssertFalse(FileManager.default.fileExists(atPath:try JournalStore.url(d).path))
    }
    func testAllDatabaseAndPublicationCheckpointRetriesReusePlannedDatabase() throws {
        let e=try exported()
        for point in [MigrationCheckpoint.afterDatabaseCreated,.afterImportCommit,.beforePublish,.afterPublish] {
            let d=child(point.rawValue)
            denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.at(point)) }
            let prior=try MigrationCoordinator.status(destination:d)
            let resumed=try MigrationCoordinator.restore(from:e,to:d,hostID:"new")
            XCTAssertEqual(resumed.databaseName,prior.databaseName);XCTAssertEqual(resumed.phase,.publishedReadOnly)
            XCTAssertEqual(try PortableInstance.store(d).rows("SELECT value FROM macnas.labels;"),[["合成测试・家族"]])
        }
    }
    func testUpgradeCommitBeforeJournalAdvanceIsDetectedAndNotReapplied() throws {
        let s=try source(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new",fault:.at(.afterSchemaCommit)) }
        let record=try MigrationCoordinator.status(destination:d)
        XCTAssertEqual(record.phase,.imported)
        try StateStore(databaseName:record.databaseName).validate(expectedVersion:2)
        let resumed=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new")
        XCTAssertEqual(resumed.databaseName,record.databaseName)
        XCTAssertEqual(try PortableInstance.store(d).rows("SELECT version FROM macnas.schema_migrations ORDER BY version;"),[["1"],["2"]])
    }
    func testCopyResumeRevalidatesAndRepairsOnlyItsKnownStagingFile() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let record=try MigrationCoordinator.status(destination:d),stage=try SafeFS.resolve(lab,record.stagingName)
        let file=try XCTUnwrap(record.copiedFiles.first)
        try Data("interrupted-write".utf8).write(to:SafeFS.resolve(stage,file))
        let resumed=try MigrationCoordinator.restore(from:e,to:d,hostID:"new")
        XCTAssertEqual(resumed.transactionID,record.transactionID);XCTAssertEqual(resumed.copiedFiles.count,PortableInstance.requiredFiles.count)
        XCTAssertNoThrow(try PortableInstance.verify(d))
    }
    func testUnknownStagingFileIsNotDeletedOrSilentlyImported() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let record=try MigrationCoordinator.status(destination:d),stage=try SafeFS.resolve(lab,record.stagingName)
        try Data("preserve".utf8).write(to:stage.appendingPathComponent("unapproved"))
        denied(.invalidSchema) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new") }
        XCTAssertTrue(FileManager.default.fileExists(atPath:stage.appendingPathComponent("unapproved").path))
    }
    func testJournalTamperingCannotRedirectDatabase() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let file=try JournalStore.url(d)
        var envelope=try XCTUnwrap(try JSONSerialization.jsonObject(with:Data(contentsOf:file)) as? [String:Any])
        var record=try XCTUnwrap(envelope["transaction"] as? [String:Any]);record["databaseID"]=UUID().uuidString;envelope["transaction"]=record
        try JSONSerialization.data(withJSONObject:envelope).write(to:file)
        denied(.integrity) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.path))
    }
    func testDifferentSignedExportCannotResumeAnotherTransaction() throws {
        let s=try source(),one=child("one"),two=child("two"),d=child("target")
        try PortableInstance.export(from:s,to:one);try PortableInstance.export(from:s,to:two)
        denied(.interrupted) { try MigrationCoordinator.restore(from:one,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        denied(.integrity) { try MigrationCoordinator.restore(from:two,to:d,hostID:"new") }
    }
    func testPreexistingDatabaseWithoutMatchingAttestationIsNeverOverwritten() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let record=try MigrationCoordinator.status(destination:d)
        let foreign=try StateStore.createEmpty(name:record.databaseName,attestation:"different-owner-operation")
        denied(.collision) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new") }
        XCTAssertEqual(try foreign.attestation(),"different-owner-operation");XCTAssertEqual(try foreign.tableCount(),0)
    }
    func testCrashWindowBeforeDatabaseAttestationAllocatesNewCandidateWithoutAdoptingOrDeletingUnknownDatabase() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let prior=try MigrationCoordinator.status(destination:d),unknown=try StateStore(databaseName:prior.databaseName)
        _=try unknown.tools.run("createdb",["--host",unknown.tools.socket.path,"--port","55432","--username","macnas_test_admin","--no-password","--owner","macnas_test_owner","--template","template0",prior.databaseName])
        let resumed=try MigrationCoordinator.restore(from:e,to:d,hostID:"new")
        XCTAssertNotEqual(resumed.databaseName,prior.databaseName)
        XCTAssertEqual(resumed.abandonedDatabases,[prior.databaseName])
        XCTAssertTrue(try unknown.exists());XCTAssertEqual(try unknown.tableCount(),0);XCTAssertEqual(try unknown.attestation(),"")
        XCTAssertEqual(resumed.phase,.publishedReadOnly)
    }
    func testCandidateMutationDuringInterruptedUpgradeCannotBeSignedAsRecoveredData() throws {
        let s=try source(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new",fault:.at(.afterSchemaCommit)) }
        let journal=try MigrationCoordinator.status(destination:d),candidate=try StateStore(databaseName:journal.databaseName)
        try candidate.execute("UPDATE app_sample_file_index.state SET revision=99;")
        denied(.integrity) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new") }
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.path))
        try PortableInstance.store(s).validate(expectedVersion:1)
    }
    func testRollbackRetainsOldSchemaAndAllFilesAndRefusesResume() throws {
        let s=try source(),d=child("target"),before=try PortableInstance.store(s).contentDigest()
        let upgraded=try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new")
        let rolled=try MigrationCoordinator.rollback(destination:d,confirm:true)
        XCTAssertEqual(rolled.phase,.rolledBack);XCTAssertEqual(upgraded.databaseName,rolled.databaseName)
        XCTAssertEqual(try PortableInstance.store(s).contentDigest(),before);try PortableInstance.store(s).validate(expectedVersion:1)
        XCTAssertTrue(FileManager.default.fileExists(atPath:d.appendingPathComponent("state/platform.pgdump").path))
        XCTAssertEqual(try SafeFS.read(HostBinding.self,d.appendingPathComponent("host-binding/binding.json")).mode,"rolled_back_recovery")
        XCTAssertEqual(try MigrationCoordinator.rollback(destination:d,confirm:true).phase,.rolledBack)
        denied(.staleState) { try MigrationCoordinator.upgrade(from:s,to:d,hostID:"new") }
    }
    func testRollbackPreviewAndStatusDoNotChangeJournal() throws {
        let e=try exported(),d=child("target")
        denied(.interrupted) { try MigrationCoordinator.restore(from:e,to:d,hostID:"new",fault:.afterCopiedFiles(2)) }
        let file=try JournalStore.url(d),before=try Data(contentsOf:file)
        _=try MigrationCoordinator.status(destination:d);_=try MigrationCoordinator.rollback(destination:d)
        XCTAssertEqual(try Data(contentsOf:file),before)
    }
    func testSchemaTwoCanBeExportedAndRestoredAgain() throws {
        let s=try source(),two=child("v2"),e=child("v2-export"),d=child("v2-restored")
        try MigrationCoordinator.upgrade(from:s,to:two,hostID:"upgrade")
        try PortableInstance.export(from:two,to:e)
        try PortableInstance.restore(from:e,to:d,hostID:"another",confirmCreate:true)
        try PortableInstance.store(d).validate(expectedVersion:2)
        XCTAssertEqual(try PortableInstance.store(d).contentDigest(),try PortableInstance.store(two).contentDigest())
    }
    func testForcedProcessDeathAfterImportAndAfterPublicationRecovers() throws {
        let e=try exported(),bin=try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        for point in [MigrationCheckpoint.afterImportCommit,.afterPublish] {
            let d=child("kill-"+point.rawValue),marker=child(".kill-\(point.rawValue).macnas-test-checkpoint")
            let process=Process();process.executableURL=URL(fileURLWithPath:bin).appendingPathComponent("macnas")
            process.arguments=["migrate","restore","--source",e.path,"--dest",d.path,"--host-id","new","--confirm-create","--synthetic-test-hold-after",point.rawValue]
            process.standardOutput=FileHandle.nullDevice;process.standardError=FileHandle.nullDevice
            try process.run()
            defer { if process.isRunning { ChildControl.stop(process) } }
            let deadline=ProcessInfo.processInfo.systemUptime+10
            while !FileManager.default.fileExists(atPath:marker.path) && process.isRunning && ProcessInfo.processInfo.systemUptime<deadline { Thread.sleep(forTimeInterval:0.01) }
            XCTAssertTrue(FileManager.default.fileExists(atPath:marker.path))
            let prior=try MigrationCoordinator.status(destination:d)
            kill(process.processIdentifier,SIGKILL);process.waitUntilExit()
            XCTAssertEqual(process.terminationReason,.uncaughtSignal)
            let resumed=try MigrationCoordinator.restore(from:e,to:d,hostID:"new")
            XCTAssertEqual(resumed.databaseName,prior.databaseName);XCTAssertEqual(resumed.phase,.publishedReadOnly)
        }
    }
}

final class PostgreSQLIsolationTests: LabTest {
    func testEachAppRoleCanUseItsOwnTableButCannotReadCoreOrOtherApp() throws {
        let db=try StateStore.createSynthetic()
        for app in SampleApp.allCases {
            let own=try db.tools.sql("INSERT INTO \(app.schema).state VALUES('fixture','own'); SELECT value FROM \(app.schema).state;",database:db.databaseName,principal:.app(app))
            XCTAssertEqual(own,"own")
            XCTAssertThrowsError(try db.tools.sql("SELECT * FROM macnas.labels;",database:db.databaseName,principal:.app(app)))
            let other=app == .diagnostics ? SampleApp.fileIndex : .diagnostics
            XCTAssertThrowsError(try db.tools.sql("SELECT * FROM \(other.schema).state;",database:db.databaseName,principal:.app(app)))
            XCTAssertThrowsError(try db.tools.sql("CREATE TABLE \(app.schema).escape(id integer);",database:db.databaseName,principal:.app(app)))
        }
    }
    func testAppRoleCannotConnectToAnotherInstanceDatabase() throws {
        let first=try StateStore.createSynthetic(),second=try StateStore.createSynthetic()
        var args=try first.tools.connection(second.databaseName,principal:.app(.fileIndex))
        let username=try XCTUnwrap(args.firstIndex(of:"--username"));args[username+1]=SampleApp.fileIndex.role(database:first.databaseName)
        XCTAssertThrowsError(try first.tools.run("psql",args+["-X","-t","-A","-c","SELECT 1;"]))
    }
    func testRestoredAppRoleIsAlsoReadOnly() throws {
        let e=try exported(),d=child("target");try PortableInstance.restore(from:e,to:d,hostID:"new",confirmCreate:true)
        let db=try PortableInstance.store(d)
        XCTAssertEqual(try db.tools.sql("SELECT value FROM app_sample_file_index.state;",database:db.databaseName,principal:.app(.fileIndex)),"synthetic:sample-file-index")
        XCTAssertThrowsError(try db.tools.sql("UPDATE app_sample_file_index.state SET value='refused';",database:db.databaseName,principal:.app(.fileIndex)))
    }
}

final class SnapshotBarrierTests: LabTest {
    func writer(_ db:StateStore,app:SampleApp?=nil,sql:String,name:String) throws -> Process {
        let p=Process();p.executableURL=db.tools.bin.appendingPathComponent("psql")
        p.arguments=try db.tools.connection(db.databaseName,principal:app.map { .app($0) } ?? .owner)+["-X","-q","--set","ON_ERROR_STOP=1","-c",sql]
        p.environment=db.tools.environment(application:name);p.standardOutput=FileHandle.nullDevice;p.standardError=FileHandle.nullDevice
        try p.run();return p
    }
    func waitFor(_ db:StateStore,name:String,condition:String) throws {
        let deadline=ProcessInfo.processInfo.systemUptime+3
        while ProcessInfo.processInfo.systemUptime<deadline {
            if try db.tools.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='\(name)' AND \(condition);",database:"postgres",admin:true)=="1" { return }
            Thread.sleep(forTimeInterval:0.01)
        }
        XCTFail("expected PostgreSQL session state was not reached")
    }
    func testUnfinishedTransactionTimeoutDoesNotPublishAnySnapshot() throws {
        let s=try source(),db=try PortableInstance.store(s)
        let p=try writer(db,sql:"BEGIN; UPDATE macnas.labels SET value='not-committed'; SELECT pg_sleep(10); COMMIT;",name:"fixture-open-transaction")
        defer { ChildControl.stop(p) }
        try waitFor(db,name:"fixture-open-transaction",condition:"wait_event='PgSleep'")
        denied(.timedOut) { try PortableInstance.export(from:s,to:child("snapshot"),timeout:0.1) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:child("snapshot").path))
    }
    func testCancellationWhileWaitingForInstanceWriter() throws {
        let s=try source(),token=CancellationToken(),lock=try InstanceLock(s)
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { token.cancel() }
        withExtendedLifetime(lock) { denied(.cancelled) { try PortableInstance.export(from:s,to:child("snapshot"),timeout:2,cancellation:token) } }
        XCTAssertFalse(FileManager.default.fileExists(atPath:child("snapshot").path))
    }
    func testCancellationWhileDrainingWriterCancelsOnlyItsOwnDatabaseBarrierSession() throws {
        let s=try source(),db=try PortableInstance.store(s),token=CancellationToken(),observedWait=CancellationToken(),finished=DispatchSemaphore(value:0)
        let p=try writer(db,sql:"BEGIN; UPDATE macnas.labels SET value='uncommitted'; SELECT pg_sleep(10); COMMIT;",name:"fixture-cancellation-writer")
        defer { ChildControl.stop(p) }
        try waitFor(db,name:"fixture-cancellation-writer",condition:"wait_event='PgSleep'")
        let databaseName=db.databaseName
        DispatchQueue.global().async {
            defer { finished.signal() }
            do {
                let tools=try PostgreSQLTools(),deadline=ProcessInfo.processInfo.systemUptime+3
                while ProcessInfo.processInfo.systemUptime<deadline {
                    let count=try tools.sql("SELECT count(*) FROM pg_stat_activity WHERE datname='\(databaseName)' AND application_name LIKE 'macnas-freeze-%' AND wait_event_type='Lock';",database:"postgres",admin:true)
                    if count=="1" { observedWait.cancel();token.cancel();return }
                    Thread.sleep(forTimeInterval:0.01)
                }
            } catch {}
            token.cancel()
        }
        denied(.cancelled) { try PortableInstance.export(from:s,to:child("cancelled"),timeout:4,cancellation:token) }
        XCTAssertEqual(finished.wait(timeout:.now()+1),.success)
        XCTAssertTrue(observedWait.isCancelled,"cancellation must happen after a real PostgreSQL lock wait, not before starting it")
        let deadline=ProcessInfo.processInfo.systemUptime+1
        var remaining="1"
        while ProcessInfo.processInfo.systemUptime<deadline {
            remaining=try db.tools.sql("SELECT count(*) FROM pg_stat_activity WHERE datname='\(db.databaseName)' AND application_name LIKE 'macnas-freeze-%';",database:"postgres",admin:true)
            if remaining=="0" { break };Thread.sleep(forTimeInterval:0.01)
        }
        XCTAssertEqual(remaining,"0");XCTAssertTrue(p.isRunning)
        XCTAssertFalse(FileManager.default.fileExists(atPath:child("cancelled").path))
    }
    func testDatabaseTableBarrierStopsAppWritesWhileReadersAndDumpContinue() throws {
        let s=try source(),db=try PortableInstance.store(s)
        var writerProcess:Process?
        do {
            let barrier=try DatabaseSnapshotBarrier(store:db)
            let p=try writer(db,app:.fileIndex,sql:"UPDATE app_sample_file_index.state SET value='after-barrier';",name:"fixture-blocked-app")
            writerProcess=p
            try waitFor(db,name:"fixture-blocked-app",condition:"wait_event_type='Lock'")
            XCTAssertEqual(try db.rows("SELECT value FROM app_sample_file_index.state;"),[["synthetic:sample-file-index"]])
            try db.snapshot(to:child("consistent.pgdump"));try barrier.check()
        }
        let p=try XCTUnwrap(writerProcess);p.waitUntilExit();XCTAssertEqual(p.terminationStatus,0)
        XCTAssertEqual(try db.rows("SELECT value FROM app_sample_file_index.state;"),[["after-barrier"]])
    }
}
