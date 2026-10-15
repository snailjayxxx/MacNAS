import Foundation
import XCTest
@testable import MacNASCore

private final class ThreadOutcome: @unchecked Sendable {
    private let lock=NSLock()
    private var error:Error?
    func fail(_ error:Error) { lock.lock();self.error=error;lock.unlock() }
    func check() throws { lock.lock();defer { lock.unlock() };if let error { throw error } }
}
final class PrototypeAPITests: LabTest {
    func service() throws -> PrototypePlatformAPI { try PrototypePlatformAPI(root:source()) }
    func owner(_ service:PrototypePlatformAPI) throws -> PrototypeSession { try service.beginFixtureSession(userID:"fixture-owner") }
    func testOwnerBusinessCommandsUseActualDatabaseAndPortableConfiguration() throws {
        let api=try service(),session=try owner(api)
        try api.setLanguages(["ja-JP","zh-CN"],session:session)
        try api.writeLabel(id:"typed-api",value:"中文と日本語",session:session)
        try api.enqueue(id:"api-job",key:"api-key",session:session);try api.enqueue(id:"duplicate",key:"api-key",session:session)
        XCTAssertEqual(try api.overview(session:session).languages,["ja-JP","zh-CN"])
        let db=try PortableInstance.store(api.root)
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id='typed-api';"),[["中文と日本語"]])
        XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.jobs WHERE idempotency_key='api-key';"),[["1"]])
    }
    func testReaderAndEndedSessionsCannotEscalateThroughBusinessAPI() throws {
        let api=try service(),reader=try api.beginFixtureSession(userID:"fixture-family"),admin=try owner(api)
        XCTAssertEqual(try api.overview(session:reader).role,"reader")
        denied(.denied) { try api.setLanguages(["ja-JP"],session:reader) }
        denied(.denied) { try api.writeLabel(id:"private",value:"no",session:reader) }
        denied(.denied) { _=try api.issueAppGrant(app:.diagnostics,session:reader) }
        api.endSession(admin);denied(.denied) { _=try api.overview(session:admin) }
        denied(.denied) { _=try api.beginFixtureSession(userID:"unknown") }
    }
    func testCrossInstanceSessionAndAppGrantAreRejected() throws {
        let first=try service(),session=try owner(first),grant=try first.issueAppGrant(app:.diagnostics,session:session)
        let other=child("different-instance");try PortableInstance.createSynthetic(at:other)
        let second=try PrototypePlatformAPI(root:other)
        denied(.denied) { _=try second.overview(session:session) }
        denied(.denied) { _=try second.appState(grant:grant) }
    }
    func testAppStateAPIUsesScopedRoleAndRevocationInvalidatesOldTickets() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.fileIndex,session:session)
        try api.putAppState(id:"index-result",value:"only-my-schema",grant:grant)
        XCTAssertTrue(try api.appState(grant:grant).contains(["index-result","only-my-schema"]))
        api.registry.disable(SampleApp.fileIndex.rawValue)
        denied(.denied) { try api.putAppState(id:"refused",value:"no",grant:grant) }
        try api.registry.register(.sample(SampleApp.fileIndex.rawValue))
        denied(.denied) { _=try api.appState(grant:grant) }
        let renewed=try api.issueAppGrant(app:.fileIndex,session:session)
        XCTAssertTrue(try api.appState(grant:renewed).contains(["index-result","only-my-schema"]))
    }
    func testDatabaseRevocationStillRejectsAValidInMemoryGrant() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.fileIndex,session:session),db=try PortableInstance.store(api.root)
        let role=SampleApp.fileIndex.role(database:db.databaseName)
        _=try db.tools.sql("REVOKE ALL ON app_sample_file_index.state FROM \(role);",database:db.databaseName,admin:true)
        denied(.database) { try api.putAppState(id:"refused",value:"no",grant:grant) }
        XCTAssertEqual(try db.rows("SELECT count(*) FROM app_sample_file_index.state WHERE id='refused';"),[["0"]])
    }
    func testRecoveryModeBusinessAPIRefusesMutationsBeforeDatabaseAccess() throws {
        let e=try exported(),d=child("recovered");try PortableInstance.restore(from:e,to:d,hostID:"new",confirmCreate:true)
        let api=try PrototypePlatformAPI(root:d),session=try owner(api),grant=try api.issueAppGrant(app:.diagnostics,session:session)
        XCTAssertEqual(try api.overview(session:session).mode,"read_only_recovery")
        denied(.denied) { try api.setLanguages(["ja-JP"],session:session) }
        denied(.denied) { try api.putAppState(id:"no",value:"no",grant:grant) }
        denied(.denied) { _=try api.runSample(grant:grant) }
        XCTAssertFalse(try api.appState(grant:grant).isEmpty)
    }
    func testDiagnosticsRunsWithoutDatabaseOrSigningEnvironmentAndPersistsOwnResult() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.diagnostics,session:session)
        let data=try api.runSample(grant:grant)
        let result=try JSONDecoder().decode([String:String].self,from:data)
        XCTAssertEqual(result["seesDatabaseConfiguration"],"false");XCTAssertEqual(result["seesExportSigningKey"],"false")
        XCTAssertTrue(try api.appState(grant:grant).contains { $0.first == "last-result" })
    }
    func testFileIndexRequiresExplicitSyntheticLibraryAndKeepsRelativePaths() throws {
        let api=try service(),session=try owner(api),library=try SafeFS.resolve(api.root,"host-binding/fixtures")
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        try Data("synthetic".utf8).write(to:library.appendingPathComponent("写真.txt"))
        denied(.unsafePath) { _=try api.issueAppGrant(app:.fileIndex,session:session,fixtureLibrary:lab) }
        let grant=try api.issueAppGrant(app:.fileIndex,session:session,fixtureLibrary:library)
        XCTAssertEqual(try JSONDecoder().decode([String].self,from:api.runSample(grant:grant)),["写真.txt"])
        XCTAssertTrue(try api.appState(grant:grant).contains { $0.first == "last-result" })
    }
    func testSampleTimeoutAndOutputBudgetAreActuallyEnforced() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.diagnostics,session:session)
        let start=ProcessInfo.processInfo.systemUptime
        denied(.timedOut) { _=try api.runSample(grant:grant,execution:.simulateHang,budget:SampleBudget(seconds:0.1)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,2)
        XCTAssertEqual(api.registry.states[SampleApp.diagnostics.rawValue],.failed)
        try api.registry.register(.sample(SampleApp.diagnostics.rawValue))
        let new=try api.issueAppGrant(app:.diagnostics,session:session)
        denied(.budgetExceeded) { _=try api.runSample(grant:new,execution:.simulateOutputFlood,budget:SampleBudget(outputBytes:1024)) }
        XCTAssertEqual(try PortableInstance.store(api.root).rows("SELECT count(*) FROM app_hello_diagnostics.state WHERE id='last-result';"),[["0"]])
        XCTAssertEqual(api.registry.states[SampleApp.fileIndex.rawValue],.registered)
    }
    func testRevokingRunningSampleStopsItAndCoreRemainsUsable() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.diagnostics,session:session),registry=api.registry
        DispatchQueue.global().asyncAfter(deadline:.now()+0.15) { registry.disable(SampleApp.diagnostics.rawValue) }
        let start=ProcessInfo.processInfo.systemUptime
        denied(.denied) { _=try api.runSample(grant:grant,execution:.simulateHang,budget:SampleBudget(seconds:3)) }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime-start,2)
        XCTAssertEqual(registry.states[SampleApp.diagnostics.rawValue],.disabled)
        try api.enqueue(id:"core-still-works",key:"core-still-works",session:session)
        XCTAssertEqual(try PortableInstance.store(api.root).rows("SELECT state FROM macnas.jobs WHERE id='core-still-works';"),[["queued"]])
    }
    func testCancellationAndExpiredGrantDoNotRunOrPublishSampleResults() throws {
        let api=try service(),session=try owner(api),grant=try api.issueAppGrant(app:.diagnostics,session:session),token=CancellationToken()
        DispatchQueue.global().asyncAfter(deadline:.now()+0.1) { token.cancel() }
        denied(.cancelled) { _=try api.runSample(grant:grant,execution:.simulateHang,cancellation:token) }
        XCTAssertEqual(api.registry.states[SampleApp.diagnostics.rawValue],.registered)
        let expired=try api.issueAppGrant(app:.diagnostics,session:session,lifetime:0.01)
        Thread.sleep(forTimeInterval:0.02)
        denied(.expired) { _=try api.runSample(grant:expired) }
        XCTAssertEqual(try PortableInstance.store(api.root).rows("SELECT count(*) FROM app_hello_diagnostics.state WHERE id='last-result';"),[["0"]])
    }
    func testUnifiedBarrierWaitsForConfigurationAndDatabaseTaskToFinish() throws {
        let s=try source(),e=child("coherent-export"),ready=DispatchSemaphore(value:0),release=DispatchSemaphore(value:0),done=DispatchSemaphore(value:0),outcome=ThreadOutcome()
        DispatchQueue.global().async {
            do {
                let api=try PrototypePlatformAPI(root:s)
                try api.withManagedWrite {
                    try PortableInstance.store(s).execute("INSERT INTO macnas.labels VALUES('paired-update','completed');")
                    ready.signal();_ = release.wait(timeout:.now()+3)
                    var config=try PortableInstance.strictRead(PortableConfig.self,SafeFS.resolve(s,"config/platform.json"));config.languages=["ja-JP"]
                    try SafeFS.write(config,to:SafeFS.resolve(s,"config/platform.json"))
                }
            } catch { outcome.fail(error);ready.signal() }
            done.signal()
        }
        XCTAssertEqual(ready.wait(timeout:.now()+5),.success)
        DispatchQueue.global().asyncAfter(deadline:.now()+0.2) { release.signal() }
        try PortableInstance.export(from:s,to:e,timeout:3)
        XCTAssertEqual(done.wait(timeout:.now()+3),.success);try outcome.check()
        let d=child("coherent-restored");try PortableInstance.restore(from:e,to:d,hostID:"new",confirmCreate:true)
        XCTAssertEqual(try SafeFS.read(PortableConfig.self,d.appendingPathComponent("config/platform.json")).languages,["ja-JP"])
        XCTAssertEqual(try PortableInstance.store(d).rows("SELECT value FROM macnas.labels WHERE id='paired-update';"),[["completed"]])
    }
}
