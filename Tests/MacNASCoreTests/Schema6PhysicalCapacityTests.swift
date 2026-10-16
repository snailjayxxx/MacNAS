import Foundation
import XCTest
@testable import MacNASCore

final class Schema6PhysicalCapacityTests: PhysicalCapacityLab {
    func testMigrationFileDDLAtomicityAndAllFiveOlderDigestProjections() throws {
        let repo = URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf:repo.appendingPathComponent("database/migrations/0006_physical_capacity_ownership.sql"),encoding:.utf8),StateStore.migration6SQL+"\n")
        let db = try StateStore.createSynthetic(schemaVersion:5), before = try (1...5).map { try db.contentDigest(asVersion:$0) }
        denied(.database) { _ = try db.migrate(toVersion:6,injectFailure:true) }
        XCTAssertEqual(try db.schemaVersion(),5); XCTAssertEqual(try db.tableCount(),14)
        XCTAssertEqual(try db.contentDigest(),before[4])
        XCTAssertTrue(try db.migrate(toVersion:6)); XCTAssertFalse(try db.migrate(toVersion:6)); XCTAssertEqual(try db.tableCount(),16)
        for version in 1...5 { XCTAssertEqual(try db.contentDigest(asVersion:version),before[version-1]) }
    }
    func testClosedPhysicalStructureFunctionBodiesAndIndexesAreChecked() throws {
        for sql in [
            "ALTER TABLE macnas.capacity_file_ownership ADD COLUMN unapproved text;",
            "ALTER TABLE macnas.physical_capacity_scopes DROP CONSTRAINT physical_capacity_scopes_data_check; ALTER TABLE macnas.physical_capacity_scopes ADD CONSTRAINT physical_capacity_scopes_data_check CHECK(true);",
            "CREATE INDEX hidden_physical_index ON macnas.capacity_file_ownership(sha256);",
            "CREATE OR REPLACE FUNCTION macnas.valid_capacity_file_ownership(o macnas.capacity_file_ownership) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $$ SELECT true $$;"
        ] {
            let db = try StateStore.createSynthetic(schemaVersion:6); try db.execute(sql)
            denied(.invalidSchema) { try db.validate() }
        }
    }
    func testPhysicalRowsChangeFullDigestAndPreserveAllEarlierProjections() throws {
        let root = child("digest"); try PortableInstance.createSynthetic(at:root,databaseVersion:6)
        let db = try PortableInstance.store(root), before = try db.contentDigest()
        _ = try FixturePhysicalCapacityNamespace.createFresh(root:root,userID:owner,confirmed:true)
        let host = try FixturePhysicalCapacityNamespace(root:root,userID:owner), projected = try db.contentDigest(asVersion:5)
        let scoped = try db.contentDigest(); XCTAssertNotEqual(scoped,before)
        let binding = try XCTUnwrap(try db.rows("SELECT registry_sha256 FROM macnas.physical_capacity_scopes;").first?.first)
        try db.execute("UPDATE macnas.physical_capacity_scopes SET registry_sha256='\(String(repeating:"e",count:64))';")
        XCTAssertNotEqual(try db.contentDigest(),scoped); XCTAssertEqual(try db.contentDigest(asVersion:5),projected)
        XCTAssertThrowsError(try FixturePhysicalCapacityNamespace(root:root,userID:owner))
        try db.execute("UPDATE macnas.physical_capacity_scopes SET registry_sha256='\(binding)';")
        _ = try receive(host); XCTAssertNotEqual(try db.contentDigest(),scoped)
        try db.validate()
    }
    func testBothAppRolesCannotReadWriteTruncateOrExecuteNewObjects() throws {
        let db = try StateStore.createSynthetic(schemaVersion:6)
        for app in SampleApp.allCases {
            for table in ["physical_capacity_scopes","capacity_file_ownership"] {
                for sql in ["SELECT * FROM macnas.\(table);","DELETE FROM macnas.\(table) WHERE false;","TRUNCATE macnas.\(table);"] {
                    denied(.database) { _ = try db.tools.sql(sql,database:db.databaseName,principal:.app(app)) }
                }
            }
            for (name,args,_) in StateStore.schema6Functions {
                XCTAssertEqual(try db.rows("SELECT has_function_privilege(\(StateStore.quote(app.role(database:db.databaseName))),\(StateStore.quote("macnas.\(name)(\(args))")),'EXECUTE');"),[["f"]])
            }
        }
        try db.execute("GRANT TRUNCATE ON macnas.capacity_file_ownership TO \(SampleApp.diagnostics.role(database:db.databaseName));")
        denied(.denied) { try db.validate() }
    }
    func testProofStateAndPhysicalScopeCrossChecksRejectMissingOrForgedRows() throws {
        for corrupt in [
            "DELETE FROM macnas.capacity_file_ownership;",
            "UPDATE macnas.capacity_file_ownership SET baseline_stamp=NULL,sha256=NULL,published_at=NULL;",
            "UPDATE macnas.capacity_file_ownership SET sha256='\(String(repeating:"f",count:64))';",
            "UPDATE macnas.capacity_file_ownership SET baseline_stamp=jsonb_set(baseline_stamp,'{bytes}','3'::jsonb);"
        ] {
            let (_,host) = try physicalLab(UUID().uuidString); _ = try receive(host)
            try host.store.execute(corrupt)
            denied(.invalidSchema) { try host.store.validate() }
        }
    }
    func testDiagnosticSnapshotRestoresTenPrivateValidatorsAndIdentityMetadataOnly() throws {
        let (_,host) = try physicalLab(); _ = try receive(host)
        let digest = try host.store.contentDigest(), archive = child("metadata-only.pgdump")
        try host.store.snapshot(to:archive)
        let restored = try StateStore.restoreSynthetic(archive:archive)
        try restored.validate(expectedVersion:6); XCTAssertEqual(try restored.contentDigest(),digest)
        XCTAssertEqual(try restored.rows("SELECT count(*) FROM macnas.capacity_file_ownership WHERE baseline_stamp IS NOT NULL;"),[["1"]])
        denied(.unsupported) { try restored.requirePortableRecycleEmpty() }
        XCTAssertEqual(try restored.rows("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON p.pronamespace=n.oid, LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) x WHERE n.nspname='macnas' AND x.grantee=0 AND x.privilege_type='EXECUTE';"),[["0"]])
        denied(.database) { try restored.execute("UPDATE macnas.capacity_file_ownership SET ownership_version=ownership_version;") }
    }
    func testSnapshotBarrierIncludesBothPhysicalTables() throws {
        let (_,host) = try physicalLab(); _ = try receive(host)
        do {
            let barrier = try DatabaseSnapshotBarrier(store:host.store)
            withExtendedLifetime(barrier) {
                for table in ["physical_capacity_scopes","capacity_file_ownership"] {
                    denied(.database) { try host.store.execute("BEGIN; SET LOCAL lock_timeout='100ms'; UPDATE macnas.\(table) SET \(table == "physical_capacity_scopes" ? "binding_version=binding_version" : "ownership_version=ownership_version"); COMMIT;") }
                }
            }
        }
        try host.store.validate()
    }
    func testEmptySixStillSupportsIsolatedUpgradeReadOnlyJobsAndRollback() throws {
        let source = child("source5"); try PortableInstance.createSynthetic(at:source,databaseVersion:5)
        let sourceDB = try PortableInstance.store(source), before = try sourceDB.contentDigest(), target = child("target6")
        denied(.interrupted) { _ = try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new-host",targetVersion:6,fault:.at(.afterSchemaCommit)) }
        let journal = try MigrationCoordinator.upgrade(from:source,to:target,hostID:"new-host",targetVersion:6), db = try StateStore(databaseName:journal.databaseName)
        XCTAssertEqual(journal.phase,.publishedReadOnly); try db.validate(expectedVersion:6)
        XCTAssertEqual(try db.contentDigest(asVersion:5),before); XCTAssertEqual(try sourceDB.contentDigest(),before)
        denied(.database) { _ = try db.enqueue("read-only",key:"refuse") }
        _ = try MigrationCoordinator.rollback(destination:target,confirm:true)
    }
    func testOldVersionDescriptorCannotHideManagedHostLayout() throws {
        let (root,_) = try physicalLab(), descriptor = try PortableInstance.databaseDescriptor(root)
        for version in 1...5 {
            let old = try StateStore.createSynthetic(schemaVersion:version)
            var binding = try SafeFS.read(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
            binding.databaseName = old.databaseName; try SafeFS.write(binding,to:SafeFS.resolve(root,"host-binding/binding.json"))
            var changed = descriptor; changed.schemaVersion = String(version)
            try SafeFS.write(changed,to:SafeFS.resolve(root,"state/database.json"))
            XCTAssertThrowsError(try PortableInstance.export(from:root,to:child("old-export-\(version)")))
            XCTAssertFalse(FileManager.default.fileExists(atPath:child("old-export-\(version)").path))
        }
    }
}
