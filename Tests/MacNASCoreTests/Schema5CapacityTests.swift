import Foundation
import XCTest
@testable import MacNASCore

final class Schema5CapacityTests: CapacityLedgerLab {
    func testMigrationFileRollbackAndAllOlderDigestProjections() throws {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf:repo.appendingPathComponent("database/migrations/0005_durable_capacity.sql"),encoding:.utf8),StateStore.migration5SQL+"\n")
        let db = try StateStore.createSynthetic(schemaVersion:4); try db.label("日本中日","retain"); try db.enqueue("legacy",key:"keep")
        let before = try (1...4).map { try db.contentDigest(asVersion:$0) }
        denied(.database) { _ = try db.migrate(toVersion:5,injectFailure:true) }
        XCTAssertEqual(try db.schemaVersion(),4); XCTAssertEqual(try db.contentDigest(),before[3]); XCTAssertEqual(try db.tableCount(),12)
        XCTAssertTrue(try db.migrate(toVersion:5)); XCTAssertFalse(try db.migrate(toVersion:5))
        try db.validateUpgradeDefaults(from:4); XCTAssertEqual(try db.tableCount(),14)
        for version in 1...4 { XCTAssertEqual(try db.contentDigest(asVersion:version),before[version-1]) }
    }
    func testCapacityChangesFullDigestAndRetainsEveryOlderProjection() throws {
        let (_,store,ledger,_) = try capacityFixture(), older = try (1...4).map { try store.contentDigest(asVersion:$0) }, before = try store.contentDigest()
        _ = try ledger.createMetadataScope(confirmed:true)
        let scoped = try store.contentDigest(); XCTAssertNotEqual(scoped,before)
        let r = try reserve(ledger); let reserved = try store.contentDigest(); XCTAssertNotEqual(reserved,scoped)
        _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:1)
        XCTAssertNotEqual(try store.contentDigest(),reserved)
        for version in 1...4 { XCTAssertEqual(try store.contentDigest(asVersion:version),older[version-1]) }
    }
    func testColumnsChecksIndexesAndFunctionReplacementsAreStrictlyValidated() throws {
        for sql in [
            "ALTER TABLE macnas.capacity_allocations ADD COLUMN hidden text;",
            "ALTER TABLE macnas.capacity_allocations DROP CONSTRAINT capacity_allocations_data_check; ALTER TABLE macnas.capacity_allocations ADD CONSTRAINT capacity_allocations_data_check CHECK(true);",
            "CREATE INDEX unapproved_capacity_index ON macnas.capacity_allocations(revision);",
            "CREATE OR REPLACE FUNCTION macnas.valid_capacity_scope(s macnas.capacity_scopes) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $$ SELECT true $$;"
        ] {
            let db = try StateStore.createSynthetic(schemaVersion:5); try db.execute(sql)
            denied(.invalidSchema) { try db.validate() }
        }
    }
    func testInvalidRowUpdatesCannotBypassPhaseAndRowBudgetChecks() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true); _ = try reserve(ledger)
        let before = try store.contentDigest()
        for sql in [
            "UPDATE macnas.capacity_scopes SET singleton=false;",
            "UPDATE macnas.capacity_scopes SET byte_limit=67108865;",
            "UPDATE macnas.capacity_scopes SET owner_user_utf8=decode('ff','hex');",
            "UPDATE macnas.capacity_allocations SET declared_bytes=16777217;",
            "UPDATE macnas.capacity_allocations SET state='owned',revision=3;",
            "UPDATE macnas.capacity_allocations SET revision=9007199254740992;",
            "UPDATE macnas.capacity_allocations SET idempotency_key_utf8=convert_to(repeat('x',129),'UTF8');"
        ] { denied(.database) { try store.execute(sql) } }
        XCTAssertEqual(try store.contentDigest(),before); try store.validate()
    }
    func testBothAppRolesAreDeniedAllNewTablesAndValidatorFunctions() throws {
        let db = try StateStore.createSynthetic(schemaVersion:5)
        for app in SampleApp.allCases {
            for table in ["capacity_scopes","capacity_allocations"] {
                for sql in ["SELECT * FROM macnas.\(table);","DELETE FROM macnas.\(table) WHERE false;","TRUNCATE macnas.\(table);"] {
                    denied(.database) { _ = try db.tools.sql(sql,database:db.databaseName,principal:.app(app)) }
                }
            }
            for (name,args,_) in StateStore.schema5Functions {
                XCTAssertEqual(try db.rows("SELECT has_function_privilege(\(StateStore.quote(app.role(database:db.databaseName))),\(StateStore.quote("macnas.\(name)(\(args))")),'EXECUTE');"),[["f"]])
            }
        }
        let role = SampleApp.diagnostics.role(database:db.databaseName)
        try db.execute("GRANT TRUNCATE ON macnas.capacity_allocations TO \(role);")
        denied(.denied) { try db.validate() }
    }
    func testRestoreHardensAllEightFunctionsAndPreservesCancelledHistory() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let r = try reserve(ledger); _ = try ledger.cancelUnarmedMetadataOnly(r.allocationID,revision:1)
        let before = try store.contentDigest(), archive = child("capacity-metadata.pgdump")
        try store.snapshot(to:archive)
        let restored = try StateStore.restoreSynthetic(archive:archive)
        try restored.validate(expectedVersion:5); XCTAssertEqual(try restored.contentDigest(),before)
        XCTAssertTrue(try restored.hasCapacityHistory()); denied(.unsupported) { try restored.requirePortableRecycleEmpty() }
        XCTAssertEqual(try restored.rows("SELECT state,declared_bytes FROM macnas.capacity_allocations;"),[["cancelled","4"]])
        denied(.database) { try restored.execute("UPDATE macnas.capacity_allocations SET declared_bytes=declared_bytes;") }
    }
    func testAggregateBudgetValidationRejectsIndividuallyValidOvercommit() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        for n in 0..<4 { _ = try reserve(ledger,"\(n)",bytes:DurableCapacityLedger.fileLimit) }
        // Deliberately bypass the host ledger in this synthetic DB. Row constraints alone
        // cannot enforce the serialized total, so ordinary validation must reject it too.
        try store.execute("""
        INSERT INTO macnas.capacity_allocations
        SELECT '\(UUID().uuidString)'::uuid,scope_id,1,'copy',convert_to('sql-bypass','UTF8'),intent_sha256,1,'reserved',1,NULL,now(),NULL,NULL,NULL
        FROM macnas.capacity_allocations LIMIT 1;
        """)
        denied(.invalidSchema) { try store.validate() }
    }
    func testRestoredCheckFunctionDoesNotHideMalformedRowsOrOversizedDigest() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        _ = try reserve(ledger,"one"); _ = try reserve(ledger,"two")
        let function = try XCTUnwrap(StateStore.schema5Functions.first { $0.0 == "valid_capacity_allocation" })
        let prefix = "CREATE OR REPLACE FUNCTION macnas.valid_capacity_allocation(a macnas.capacity_allocations) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $capacity_restore$\n"
        try store.execute(prefix+"SELECT true\n$capacity_restore$;")
        try store.execute("UPDATE macnas.capacity_allocations SET intent_sha256=repeat('x',2100000);")
        try store.execute(prefix+function.2+"\n$capacity_restore$;")
        denied(.invalidSchema) { try store.validate() }
        denied(.budgetExceeded) { _ = try store.contentDigest() }
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.capacity_allocations;"),[["2"]])
    }
    func testSnapshotBarrierFreezesBothNewTablesUntilReleased() throws {
        let (_,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        do {
            let barrier = try DatabaseSnapshotBarrier(store:store)
            withExtendedLifetime(barrier) { denied(.database) { _ = try self.reserve(ledger,"blocked") } }
        }
         XCTAssertEqual(try ledger.totals().historyCount,0)
        _ = try reserve(ledger,"after-unlock"); XCTAssertEqual(try ledger.totals().historyCount,1)
    }
    func testFourToFiveIsolatedUpgradePreservesSourceAndResumesAfterSchemaCommit() throws {
        let source = child("source4"); try PortableInstance.createSynthetic(at:source,databaseVersion:4)
        let original = try PortableInstance.store(source), before = try original.contentDigest(), target = child("candidate5")
        denied(.database) { _ = try MigrationCoordinator.upgrade(from:source,to:target,hostID:"next",targetVersion:5,fault:.failSchemaSQL) }
        var journal = try MigrationCoordinator.status(destination:target)
        let candidate = try StateStore(databaseName:journal.databaseName)
        try candidate.validate(expectedVersion:4)
        denied(.interrupted) { _ = try MigrationCoordinator.upgrade(from:source,to:target,hostID:"next",targetVersion:5,fault:.at(.afterSchemaCommit)) }
        try candidate.validate(expectedVersion:5)
        journal = try MigrationCoordinator.upgrade(from:source,to:target,hostID:"next",targetVersion:5)
        XCTAssertEqual(journal.phase,.publishedReadOnly); XCTAssertNotEqual(candidate.databaseName,original.databaseName)
        XCTAssertEqual(try candidate.contentDigest(asVersion:4),before); XCTAssertEqual(try original.contentDigest(),before)
        XCTAssertFalse(try candidate.hasCapacityHistory())
        denied(.database) { try candidate.label("read-only","denied") }
        _ = try MigrationCoordinator.rollback(destination:target,confirm:true)
    }
    func testOrdinaryExportRefusesEvenAnEmptyCapacityScopeWithoutCreatingDestination() throws {
        let (root,_,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        let output = child("must-not-create")
        denied(.unsupported) { try PortableInstance.export(from:root,to:output) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
    }
    func testExistingAuthorityDoesNotFollowSchemaUpgradeInPlace() throws {
        let root = child("schema-pinning"); try PortableInstance.createSynthetic(at:root,databaseVersion:4)
        let host = try FixtureRecycleAuthority(root:root,userID:Data("fixture-owner".utf8)); _ = try host.createFreshFixture(confirmed:true)
        let identity = try SafeFS.read(InstanceIdentity.self,SafeFS.resolve(root,"instance.json"))
        let journal = try DurableFileEffectJournal(store:host.store,scope:FileEffectJournalScope(instanceID:identity.instanceID,generation:Int64(identity.generation),userID:Data("fixture-owner".utf8),originScopeSHA256:capacityHash))
        // Internal-only in-place upgrade fixture. Ordinary product upgrade uses an isolated
        // candidate; this proves a pre-existing native authority cannot follow a version change.
        _ = try host.store.migrate(toVersion:5)
        var descriptor = try PortableInstance.databaseDescriptor(root); descriptor.schemaVersion = "5"
        try SafeFS.write(descriptor,to:SafeFS.resolve(root,"state/database.json"))
        denied(.invalidSchema) { _ = try host.approve(.observe,confirmed:true) }
        denied(.invalidSchema) { _ = try journal.record(operationID:UUID()) }
        let fresh = try FixtureRecycleAuthority(root:root,userID:Data("fixture-owner".utf8))
        XCTAssertNoThrow(try fresh.approve(.observe,confirmed:true))
    }

    func testHiddenSchemaFiveHistoryCannotBecomeAnOldPortableSource() throws {
        let (root,store,ledger,_) = try capacityFixture(); _ = try ledger.createMetadataScope(confirmed:true)
        try store.execute("DELETE FROM macnas.schema_migrations WHERE version=5;")
        var descriptor = try PortableInstance.databaseDescriptor(root); descriptor.schemaVersion = "4"
        try SafeFS.write(descriptor,to:SafeFS.resolve(root,"state/database.json"))
        for id in PortableInstance.sampleIDs {
            try SafeFS.write(PluginManifest.sample(id,dataSchema:4),to:SafeFS.resolve(root,"apps/\(id)/manifest.json"))
            let schema = id == "hello-diagnostics" ? "app_hello_diagnostics" : "app_sample_file_index"
            try SafeFS.write(["dataSchema":"4","schema":schema],to:SafeFS.resolve(root,"app-data/\(id)/schema.json"))
        }
        let output = child("hidden-history")
        denied(.invalidSchema) { try PortableInstance.export(from:root,to:output) }
        XCTAssertFalse(FileManager.default.fileExists(atPath:output.path))
        XCTAssertEqual(try store.rows("SELECT count(*) FROM macnas.capacity_scopes;"),[["1"]])
    }
}
