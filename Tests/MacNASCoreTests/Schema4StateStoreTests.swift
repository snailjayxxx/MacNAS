import Foundation
import CryptoKit
import XCTest
@testable import MacNASCore

final class Schema4StateStoreTests: FileEffectJournalLab {
    private func oldCanonical(_ version: Int) -> String {
        let app=version>=2 ? "id,value,revision":"id,value",jobs=version>=3 ? "*":"id,idempotency_key,state,effects,checkpoint"
        var extra=""
        if version>=3 {
            for (table,order) in [("job_steps","job_id,step"),("job_events","sequence"),("event_clock","singleton"),("event_consumers","id"),("event_receipts","consumer_id,sequence")] {
                extra += ",'\(table)',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY \(order)),'[]') FROM macnas.\(table) t)"
            }
        }
        return "jsonb_build_object('schema',\(version),'labels',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT id,value FROM macnas.labels) t),'jobs',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(jobs) FROM macnas.jobs) t),'diagnostics',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(app) FROM app_hello_diagnostics.state) t),'fileIndex',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(app) FROM app_sample_file_index.state) t)\(extra))"
    }
    func testMigration4FileMatchesEmbeddedAndInjectFailureLeavesSchema3Untouched() throws {
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        XCTAssertEqual(try String(contentsOf:repo.appendingPathComponent("database/migrations/0004_recycle_effect_journal.sql"),encoding:.utf8),StateStore.migration4SQL+"\n")
        let db=try StateStore.createSynthetic(schemaVersion:3);try db.label("中日","retain");try db.enqueue("legacy",key:"same")
        let before=try db.contentDigest()
        denied(.database){_ = try db.migrate(toVersion:4,injectFailure:true)}
        XCTAssertEqual(try db.schemaVersion(),3);XCTAssertEqual(try db.contentDigest(),before);XCTAssertEqual(try db.tableCount(),10)
        XCTAssertTrue(try db.migrate(toVersion:4));XCTAssertFalse(try db.migrate(toVersion:4));try db.validateUpgradeDefaults(from:3)
        XCTAssertEqual(try db.tableCount(),12);XCTAssertEqual(try db.contentDigest(asVersion:3),before)
    }
    func testDatabaseSHAEqualsPreviousSwiftSHAForAllThreeLegacyFormatsAndExactSize() throws {
        for version in 1...3 {
            let db=try StateStore.createSynthetic(schemaVersion:version);try db.label("Unicode-日本"," value \t 中 ");try db.enqueue("job",key:"key")
            let canonical=try db.tools.sql("SELECT (\(oldCanonical(version)))::text;",database:db.databaseName)
            let old=SHA256.hash(data:Data(canonical.utf8)).map{String(format:"%02x",$0)}.joined()
            XCTAssertEqual(try db.contentDigest(),old)
            if version==3 { XCTAssertEqual(try db.rows("SELECT octet_length((\(oldCanonical(3)))::text),(\(StateStore.legacyMetadataBytesSQL));").first,[String(canonical.utf8.count),String(canonical.utf8.count)]) }
        }
    }
    func testAllSchema3TaskAndEventFieldsSurviveVersion4Projection() throws {
        let db=try StateStore.createSynthetic(schemaVersion:3)
        try db.execute("""
        INSERT INTO macnas.jobs(id,idempotency_key,state,kind,owner_user,payload,attempts,max_attempts,next_run_at,revision,last_error)
          VALUES('managed','key','completed','label','owner','{"value":"中日"}',2,5,'2026-10-16T01:00:00Z',7,'interrupted');
        INSERT INTO macnas.job_steps VALUES('managed',0,'{"result":true}');
        UPDATE macnas.event_clock SET next_sequence=2;
        INSERT INTO macnas.job_events VALUES(1,'managed',7,'owner',NULL,'completed','completed');
        INSERT INTO macnas.event_consumers VALUES('consumer','owner',NULL,0,1);
        INSERT INTO macnas.event_receipts VALUES('consumer',1);
        """)
        let old=try (1...3).map{try db.contentDigest(asVersion:$0)}
        _ = try db.migrate(toVersion:4)
        for version in 1...3 { XCTAssertEqual(try db.contentDigest(asVersion:version),old[version-1]) }
        try db.execute("UPDATE macnas.jobs SET payload='{"+"\"value\":\"changed\"}'::jsonb;")
        XCTAssertNotEqual(try db.contentDigest(asVersion:3),old[2]);XCTAssertEqual(try db.contentDigest(asVersion:1),old[0])
    }
    func testFull4DigestIncludesEntryAndClosedCompletedFixtureButOlderProjectionDoesNot() throws {
        let (_,db,journal)=try journalFixture(),before=try db.contentDigest(),legacy=try db.contentDigest(asVersion:3)
        let record=try prepareJournal(journal,bytes:4)
        try db.validate(expectedVersion:4);XCTAssertTrue(try db.hasRecycleHistory());denied(.unsupported){try db.requirePortableRecycleEmpty()}
        let prepared=try db.contentDigest();XCTAssertNotEqual(prepared,before)
        // SQL-only effect fixture: this never claims that a source or payload was moved.
        _ = try journalRetainedFixture(db,record:record);try db.validate(expectedVersion:4)
        XCTAssertNotEqual(try db.contentDigest(),prepared);XCTAssertEqual(try db.contentDigest(asVersion:3),legacy)
        try db.execute("UPDATE macnas.recycle_entries SET retain_until=retain_until+interval '1 day';")
        XCTAssertNotEqual(try db.contentDigest(),prepared)
    }
    func testColumnTypeUnknownIndexAndWeakenedConstraintFailClosed() throws {
        for change in ["ALTER TABLE macnas.recycle_entries ALTER COLUMN revision TYPE numeric;",
                       "CREATE INDEX unexpected_recycle_index ON macnas.recycle_entries(revision);",
                       "ALTER TABLE macnas.recycle_entries DROP CONSTRAINT recycle_entries_data_check; ALTER TABLE macnas.recycle_entries ADD CONSTRAINT recycle_entries_data_check CHECK(true);"] {
            let db=try StateStore.createSynthetic(schemaVersion:4);try db.execute(change)
            denied(.invalidSchema){try db.validate()}
        }
    }
    func testValidatorFunctionReplacementIsRejectedEvenWhenCheckNameRemains() throws {
        let db=try StateStore.createSynthetic(schemaVersion:4)
        try db.execute("CREATE OR REPLACE FUNCTION macnas.valid_file_effect_path(value text,allow_empty boolean) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $$ SELECT true $$;")
        denied(.invalidSchema){try db.validate()}
    }
    func testRestoredConstraintFunctionsRejectMalformedWideRowsAndDigestRefusesActualSize() throws {
        let (_,db,journal)=try journalFixture();_ = try prepareJournal(journal)
        print("Schema4 wide-row stage: prepare complete")
        let functions=StateStore.schema4Functions.filter{["valid_recycle_entry","valid_file_effect_operation"].contains($0.0)}
        XCTAssertEqual(functions.count,2)
        func definition(_ name: String, body: String) -> String {
            let argument=name=="valid_recycle_entry" ? "e macnas.recycle_entries":"o macnas.file_effect_operations"
            return "CREATE OR REPLACE FUNCTION macnas.\(name)(\(argument)) RETURNS boolean LANGUAGE sql IMMUTABLE STRICT SET search_path=pg_catalog SET TimeZone='UTC' AS $restored_row_check$\n\(body)\n$restored_row_check$;"
        }
        // Deliberately corrupt only a synthetic DB, then restore the exact function fingerprints.
        // PostgreSQL does not recheck existing rows when a CHECK function body is restored.
        let weaken=functions.map{definition($0.0,body:"SELECT true")}.joined(separator:"\n")
        let restore=functions.map{definition($0.0,body:$0.2)}.joined(separator:"\n")
        try db.execute("""
        BEGIN;
        \(weaken)
        UPDATE macnas.recycle_entries SET original_path_utf8=convert_to(repeat('a',2100000),'UTF8');
        UPDATE macnas.file_effect_operations SET intent=jsonb_set(intent,'{sourcePath}',to_jsonb(repeat('a',2100000))) || '{"extra":true}'::jsonb;
        UPDATE macnas.file_effect_operations SET intent_sha256=encode(sha256(convert_to(intent::text,'UTF8')),'hex');
        \(restore)
        COMMIT;
        """)
        print("Schema4 wide-row stage: setup/restore complete")
        XCTAssertEqual(try db.rows("SELECT (SELECT sum(octet_length(to_jsonb(e)::text)) FROM macnas.recycle_entries e)+(SELECT sum(octet_length(to_jsonb(o)::text)) FROM macnas.file_effect_operations o)>4000000;"),[["t"]])
        print("Schema4 wide-row stage: size scalar complete")
        denied(.invalidSchema){try db.validate()}
        print("Schema4 wide-row stage: validate rejection complete")
        denied(.budgetExceeded){_ = try db.contentDigest()}
        print("Schema4 wide-row stage: digest rejection complete")
        XCTAssertEqual(try db.rows("SELECT (SELECT count(*) FROM macnas.recycle_entries),(SELECT count(*) FROM macnas.file_effect_operations),(SELECT octet_length(original_path_utf8) FROM macnas.recycle_entries),(SELECT length(intent->>'sourcePath') FROM macnas.file_effect_operations),(SELECT intent->>'extra' FROM macnas.file_effect_operations);"),[["1","1","2100000","2100000","true"]])
        print("Schema4 wide-row stage: preservation scalar complete")
    }
    func testDDLRejectsInvalidUTF8EvidenceStateAndIntentHash() throws {
        let (_,db,journal)=try journalFixture();_ = try prepareJournal(journal)
        for statement in ["UPDATE macnas.recycle_entries SET owner_user_utf8=decode('ff','hex');",
                          "UPDATE macnas.file_effect_operations SET pre_evidence=jsonb_set(pre_evidence,'{object,inode}','\"18446744073709551616\"');",
                          "UPDATE macnas.file_effect_operations SET post_evidence=pre_evidence;",
                          "UPDATE macnas.file_effect_operations SET intent_sha256=repeat('0',64);",
                          "UPDATE macnas.file_effect_operations SET phase='completed',completed_at=prepared_at;"] {
            denied(.database){try db.execute(statement)}
        }
        try db.validate()
    }
    func testCompositeForeignKeyAndSemanticActorChargeValidation() throws {
        let (_,db,journal)=try journalFixture(),one=try prepareJournal(journal,name:"one"),two=try prepareJournal(journal,name:"two")
        denied(.database){try db.execute("UPDATE macnas.recycle_entries SET active_operation_id=\(FileEffectMetadata.uuidSQL(two.operationID)) WHERE entry_id=\(FileEffectMetadata.uuidSQL(one.entryID));")}
        try db.execute("UPDATE macnas.file_effect_operations SET actor_user_utf8=convert_to('other','UTF8') WHERE operation_id=\(FileEffectMetadata.uuidSQL(one.operationID));")
        denied(.invalidSchema){try db.validate()}
    }
    func testChargeMismatchDoesNotPassSchemaValidation() throws {
        let (_,db,journal)=try journalFixture();_ = try prepareJournal(journal)
        try db.execute("UPDATE macnas.recycle_entries SET charge_state='retained';")
        denied(.invalidSchema){try db.validate()}
    }
    func testSchema4RejectsMissingMigrationAndBothAppRolesCannotAccessEitherCoreTable() throws {
        let db=try StateStore.createSynthetic(schemaVersion:4)
        for app in SampleApp.allCases {
            for table in ["recycle_entries","file_effect_operations"] {
                XCTAssertEqual(try db.rows("SELECT has_table_privilege(\(StateStore.quote(app.role(database:db.databaseName))),'macnas.\(table)','SELECT,INSERT,UPDATE,DELETE');"),[["f"]])
                for statement in ["SELECT * FROM macnas.\(table) LIMIT 0;","INSERT INTO macnas.\(table) SELECT * FROM macnas.\(table) LIMIT 0;","UPDATE macnas.\(table) SET revision=revision WHERE false;","DELETE FROM macnas.\(table) WHERE false;"] {
                    denied(.database){_ = try db.tools.sql(statement,database:db.databaseName,principal:.app(app))}
                }
            }
        }
        try db.execute("DELETE FROM macnas.schema_migrations WHERE version=3;");denied(.invalidSchema){_ = try db.schemaVersion()}
    }
    func testOversizedLegacyMetadataFailsBeforeDigestAggregationAndDoesNotTruncate() throws {
        let db=try StateStore.createSynthetic(schemaVersion:4)
        try db.execute("INSERT INTO macnas.labels VALUES('large',repeat('x',4000001));")
        denied(.budgetExceeded){_ = try db.contentDigest()};denied(.budgetExceeded){_ = try db.contentDigest(asVersion:3)}
        XCTAssertEqual(try db.rows("SELECT length(value) FROM macnas.labels WHERE id='large';"),[["4000001"]])
    }
    func testTruncateMisgrantIsRejectedAndSyntheticHistoryReallyCanBeRemovedByThatPrivilege() throws {
        let (_,db,journal)=try journalFixture();_ = try prepareJournal(journal)
        let role=SampleApp.diagnostics.role(database:db.databaseName)
        // Deliberate permission corruption in a fresh synthetic DB. No real payload or filesystem effect exists.
        try db.execute("GRANT USAGE ON SCHEMA macnas TO \(role); GRANT TRUNCATE ON macnas.recycle_entries,macnas.file_effect_operations TO \(role);")
        denied(.denied){try db.validate()}
        _ = try db.tools.sql("TRUNCATE macnas.file_effect_operations,macnas.recycle_entries;",database:db.databaseName,principal:.app(.diagnostics))
        XCTAssertEqual(try db.rows("SELECT (SELECT count(*) FROM macnas.recycle_entries),(SELECT count(*) FROM macnas.file_effect_operations);"),[["0","0"]])
    }
    func testEveryCoreTablePrivilegeMisgrantFailsValidationForBothApps() throws {
        let db=try StateStore.createSynthetic(schemaVersion:4)
        for app in SampleApp.allCases {
            let role=app.role(database:db.databaseName)
            for privilege in ["SELECT","INSERT","UPDATE","DELETE","TRUNCATE","REFERENCES","TRIGGER","MAINTAIN"] {
                try db.execute("GRANT \(privilege) ON macnas.recycle_entries,macnas.file_effect_operations TO \(role);")
                denied(.denied){try db.validate()}
                try db.execute("REVOKE \(privilege) ON macnas.recycle_entries,macnas.file_effect_operations FROM \(role);")
            }
        }
        try db.validate()
    }
    func testCoreSchemaAndValidatorFunctionMisgrantsFailValidationForBothApps() throws {
        let db=try StateStore.createSynthetic(schemaVersion:4)
        for app in SampleApp.allCases {
            let role=app.role(database:db.databaseName)
            for privilege in ["USAGE","CREATE"] {
                try db.execute("GRANT \(privilege) ON SCHEMA macnas TO \(role);")
                denied(.denied){try db.validate()}
                try db.execute("REVOKE \(privilege) ON SCHEMA macnas FROM \(role);")
            }
            for (name,arguments,_) in StateStore.schema4Functions {
                try db.execute("GRANT EXECUTE ON FUNCTION macnas.\(name)(\(arguments)) TO \(role);")
                denied(.denied){try db.validate()}
                try db.execute("REVOKE EXECUTE ON FUNCTION macnas.\(name)(\(arguments)) FROM \(role);")
            }
        }
        try db.validate()
    }
    func testDiagnosticImportRebuildsOnlyKnownPublicFunctionBoundaryAndKeepsStrictValidation() throws {
        let source=try StateStore.createSynthetic(schemaVersion:4),archive=child("schema4-diagnostic.pgdump")
        try source.snapshot(to:archive)
        let restored=try StateStore.createEmpty(name:StateStore.plannedName(UUID()),attestation:"macnas-synthetic-schema4-import-test")
        try restored.importArchive(archive);try restored.installAppRoles()
        try restored.validate(expectedVersion:4)
        XCTAssertEqual(try restored.rows("SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace, LATERAL aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl WHERE n.nspname='macnas' AND acl.grantee=0 AND acl.privilege_type='EXECUTE';"),[["0"]])
        XCTAssertEqual(try source.contentDigest(),try restored.contentDigest())
        // Idempotent on an isolated imported candidate; no ordinary validation repairs privileges.
        try restored.hardenImportedSchema4FunctionPrivileges();try restored.validate()
        try restored.execute("GRANT EXECUTE ON FUNCTION macnas.valid_file_effect_path(text,boolean) TO PUBLIC;")
        denied(.invalidSchema){try restored.validate()}
    }
}
