import XCTest
import Foundation
import CryptoKit
@testable import MacNASCore

class LabTest: XCTestCase {
    var lab: URL!
    override func setUpWithError() throws {
        let base = try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_TESTLAB"], "Run /usr/bin/python3 scripts/dev.py to start isolated PostgreSQL")
        lab = URL(fileURLWithPath: base).appendingPathComponent(UUID().uuidString)
        try SafeFS.freshDirectory(lab)
    }
    override func tearDownWithError() throws { if let lab { try FileManager.default.removeItem(at: lab) } }
    func child(_ name: String) -> URL { lab.appendingPathComponent(name) }
    func source() throws -> URL { let root = child("旧实例-合成"); try PortableInstance.createSynthetic(at: root); return root }
    func exported() throws -> URL { let root = try source(); let export = child("snapshot"); try PortableInstance.export(from: root, to: export); return export }
    func denied(_ expected: NASError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? NASError, expected, file: file, line: line) }
    }
}
final class PathTests: LabTest {
    func testTraversalAndAbsolutePathsRejected() throws {
        for path in ["../x", "/etc/x", "a/../../x", "a//b", "a/./b", "a\\b", "a\0b", "C:x"] { denied(.unsafePath) { _ = try SafeFS.resolve(lab, path) } }
    }
    func testSymlinkEscapeRejected() throws {
        try FileManager.default.createSymbolicLink(at: child("escape"), withDestinationURL: lab.deletingLastPathComponent())
        denied(.unsafeFile) { _ = try SafeFS.resolve(lab, "escape/private") }
    }
    func testHardLinkRejected() throws {
        try Data("synthetic".utf8).write(to: child("original"))
        try FileManager.default.linkItem(at: child("original"), to: child("alias"))
        denied(.unsafeFile) { _ = try SafeFS.files(lab) }
    }
    func testUnicodeRelativePathSupported() throws { XCTAssertEqual(try SafeFS.resolve(lab, "合成/写真.json").lastPathComponent, "写真.json") }
    func testFreshDirectoryDoesNotOverwrite() throws { try SafeFS.freshDirectory(child("exists")); denied(.collision) { try SafeFS.freshDirectory(child("exists")) } }
    func testLocalLockExcludesSecondWriter() throws {
        do {
            let lock = try InstanceLock(lab)
            withExtendedLifetime(lock) { denied(.busy) { _ = try InstanceLock(lab) } }
        }
        XCTAssertNoThrow(try InstanceLock(lab))
    }
}
final class SecurityTests: XCTestCase {
    func testAuthorizedMockOperationAndReplayRejection() throws {
        let gate = MockOperationGate(), req = OperationRequest(), ctx = MockSecurityContext()
        let token = try gate.preview(req, context: ctx)
        try gate.commit(req, token: token, context: ctx, actualState: "state-v1")
        XCTAssertThrowsError(try gate.commit(req, token: token, context: ctx, actualState: "state-v1")) { XCTAssertEqual($0 as? NASError, .replay) }
    }
    func testRejectsUnverifiedCaller() { var c = MockSecurityContext(); c.verifiedMockCaller = false; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsNonAdmin() { var c = MockSecurityContext(); c.role = "reader"; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsOtherUser() { var c = MockSecurityContext(); c.user = "fixture-other"; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsCrossOrigin() { var c = MockSecurityContext(); c.origin = "https://attacker.test"; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsMissingCSRF() { var c = MockSecurityContext(); c.csrf = ""; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsWrongSession() { var c = MockSecurityContext(); c.session = "other"; XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(), context: c)) }
    func testRejectsPathScope() { XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(scope: "fixture:../disk"), context: MockSecurityContext())) }
    func testRejectsRealSystemOperation() { XCTAssertThrowsError(try MockOperationGate().preview(OperationRequest(operation: .installHelper), context: MockSecurityContext())) }
    func testRejectsExpiredGrant() throws {
        let g = MockOperationGate(), r = OperationRequest(), c = MockSecurityContext(), start = Date()
        let t = try g.preview(r, context: c, now: start)
        XCTAssertThrowsError(try g.commit(r, token: t, context: c, actualState: "state-v1", now: start.addingTimeInterval(31))) { XCTAssertEqual($0 as? NASError, .expired) }
    }
    func testRejectsChangedPreview() throws {
        let g = MockOperationGate(), c = MockSecurityContext(); var r = OperationRequest()
        let t = try g.preview(r, context: c); r.preview = "changed"
        XCTAssertThrowsError(try g.commit(r, token: t, context: c, actualState: "state-v1"))
    }
    func testRejectsStateChangeAndConsumesGrant() throws {
        let g = MockOperationGate(), c = MockSecurityContext(), r = OperationRequest(), t = try g.preview(r, context: c)
        XCTAssertThrowsError(try g.commit(r, token: t, context: c, actualState: "changed")) { XCTAssertEqual($0 as? NASError, .staleState) }
        XCTAssertThrowsError(try g.commit(r, token: t, context: c, actualState: "state-v1"))
    }
    func testRejectsUnknownGrant() { XCTAssertThrowsError(try MockOperationGate().commit(OperationRequest(), token: UUID(), context: MockSecurityContext(), actualState: "state-v1")) }
}
final class PostgreSQLTests: LabTest {
    func testActualPostgreSQLVersionAndSchema() throws { let db = try StateStore.createSynthetic(); try db.validate(); XCTAssertEqual(try db.rows("SELECT current_setting('server_version_num')::int / 10000;"), [["18"]]) }
    func testDuplicateJobAndRestartCompletionIdempotent() throws {
        let db = try StateStore.createSynthetic()
        try db.enqueue("job", key: "key"); try db.enqueue("duplicate", key: "key"); try db.complete("job")
        let restarted = try StateStore(databaseName: db.databaseName); try restarted.complete("job")
        XCTAssertEqual(try restarted.rows("SELECT id,effects,state FROM macnas.jobs;"), [["job","1","completed"]])
    }
    func testSQLQuotesRemainData() throws { let db = try StateStore.createSynthetic(); try db.label("o'hara", "家族 'quoted'"); XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels;"), [["家族 'quoted'"]]) }
    func testNoFallbackWhenDatabaseMissing() throws { let db = try StateStore(databaseName: "macnas_fixture_missing"); XCTAssertThrowsError(try db.validate()) }
    func testProductionAndRemoteConnectionNamesRejected() { XCTAssertThrowsError(try StateStore(databaseName: "snailjoss")); XCTAssertThrowsError(try StateStore(databaseName: "host=example.com")) }
    func testVersionedMigrationRejectsUnknownSchema() throws { let db = try StateStore.createSynthetic(); try db.execute("UPDATE macnas.schema_migrations SET version=99;"); denied(.invalidSchema) { try db.validate() } }
}
final class MigrationTests: LabTest {
    func testPORT01DifferentPathRestoresConfigAppsAndActualDatabase() throws {
        let source = try source(), export = child("export"), dest = child("まったく別の復元先")
        let sourceDB = try PortableInstance.store(source)
        try sourceDB.complete("fixture-job")
        try PortableInstance.export(from: source, to: export)
        try PortableInstance.restore(from: export, to: dest, hostID: "new-uid-host", confirmCreate: true)
        XCTAssertEqual(try Data(contentsOf: dest.appendingPathComponent("config/platform.json")), try Data(contentsOf: source.appendingPathComponent("config/platform.json")))
        let targetDB = try PortableInstance.store(dest)
        XCTAssertEqual(try targetDB.rows("SELECT value FROM macnas.labels WHERE id='manual-tag';"), [["合成测试・家族"]])
        XCTAssertEqual(try targetDB.rows("SELECT effects,state FROM macnas.jobs;"), [["1","completed"]])
        XCTAssertEqual(try targetDB.rows("SELECT value FROM app_sample_file_index.state;"), [["synthetic:sample-file-index"]])
        XCTAssertEqual(try targetDB.rows("SELECT value FROM app_hello_diagnostics.state;"), [["synthetic:hello-diagnostics"]])
        XCTAssertNotEqual(sourceDB.databaseName, targetDB.databaseName)
    }
    func testPORT02HostBindingsRecreatedAndPORT06ReadonlyEnforced() throws {
        let e = try exported(), d = child("restored")
        try PortableInstance.restore(from: e, to: d, hostID: "new-host", confirmCreate: true)
        let binding = try SafeFS.read(HostBinding.self, d.appendingPathComponent("host-binding/binding.json"))
        XCTAssertEqual(binding.hostID, "new-host"); XCTAssertEqual(binding.mode, "read_only_recovery"); XCTAssertTrue(binding.needsAuthorization.contains("SMB"))
        let db = try PortableInstance.store(d)
        XCTAssertEqual(try db.rows("SHOW default_transaction_read_only;"), [["on"]])
        XCTAssertThrowsError(try db.label("should", "not-write"))
    }
    func testPORT03DumpIsConsistentAndSourceRemainsWritable() throws {
        let s = try source(), db = try PortableInstance.store(s), e = child("snapshot")
        try db.label("before", "included"); try PortableInstance.export(from: s, to: e); try db.label("after", "excluded")
        let d = child("target"); try PortableInstance.restore(from: e, to: d, hostID: "new", confirmCreate: true)
        XCTAssertEqual(try PortableInstance.store(d).rows("SELECT id FROM macnas.labels ORDER BY id;"), [["before"],["manual-tag"]])
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id='after';"), [["excluded"]])
    }
    func testPORT03ExportDrainsConcurrentUncommittedTransaction() throws {
        let s = try source(), db = try PortableInstance.store(s), e = child("concurrent-export")
        try db.label("atomic-a", "old"); try db.label("atomic-b", "old")
        let writer = Process()
        writer.executableURL = db.tools.bin.appendingPathComponent("psql")
        writer.arguments = try db.tools.connection(db.databaseName) + ["-X", "-q", "--set", "ON_ERROR_STOP=1", "-c",
            "BEGIN; UPDATE macnas.labels SET value='new' WHERE id='atomic-a'; SELECT pg_sleep(5); UPDATE macnas.labels SET value='new' WHERE id='atomic-b'; COMMIT;"]
        writer.environment = ["PATH":"/usr/bin:/bin", "HOME":db.tools.socket.path, "PGAPPNAME":"macnas-concurrent-fixture", "PGCONNECT_TIMEOUT":"3"]
        writer.standardOutput = FileHandle.nullDevice; writer.standardError = FileHandle.nullDevice
        try writer.run()
        defer { if writer.isRunning { writer.terminate(); writer.waitUntilExit() } }
        let deadline = Date().addingTimeInterval(2)
        var sleeping = false
        while Date() < deadline {
            if try db.rows("SELECT count(*) FROM pg_stat_activity WHERE application_name='macnas-concurrent-fixture' AND wait_event='PgSleep';") == [["1"]] { sleeping = true; break }
            Thread.sleep(forTimeInterval:0.02)
        }
        XCTAssertTrue(sleeping, "writer must be inside an uncommitted transaction during export")
        try PortableInstance.export(from:s,to:e)
        writer.waitUntilExit(); XCTAssertEqual(writer.terminationStatus,0)
        let d=child("concurrent-restored"); try PortableInstance.restore(from:e,to:d,hostID:"new",confirmCreate:true)
        XCTAssertEqual(try PortableInstance.store(d).rows("SELECT value FROM macnas.labels WHERE id LIKE 'atomic-%' ORDER BY id;"),[["new"],["new"]])
        XCTAssertEqual(try db.rows("SELECT value FROM macnas.labels WHERE id LIKE 'atomic-%' ORDER BY id;"),[["new"],["new"]])
    }
    func testPORT04InterruptedExportNotPublishedAndRetryWorks() throws {
        let s = try source(), e = child("snapshot")
        denied(.interrupted) { try PortableInstance.export(from: s, to: e, interruptAfter: 2) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: e.path))
        let partial = try XCTUnwrap(try FileManager.default.contentsOfDirectory(at: lab, includingPropertiesForKeys: nil).first { $0.lastPathComponent.hasPrefix(".snapshot.partial-") })
        XCTAssertThrowsError(try PortableInstance.verify(partial))
        try PortableInstance.export(from: s, to: e); XCTAssertNoThrow(try PortableInstance.verify(e))
    }
    func testPORT04InterruptedImportPreservesSourceAndRetryWorks() throws {
        let e = try exported(), d = child("target"), original = try SafeFS.digest(e.appendingPathComponent("manifest.json"))
        denied(.interrupted) { try PortableInstance.restore(from: e, to: d, hostID: "new", confirmCreate: true, interruptAfter: 2) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: d.path))
        XCTAssertEqual(try SafeFS.digest(e.appendingPathComponent("manifest.json")), original)
        try PortableInstance.restore(from: e, to: d, hostID: "new", confirmCreate: true)
    }
    func testPORT05UnknownPluginSchemaRefusesExport() throws {
        let s = try source()
        try SafeFS.write(["dataSchema":"99", "schema":"app_sample_file_index"], to: s.appendingPathComponent("app-data/sample-file-index/schema.json"))
        denied(.invalidSchema) { try PortableInstance.export(from: s, to: child("bad")) }
    }
    func testPORT06SecretDirectoriesExcludedAndUnknownSecretConfigRejected() throws {
        let s = try source(), secrets = s.appendingPathComponent("secrets"), e = child("export")
        try FileManager.default.createDirectory(at: secrets, withIntermediateDirectories: false)
        let marker = "SYNTHETIC_SECRET_MUST_NOT_EXPORT"
        try Data(marker.utf8).write(to: secrets.appendingPathComponent("token"))
        try PortableInstance.export(from: s, to: e)
        for file in try SafeFS.files(e) { XCTAssertFalse(try Data(contentsOf: e.appendingPathComponent(file)).range(of: Data(marker.utf8)) != nil) }
        let config = s.appendingPathComponent("config/platform.json")
        var object = try XCTUnwrap(try JSONSerialization.jsonObject(with: Data(contentsOf: config)) as? [String: Any]); object["password"] = marker
        try JSONSerialization.data(withJSONObject: object).write(to: config)
        denied(.invalidSchema) { try PortableInstance.export(from: s, to: child("refused")) }
    }
    func testPORT08ActiveSourceLockRefusesExportAndCutoverAlwaysRefuses() throws {
        let s = try source(), lock = try InstanceLock(s)
        withExtendedLifetime(lock) { denied(.busy) { try PortableInstance.export(from: s, to: child("export"), timeout: 0) } }
        denied(.unsupported) { try PortableInstance.cutover() }
    }
    func testPORT13Raw35TBFilesAreOnlyLogicalReferences() throws { let s = try source(); let p = try PortableInstance.preview(s); XCTAssertEqual(p.externalBytesNotIncluded,35_000_000_000_000); XCTAssertFalse(FileManager.default.fileExists(atPath:s.appendingPathComponent("合成资料").path)) }
    func testPORT14PreviewDoesNotCreateDestinationAndRestoreRetryIsIdempotent() throws {
        let e = try exported(), d = child("new")
        try PortableInstance.restore(from: e, to: d, hostID: "new")
        XCTAssertFalse(FileManager.default.fileExists(atPath:d.path))
        try PortableInstance.restore(from: e, to: d, hostID: "new", confirmCreate: true)
        let binding = try Data(contentsOf: d.appendingPathComponent("host-binding/binding.json"))
        try PortableInstance.restore(from: e, to: d, hostID: "new", confirmCreate: true)
        XCTAssertEqual(try Data(contentsOf:d.appendingPathComponent("host-binding/binding.json")),binding)
    }
    func testExportedBundleRejectsUnlistedSecretDirectory() throws {
        let e=try exported(), dir=e.appendingPathComponent("secrets")
        try FileManager.default.createDirectory(at:dir,withIntermediateDirectories:false)
        try Data("synthetic-unlisted".utf8).write(to:dir.appendingPathComponent("token"))
        denied(.invalidSchema) { _ = try PortableInstance.verify(e) }
    }
    func testPORT15TamperedPayloadRejected() throws { let e = try exported(); try Data("tamper".utf8).write(to:e.appendingPathComponent("config/platform.json")); denied(.integrity) { _ = try PortableInstance.verify(e) } }
    func testPORT15RehashedManifestStillNeedsTrustedSignature() throws {
        let e = try exported(), p = e.appendingPathComponent("manifest.json")
        var m = try SafeFS.read(ExportManifest.self,p); m.generation += 1; try SafeFS.write(m,to:p)
        denied(.integrity) { _ = try PortableInstance.verify(e) }
    }
    func testExistingTargetIsNeverOverwritten() throws { let e = try exported(), d = child("existing"); try SafeFS.freshDirectory(d); try Data("keep".utf8).write(to:d.appendingPathComponent("original")); XCTAssertThrowsError(try PortableInstance.restore(from:e,to:d,hostID:"new",confirmCreate:true)); XCTAssertEqual(try String(contentsOf:d.appendingPathComponent("original"),encoding:.utf8),"keep") }
    func testUnexpectedExecutableOrSymlinkCannotBeExported() throws { let s = try source(); try Data("unapproved".utf8).write(to:s.appendingPathComponent("apps/hello-diagnostics/run")); denied(.invalidSchema) { try PortableInstance.export(from:s,to:child("bad")) } }
}
final class StorageAndCapabilityTests: XCTestCase {
    func reference() -> VolumeReference { VolumeReference(libraryID:"fixture",volumeID:UUID(),relativePath:"写真",estimatedBytes:1) }
    func testPORT07MissingOrSameNameWrongUUIDRejected() { let r=reference(); XCTAssertThrowsError(try VolumeGuard.canWrite(r,inventory:[])); XCTAssertThrowsError(try VolumeGuard.canWrite(r,inventory:[MountedVolume(id:UUID(),displayName:"MacNAS-Dev",authorized:true)])) }
    func testPORT16SystemFallbackAndDuplicateUUIDRejected() { let r=reference(); XCTAssertThrowsError(try VolumeGuard.canWrite(r,inventory:[MountedVolume(id:r.volumeID,displayName:"same",isSystem:true,authorized:true)])); let v=MountedVolume(id:r.volumeID,displayName:"fixture",authorized:true); XCTAssertThrowsError(try VolumeGuard.canWrite(r,inventory:[v,v])) }
    func testVolumeGrantRequiredAndExactIDAccepted() throws { let r=reference(); XCTAssertThrowsError(try VolumeGuard.canWrite(r,inventory:[MountedVolume(id:r.volumeID,displayName:"fixture")])); try VolumeGuard.canWrite(r,inventory:[MountedVolume(id:r.volumeID,displayName:"different-name",authorized:true)]) }
    func testPORT08And09MockLeaseRejectsDualMasterAndFencesOldGeneration() throws {
        let authority=MockLeaseAuthority(); let g=try authority.acquire(host:"old",expectedGeneration:0,sourceStopped:true,ownerApproved:true)
        XCTAssertThrowsError(try authority.acquire(host:"new",expectedGeneration:g,sourceStopped:false,ownerApproved:true))
        try authority.release(host:"old",generation:g)
        let next=try authority.acquire(host:"new",expectedGeneration:g,sourceStopped:true,ownerApproved:true)
        XCTAssertThrowsError(try authority.release(host:"old",generation:g)); try authority.release(host:"new",generation:next)
        _ = try authority.acquire(host:"old",expectedGeneration:next,sourceStopped:true,ownerApproved:true)
    }
    func testMockLeaseRequiresOwnerAndStoppedSource() { let a=MockLeaseAuthority(); XCTAssertThrowsError(try a.acquire(host:"x",expectedGeneration:0,sourceStopped:true,ownerApproved:false)); XCTAssertThrowsError(try a.acquire(host:"x",expectedGeneration:0,sourceStopped:false,ownerApproved:true)) }
    func testPORT10MacOS15NoAutomaticLocalModelOrSemanticClaims() { let c=MockCapabilityProbe(osMajor:15).inspect(); XCTAssertEqual(c.first{$0.id=="foundation-models"}?.state,.unavailable); XCTAssertEqual(c.first{$0.id=="natural-language-photo-search"}?.state,.notVerified) }
    func testFutureOSStillNeedsLocalModelAvailability() { XCTAssertEqual(MockCapabilityProbe(osMajor:26).inspect().first{$0.id=="foundation-models"}?.state,.unavailable); XCTAssertEqual(MockCapabilityProbe(osMajor:26,localModelAvailable:true).inspect().first{$0.id=="foundation-models"}?.state,.available) }
    func layout() throws -> MirrorOfSpans { try MirrorOfSpans(left:[.init("a","box1",10),.init("b","box1",10),.init("c","box2",10)],right:[.init("d","box2",15),.init("e","box3",15)]) }
    func testFiveMemberCapacityAndEverySingleFailure() throws { let l=try layout(); XCTAssertEqual(l.capacity,30); for id in ["a","b","c","d","e"] { XCTAssertTrue(l.readable(failed:[id])); XCTAssertFalse(l.writable(failed:[id])) } }
    func testCrossSideEnclosureFailureIsNotProtected() throws { let l=try layout(); XCTAssertFalse(l.readable(failed:l.failureOfEnclosure("box2"))) }
    func testUndersizedReplacementAndDuplicateMembersRejected() throws { let l=try layout(); XCTAssertFalse(l.replacementAllowed(memberID:"d",replacementBytes:14)); XCTAssertTrue(l.replacementAllowed(memberID:"d",replacementBytes:15)); XCTAssertThrowsError(try MirrorOfSpans(left:[.init("a","x",1)],right:[.init("a","y",1)])) }
}
final class PluginTests: LabTest {
    func testTwoSamplesRegisterDisableAndUninstallKeepsData() throws {
        let registry=SamplePluginRegistry()
        for id in PortableInstance.sampleIDs { try registry.register(.sample(id)) }
        let data=child("app-data"); try Data("keep".utf8).write(to:data)
        registry.disable("sample-file-index")
        XCTAssertThrowsError(try registry.authorize("sample-file-index",permission:"fixture-directory-read",grants:["fixture-directory-read"]))
        registry.uninstall("sample-file-index"); XCTAssertTrue(FileManager.default.fileExists(atPath:data.path))
        XCTAssertEqual(registry.states["hello-diagnostics"],.registered)
    }
    func testPluginPrivilegeEscalationRejected() throws { let r=SamplePluginRegistry(); try r.register(.sample("hello-diagnostics")); XCTAssertThrowsError(try r.authorize("hello-diagnostics",permission:"fixture-directory-read",grants:["fixture-directory-read"])); var m=PluginManifest.sample("sample-file-index"); m.permissions.append("root"); XCTAssertThrowsError(try r.register(m)) }
    func testRevokedGrantRejected() throws { let r=SamplePluginRegistry(); try r.register(.sample("sample-file-index")); XCTAssertThrowsError(try r.authorize("sample-file-index",permission:"fixture-directory-read",grants:[])) }
    func testSampleIndexRejectsSymlink() throws { try FileManager.default.createSymbolicLink(at:child("escape"),withDestinationURL:lab.deletingLastPathComponent()); denied(.unsafeFile) { _ = try SampleFileIndex.inspect(root:lab) } }
    func run(_ name: String,_ args:[String]) throws -> (Int32,Data) {
        let bin=try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])
        let p=Process(), pipe=Pipe(); p.executableURL=URL(fileURLWithPath:bin).appendingPathComponent(name); p.arguments=args; p.standardOutput=pipe; p.standardError=FileHandle.nullDevice
        try p.run(); let output=pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit(); return(p.terminationStatus,output)
    }
    func testIndependentDiagnosticsProcessCrashDoesNotAffectRegistry() throws { let r=SamplePluginRegistry(); try r.register(.sample("hello-diagnostics")); let result=try run("hello-diagnostics",["--simulate-crash"]); XCTAssertEqual(result.0,70); r.recordExit("hello-diagnostics",status:result.0); XCTAssertEqual(r.states["hello-diagnostics"],.failed); XCTAssertEqual(try run("hello-diagnostics",[]).0,0) }
    func testIndependentFileIndexOnlyReceivesExplicitFixtureRoot() throws { try Data("synthetic".utf8).write(to:child("写真.txt")); let result=try run("sample-file-index",["--granted-synthetic-root",lab.path]); XCTAssertEqual(result.0,0); XCTAssertEqual(try JSONDecoder().decode([String].self,from:result.1),["写真.txt"]); XCTAssertNotEqual(try run("sample-file-index",[]).0,0) }
}
