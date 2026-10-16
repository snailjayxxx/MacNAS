import Foundation
import XCTest
@testable import MacNASCore

final class Schema4MigrationTests: FileEffectJournalLab {
    func schemaSource(_ name: String, version: Int) throws -> URL {
        let root = child(name)
        try PortableInstance.createSynthetic(at: root, databaseVersion: version)
        return root
    }
    func populatedSchemaThree(_ name: String) throws -> (URL, StateStore) {
        let root = try schemaSource(name, version: 3), db = try PortableInstance.store(root)
        let queue = try DurableJobQueue(store: db), audience = JobAudience.user("fixture-owner")
        _ = try queue.submit(id: "old-managed", key: "old-managed-key", kind: .label,
            payload: JobPayload(target: "old-managed", value: "source-three"), audience: audience)
        _ = try queue.workOne()
        let events = try queue.poll(consumerID: "old-consumer", audience: audience)
        try queue.acknowledge(consumerID: "old-consumer", through: try XCTUnwrap(events.first?.sequence), audience: audience)
        return (root, db)
    }
    /// Only a new synthetic database/root: create valid journal history without any file executor.
    @discardableResult func addHistory(root: URL, db: StateStore, cancelled: Bool = false) throws -> FileEffectJournalRecord {
        let host = try SafeFS.resolve(root, "host-binding"), bindingFile = try SafeFS.resolve(root, "host-binding/binding.json")
        let hadHost = FileManager.default.fileExists(atPath: host.path)
        let originalBinding = FileManager.default.fileExists(atPath: bindingFile.path) ? try SafeFS.readData(bindingFile) : nil
        let descriptorFile = try SafeFS.resolve(root, "state/database.json"), originalDescriptor = try SafeFS.readData(descriptorFile)
        let readOnly = try db.rows("SHOW default_transaction_read_only;") == [["on"]]
        if !hadHost { try FileManager.default.createDirectory(at: host, withIntermediateDirectories: false) }
        var binding = HostBinding(hostID: "synthetic-journal-test")
        binding.databaseName = db.databaseName; binding.mode = "synthetic_development"
        try SafeFS.write(binding, to: bindingFile)
        _ = try db.tools.sql("ALTER DATABASE \(db.databaseName) SET default_transaction_read_only=off;", database: "postgres", admin: true)
        defer {
            try? originalDescriptor.write(to: descriptorFile, options: .atomic)
            if let originalBinding { try? originalBinding.write(to: bindingFile, options: .atomic) }
            else { try? FileManager.default.removeItem(at: bindingFile) }
            if !hadHost { try? FileManager.default.removeItem(at: host) }
            if readOnly { _ = try? db.tools.sql("ALTER DATABASE \(db.databaseName) SET default_transaction_read_only=on;", database: "postgres", admin: true) }
        }
        // A migration checkpoint may still have its source-version descriptor.
        // This closed fixture lends the internal journal a temporary Schema 4 descriptor;
        // restore the exact staged bytes before testing portable rejection, never relax runtime scope.
        var descriptor = try PortableInstance.databaseDescriptor(root); descriptor.schemaVersion = "4"
        try SafeFS.write(descriptor, to: descriptorFile)
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let journal = try DurableFileEffectJournal(store: StateStore(databaseName: db.databaseName, instanceRoot: root),
            scope: FileEffectJournalScope(instanceID: identity.instanceID, generation: Int64(identity.generation),
                userID: Data("fixture-owner".utf8), originScopeSHA256: String(repeating: "a", count: 64)))
        let record = try journal.prepareRecycle(key: Data(UUID().uuidString.utf8), intent: journalIntent(),
            volumeID: UUID(), vaultID: UUID(), byteCount: 0, evidence: journalEvidence(bytes: 0))
        return cancelled ? try journal.cancelPreparedWithoutExecutor(operationID: record.operationID, expectedRevision: record.revision) : record
    }
    func testThreeToFourPreservesCompleteSourceProjectionAndUsesIsolatedEmptyCandidate() throws {
        let (source, original) = try populatedSchemaThree("source3"), before = try original.contentDigest(), target = child("candidate4")
        let record = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4)
        let candidate = try PortableInstance.store(target)
        XCTAssertEqual(record.phase, .publishedReadOnly); XCTAssertNotEqual(candidate.databaseName, original.databaseName)
        try original.validate(expectedVersion: 3); XCTAssertEqual(try original.contentDigest(), before)
        try candidate.validate(expectedVersion: 4); try candidate.validateUpgradeDefaults(from: 3)
        XCTAssertEqual(try candidate.contentDigest(asVersion: 3), before)
        XCTAssertFalse(try candidate.hasRecycleHistory())
        XCTAssertEqual(try candidate.rows("SELECT version FROM macnas.schema_migrations ORDER BY version;"), [["1"],["2"],["3"],["4"]])
        let queue = try DurableJobQueue(store: candidate)
        XCTAssertEqual(try queue.jobs(audience: .user("fixture-owner")).first?.state, "completed")
        denied(.denied) { _ = try queue.poll(consumerID: "new-consumer", audience: .user("fixture-owner")) }
        let repeated = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4)
        XCTAssertEqual(repeated.databaseName, record.databaseName)
    }
    func testFourSQLFailureRollsBackAndCommitBeforeJournalResumesOnce() throws {
        let source = try schemaSource("source3", version: 3), target = child("candidate4")
        denied(.database) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4, fault: .failSchemaSQL) }
        let record = try MigrationCoordinator.status(destination: target), candidate = try StateStore(databaseName: record.databaseName)
        try candidate.validate(expectedVersion: 3); XCTAssertEqual(try candidate.tableCount(), 10)
        denied(.interrupted) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4, fault: .at(.afterSchemaCommit)) }
        try candidate.validate(expectedVersion: 4); XCTAssertEqual(try candidate.tableCount(), 12)
        let resumed = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4)
        XCTAssertEqual(resumed.databaseName, record.databaseName)
        XCTAssertEqual(try candidate.rows("SELECT count(*) FROM macnas.schema_migrations WHERE version=4;"), [["1"]])
        try PortableInstance.store(source).validate(expectedVersion: 3)
    }
    func testFourCandidateOldJobAndCursorMutationFailsFullProjectionDespiteMatchingBaseDigest() throws {
        let (source, original) = try populatedSchemaThree("source3"), target = child("candidate4"), before = try original.contentDigest()
        denied(.interrupted) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4, fault: .at(.afterSchemaCommit)) }
        let record = try MigrationCoordinator.status(destination: target), candidate = try StateStore(databaseName: record.databaseName)
        try candidate.execute("UPDATE macnas.jobs SET attempts=attempts+1 WHERE id='old-managed'; UPDATE macnas.event_consumers SET delivered_sequence=delivered_sequence+1;")
        XCTAssertEqual(try candidate.baseDataDigest(), try original.baseDataDigest())
        XCTAssertNotEqual(try candidate.contentDigest(asVersion: 3), before)
        denied(.integrity) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4) }
        XCTAssertEqual(try original.contentDigest(), before); XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }
    func testEmptyFourExportsRestoresAndRollsBackWithoutChangingSource() throws {
        let source = try schemaSource("source4", version: 4), db = try PortableInstance.store(source), before = try db.contentDigest()
        let package = child("export4"), target = child("restored4")
        try PortableInstance.export(from: source, to: package)
        try PortableInstance.restore(from: package, to: target, hostID: "new", confirmCreate: true)
        let candidate = try PortableInstance.store(target)
        try candidate.validate(expectedVersion: 4); XCTAssertEqual(try candidate.contentDigest(), before)
        XCTAssertEqual(try MigrationCoordinator.restore(from: package, to: target, hostID: "new").databaseName, candidate.databaseName)
        XCTAssertEqual(try MigrationCoordinator.rollback(destination: target, confirm: true).phase, .rolledBack)
        XCTAssertEqual(try db.contentDigest(), before); XCTAssertFalse(try db.hasRecycleHistory())
    }
    func testAnyFourHistoryIncludingCancelledReleasedRefusesOrdinaryPortable() throws {
        for cancelled in [false, true] {
            let root = try schemaSource(cancelled ? "cancelled4" : "prepared4", version: 4), db = try PortableInstance.store(root)
            let history = try addHistory(root: root, db: db, cancelled: cancelled), before = try db.contentDigest()
            XCTAssertEqual(history.phase, cancelled ? .cancelled : .prepared)
            XCTAssertEqual(history.chargeState, cancelled ? .released : .reserved)
            XCTAssertTrue(try db.hasRecycleHistory())
            denied(.unsupported) { try db.requirePortableRecycleEmpty() }
            denied(.unsupported) { _ = try PortableInstance.preview(root) }
            denied(.unsupported) { _ = try PortableInstance.export(from: root, to: self.child("export-" + String(cancelled))) }
            denied(.unsupported) { _ = try MigrationCoordinator.upgrade(from: root, to: self.child("upgrade-" + String(cancelled)), hostID: "new", targetVersion: 4) }
            XCTAssertEqual(try db.contentDigest(), before)
        }
    }
    func testHistoryAfterImportOrSchemaCommitPreventsCandidatePublication() throws {
        for importing in [true, false] {
            let source = try schemaSource(importing ? "source4" : "source3", version: importing ? 4 : 3), target = child(importing ? "imported4" : "upgraded4")
            let package = child("package4")
            if importing {
                try PortableInstance.export(from: source, to: package)
                denied(.interrupted) { _ = try MigrationCoordinator.restore(from: package, to: target, hostID: "new", fault: .at(.afterImportCommit)) }
            } else {
                denied(.interrupted) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4, fault: .at(.afterSchemaCommit)) }
            }
            let record = try MigrationCoordinator.status(destination: target), db = try StateStore(databaseName: record.databaseName)
            let stage = try SafeFS.resolve(lab, record.stagingName)
            _ = try addHistory(root: stage, db: db, cancelled: true)
            let before = try db.contentDigest()
            if importing { denied(.unsupported) { _ = try MigrationCoordinator.restore(from: package, to: target, hostID: "new") } }
            else { denied(.unsupported) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4) } }
            XCTAssertFalse(FileManager.default.fileExists(atPath: target.path)); XCTAssertEqual(try db.contentDigest(), before)
        }
    }
    func testPublishedHistoryRefusesResumeRollbackAndPortableButAllowsDiagnosticDatabaseSnapshot() throws {
        let source = try schemaSource("source3", version: 3), target = child("published4")
        let record = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4), db = try PortableInstance.store(target)
        _ = try addHistory(root: target, db: db, cancelled: true)
        let before = try db.contentDigest(), binding = try SafeFS.readData(SafeFS.resolve(target, "host-binding/binding.json"))
        denied(.unsupported) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4) }
        denied(.unsupported) { _ = try MigrationCoordinator.rollback(destination: target, confirm: true) }
        denied(.unsupported) { _ = try PortableInstance.export(from: target, to: self.child("refused-export")) }
        XCTAssertEqual(try MigrationCoordinator.status(destination: target).phase, record.phase)
        XCTAssertEqual(try SafeFS.readData(SafeFS.resolve(target, "host-binding/binding.json")), binding)
        XCTAssertEqual(try db.contentDigest(), before); XCTAssertEqual(try db.rows("SHOW default_transaction_read_only;"), [["on"]])
        let diagnostic = child("diagnostic-only.pgdump"); try db.snapshot(to: diagnostic)
        let restored = try StateStore.restoreSynthetic(archive: diagnostic)
        XCTAssertTrue(try restored.hasRecycleHistory()); XCTAssertEqual(try restored.contentDigest(), before)
        XCTAssertFalse(FileManager.default.fileExists(atPath: child("refused-export").path))
        try PortableInstance.store(source).validate(expectedVersion: 3)
    }
    func testRollbackRejectsDamagedVersionHistoryWithoutChangingJournalBindingOrEntries() throws {
        let source = try schemaSource("source3", version: 3), target = child("damaged-published4")
        let record = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4)
        let candidate = try PortableInstance.store(target)
        _ = try addHistory(root: target, db: candidate, cancelled: true)
        let journalFile = try JournalStore.url(target), bindingFile = try SafeFS.resolve(target, "host-binding/binding.json")
        let journalBytes = try SafeFS.readData(journalFile), bindingBytes = try SafeFS.readData(bindingFile)
        let entries = try candidate.rows("SELECT to_jsonb(e)::text FROM macnas.recycle_entries e ORDER BY entry_id;")
        let operations = try candidate.rows("SELECT to_jsonb(o)::text FROM macnas.file_effect_operations o ORDER BY operation_id;")
        XCTAssertEqual(entries.count, 1); XCTAssertEqual(operations.count, 1)
        // Closed corruption fixture: the database still contains Schema 4 history,
        // but its version marker is damaged. Reject the candidate; this never undoes a file move.
        _ = try candidate.tools.sql("DELETE FROM macnas.schema_migrations WHERE version=4;", database: candidate.databaseName, admin: true)
        XCTAssertEqual(try candidate.schemaVersion(), 3); XCTAssertEqual(try candidate.tableCount(), 12)
        denied(.invalidSchema) { _ = try MigrationCoordinator.rollback(destination: target, confirm: true) }
        XCTAssertEqual(try SafeFS.readData(journalFile), journalBytes)
        XCTAssertEqual(try SafeFS.readData(bindingFile), bindingBytes)
        XCTAssertEqual(try MigrationCoordinator.status(destination: target).phase, record.phase)
        XCTAssertEqual(try candidate.rows("SELECT to_jsonb(e)::text FROM macnas.recycle_entries e ORDER BY entry_id;"), entries)
        XCTAssertEqual(try candidate.rows("SELECT to_jsonb(o)::text FROM macnas.file_effect_operations o ORDER BY operation_id;"), operations)
        XCTAssertEqual(try candidate.rows("SELECT version FROM macnas.schema_migrations ORDER BY version;"), [["1"],["2"],["3"]])
        XCTAssertEqual(try candidate.rows("SHOW default_transaction_read_only;"), [["on"]])
        try PortableInstance.store(source).validate(expectedVersion: 3)
    }
    func testSchemaFourUnknownHostMarkersAndPayloadDirectoriesFailClosed() throws {
        for marker in ["fixtures", "transfer-staging", "unknown-vault"] {
            let root = try schemaSource(marker, version: 4), directory = try SafeFS.resolve(root, "host-binding/" + marker)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            let payload = directory.appendingPathComponent("preserve"); try Data("do-not-adopt".utf8).write(to: payload)
            denied(.unsupported) { _ = try PortableInstance.export(from: root, to: self.child("export-" + marker)) }
            XCTAssertEqual(try Data(contentsOf: payload), Data("do-not-adopt".utf8))
        }
        let root = try schemaSource("unknown-binding", version: 4), file = try SafeFS.resolve(root, "host-binding/binding.json")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: SafeFS.readData(file)) as? [String: Any]); object["vaultRegistration"] = "unknown"
        let bytes = try JSONSerialization.data(withJSONObject: object); try bytes.write(to: file)
        denied(.invalidSchema) { _ = try PortableInstance.export(from: root, to: self.child("unknown-export")) }
        XCTAssertEqual(try SafeFS.readData(file), bytes)
    }
    func testSchemaThreeHostExclusionBehaviorRemainsUnchanged() throws {
        let root = try schemaSource("legacy3", version: 3), excluded = try SafeFS.resolve(root, "host-binding/legacy-excluded")
        try FileManager.default.createDirectory(at: excluded, withIntermediateDirectories: false)
        try Data("legacy-host-only".utf8).write(to: excluded.appendingPathComponent("marker"))
        let package = child("legacy-export"); try PortableInstance.export(from: root, to: package)
        XCTAssertFalse(FileManager.default.fileExists(atPath: package.appendingPathComponent("host-binding").path))
    }
    func testSchemaFourOldJobsPluginsBridgeAndAppIsolationRemainAvailable() throws {
        let root = try schemaSource("compatible4", version: 4), db = try PortableInstance.store(root), api = try PrototypePlatformAPI(root: root)
        let session = try api.beginFixtureSession(userID: "fixture-owner"), bridge = try DesktopBridge(api: api, session: session)
        defer { bridge.close() }
        let request = try JSONSerialization.data(withJSONObject: ["apiVersion":1,"requestId":"overview4","method":"overview","params":[:] as [String: String]])
        let reply = try XCTUnwrap(JSONSerialization.jsonObject(with: bridge.handle(request)) as? [String: Any])
        XCTAssertEqual((reply["data"] as? [String: Any])?["databaseSchema"] as? Int, 4)
        _ = try api.submitLabelJob(id: "four-job", key: "four-job-key", label: "four-label", value: "old-job-path", session: session)
        _ = try DurableJobQueue(store: db).workOne()
        XCTAssertEqual(try api.durableJobs(session: session).first?.state, "completed")
        denied(.unsupported) { try api.enqueue(id: "legacy", key: "legacy-key", session: session) }
        _ = try api.issueAppGrant(app: .diagnostics, session: session)
        for app in SampleApp.allCases {
            XCTAssertFalse(try db.tools.sql("SELECT value FROM \(app.schema).state;", database: db.databaseName, principal: .app(app)).isEmpty)
            for table in ["recycle_entries", "file_effect_operations"] {
                denied(.database) { _ = try db.tools.sql("SELECT * FROM macnas.\(table);", database: db.databaseName, principal: .app(app)) }
            }
        }
    }
    func schemaFourPublicFunctionCount(_ db: StateStore) throws -> [[String]] {
        try db.rows("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='macnas' AND EXISTS(SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) a WHERE a.grantee=0 AND a.privilege_type='EXECUTE');")
    }
    func testImportCommittedBeforeFunctionHardeningResumesOnlyAtDatabasePlanned() throws {
        let source = try schemaSource("source4", version: 4), package = child("export4"), target = child("restored4")
        try PortableInstance.export(from: source, to: package)
        denied(.interrupted) { _ = try MigrationCoordinator.restore(from: package, to: target, hostID: "new", fault: .at(.afterDatabaseCreated)) }
        let record = try MigrationCoordinator.status(destination: target), candidate = try StateStore(databaseName: record.databaseName)
        XCTAssertEqual(record.phase, .databasePlanned); XCTAssertEqual(try candidate.tableCount(), 0)
        // Closed import crash fixture: bypass importArchive so pg_restore's no-privileges
        // commit is preserved with the six default PUBLIC EXECUTE grants still present.
        _ = try candidate.tools.run("pg_restore", candidate.tools.connection(candidate.databaseName) +
            ["--no-owner", "--no-privileges", "--no-tablespaces", "--exit-on-error", "--single-transaction", try SafeFS.resolve(package, "state/platform.pgdump").path])
        XCTAssertEqual(try candidate.schemaVersion(), 4); XCTAssertEqual(try candidate.tableCount(), 12)
        XCTAssertEqual(try schemaFourPublicFunctionCount(candidate), [["6"]])
        let resumed = try MigrationCoordinator.restore(from: package, to: target, hostID: "new")
        XCTAssertEqual(resumed.databaseName, record.databaseName); XCTAssertEqual(resumed.phase, .publishedReadOnly)
        XCTAssertEqual(try schemaFourPublicFunctionCount(candidate), [["0"]]); try candidate.validate(expectedVersion: 4)
        XCTAssertEqual(try candidate.contentDigest(), try PortableInstance.store(source).contentDigest())
    }
    func testPublishedPublicFunctionGrantIsRejectedWithoutAutomaticRepair() throws {
        let source = try schemaSource("source3", version: 3), target = child("published4")
        let record = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4), candidate = try PortableInstance.store(target)
        _ = try candidate.tools.sql("GRANT EXECUTE ON FUNCTION macnas.valid_file_effect_path(text,boolean) TO PUBLIC;", database: candidate.databaseName, admin: true)
        XCTAssertEqual(try schemaFourPublicFunctionCount(candidate), [["1"]])
        denied(.invalidSchema) { _ = try MigrationCoordinator.upgrade(from: source, to: target, hostID: "new", targetVersion: 4) }
        XCTAssertEqual(try schemaFourPublicFunctionCount(candidate), [["1"]])
        XCTAssertEqual(try MigrationCoordinator.status(destination: target).phase, record.phase)
        XCTAssertEqual(try candidate.rows("SHOW default_transaction_read_only;"), [["on"]])
    }
    func testAllTwelvePersistentTablesParticipateInSchemaFourFreeze() throws {
        let root = try schemaSource("freeze4", version: 4), db = try PortableInstance.store(root)
        let tables = [("macnas.schema_migrations","version"),("macnas.labels","value"),("macnas.jobs","effects"),
            ("app_hello_diagnostics.state","value"),("app_sample_file_index.state","value"),
            ("macnas.job_steps","step"),("macnas.event_clock","next_sequence"),("macnas.job_events","revision"),
            ("macnas.event_consumers","ack_sequence"),("macnas.event_receipts","sequence"),
            ("macnas.recycle_entries","revision"),("macnas.file_effect_operations","revision")]
        var writers: [Process] = []
        defer { for writer in writers where writer.isRunning { ChildControl.stop(writer) } }
        do {
            let barrier = try DatabaseSnapshotBarrier(store: db)
            for (index, table) in tables.enumerated() {
                let name = "schema4-freeze-\(index)", writer = Process()
                writer.executableURL = db.tools.bin.appendingPathComponent("psql")
                writer.arguments = try db.tools.connection(db.databaseName) + ["-X","-q","--set","ON_ERROR_STOP=1","-c","UPDATE \(table.0) SET \(table.1)=\(table.1);"]
                writer.environment = db.tools.environment(application: name)
                writer.standardOutput = FileHandle.nullDevice; writer.standardError = FileHandle.nullDevice
                try writer.run(); writers.append(writer)
                let deadline = ProcessInfo.processInfo.systemUptime + 3
                var blocked = false
                while ProcessInfo.processInfo.systemUptime < deadline {
                    blocked = try db.tools.sql("SELECT count(*) FROM pg_stat_activity WHERE application_name='\(name)' AND wait_event_type='Lock';", database: "postgres", admin: true) == "1"
                    if blocked { break }; Thread.sleep(forTimeInterval: 0.01)
                }
                XCTAssertTrue(blocked, table.0)
            }
            XCTAssertEqual(try db.rows("SELECT count(*) FROM macnas.labels;"), [["1"]]); try barrier.check()
        }
        for writer in writers { writer.waitUntilExit(); XCTAssertEqual(writer.terminationStatus, 0) }
    }
}
