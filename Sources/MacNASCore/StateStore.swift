import Foundation
import CryptoKit

public enum SampleApp: String, Codable, CaseIterable, Sendable {
    case diagnostics = "hello-diagnostics", fileIndex = "sample-file-index"
    var schema: String { self == .diagnostics ? "app_hello_diagnostics" : "app_sample_file_index" }
    func role(database: String) -> String {
        (self == .diagnostics ? "macnas_diag_" : "macnas_index_") + database.replacingOccurrences(of: "macnas_fixture_", with: "")
    }
}
enum DatabasePrincipal {
    case owner, admin, app(SampleApp)
    var isAdmin: Bool { if case .admin = self { return true }; return false }
}

public struct PostgreSQLTools {
    public var bin: URL
    public var socket: URL
    public var scratch: URL
    public init() throws {
        let env = ProcessInfo.processInfo.environment
        guard let bin = env["MACNAS_PG_BIN"], let socket = env["MACNAS_PG_SOCKET"], let scratch = env["MACNAS_TESTLAB"] else { throw NASError.unsupported }
        self.bin = URL(fileURLWithPath: bin); self.socket = URL(fileURLWithPath: socket); self.scratch = URL(fileURLWithPath: scratch)
        try SafeFS.inspect(self.bin); try SafeFS.inspect(self.scratch)
        try require(socket.hasPrefix("/private/tmp/macnas-pg-") && !socket.contains(".."), .denied)
    }
    static func fixtureName(_ name: String) throws {
        try require(name.hasPrefix("macnas_fixture_") && name.count <= 60 && name.count > 15 && name.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "_") }, .denied)
    }
    func connection(_ database: String, admin: Bool = false) throws -> [String] {
        try connection(database, principal: admin ? .admin : .owner)
    }
    func connection(_ database: String, principal: DatabasePrincipal) throws -> [String] {
        if database != "postgres" { try Self.fixtureName(database) }
        let role: String
        switch principal { case .owner: role = "macnas_test_owner"; case .admin: role = "macnas_test_admin"; case .app(let app): try Self.fixtureName(database); role = app.role(database: database) }
        return ["--host", socket.path, "--port", "55432", "--username", role, "--no-password", "--dbname", database]
    }
    func environment(application: String = "macnas-synthetic-prototype") -> [String: String] {
        ["PATH": "/usr/bin:/bin", "HOME": socket.path, "LANG": "C", "LC_ALL": "C", "PGCONNECT_TIMEOUT": "3", "PGAPPNAME": application]
    }
    @discardableResult func run(_ executable: String, _ arguments: [String], input: String? = nil, timeout: TimeInterval = 30, cancellation: CancellationToken? = nil) throws -> String {
        try require(["psql", "pg_dump", "pg_restore", "createdb", "dropdb"].contains(executable) && timeout > 0 && timeout <= 60, .denied)
        try cancellation?.check()
        let tool = try SafeFS.resolve(bin, executable)
        let out = scratch.appendingPathComponent("pg-output-\(UUID().uuidString)"), err = scratch.appendingPathComponent("pg-error-\(UUID().uuidString)"), stdin = scratch.appendingPathComponent("pg-input-\(UUID().uuidString)")
        FileManager.default.createFile(atPath: out.path, contents: nil); FileManager.default.createFile(atPath: err.path, contents: nil)
        try Data((input ?? "").utf8).write(to: stdin)
        defer { for file in [out, err, stdin] { try? FileManager.default.removeItem(at: file) } }
        let stdoutHandle = try FileHandle(forWritingTo: out), stderrHandle = try FileHandle(forWritingTo: err), stdinHandle = try FileHandle(forReadingFrom: stdin)
        defer { try? stdoutHandle.close(); try? stderrHandle.close(); try? stdinHandle.close() }
        let process = Process(); process.executableURL = tool; process.arguments = arguments
        process.standardInput = stdinHandle; process.standardOutput = stdoutHandle; process.standardError = stderrHandle
        process.environment = environment()
        try process.run()
        do {
            let deadline = ProcessInfo.processInfo.systemUptime + timeout
            while process.isRunning {
                try cancellation?.check()
                for file in [out, err] {
                    let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.intValue ?? .max
                    try require(size <= 4_000_000, .budgetExceeded)
                }
                try require(ProcessInfo.processInfo.systemUptime < deadline, .timedOut)
                Thread.sleep(forTimeInterval: 0.01)
            }
            process.waitUntilExit()
        } catch { ChildControl.stop(process); throw error }
        try require(process.terminationStatus == 0, .database)
        return String(decoding: try SafeFS.readData(out), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    func sql(_ statement: String, database: String, admin: Bool = false) throws -> String {
        try sql(statement, database: database, principal: admin ? .admin : .owner)
    }
    func sql(_ statement: String, database: String, principal: DatabasePrincipal) throws -> String {
        try run("psql", connection(database, principal: principal) + ["-X", "-q", "-t", "-A", "--field-separator", "\t", "--set", "ON_ERROR_STOP=1"], input: "SET standard_conforming_strings=on; SET TIME ZONE 'UTC';\n" + (principal.isAdmin ? "SET default_transaction_read_only=off;\n" : "") + statement + "\n")
    }
    public func inspectArchive(_ file: URL) throws {
        try SafeFS.inspect(file)
        let header = try FileHandle(forReadingFrom: file); defer { try? header.close() }
        try require(try header.read(upToCount: 5) == Data("PGDMP".utf8), .integrity)
        _ = try run("pg_restore", ["--list", file.path])
    }
}

public final class StateStore {
    public let databaseName: String
    let tools: PostgreSQLTools
    let instanceRoot: URL?
    public static let migrationSQL = #"""
BEGIN;
CREATE SCHEMA macnas;
CREATE SCHEMA app_hello_diagnostics;
CREATE SCHEMA app_sample_file_index;
CREATE TABLE macnas.schema_migrations(version integer PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE macnas.labels(id text PRIMARY KEY, value text NOT NULL);
CREATE TABLE macnas.jobs(id text PRIMARY KEY, idempotency_key text UNIQUE NOT NULL,
 state text NOT NULL CHECK(state IN ('queued','running','waiting_for_volume','paused','failed','completed','cancelled')),
 effects integer NOT NULL DEFAULT 0 CHECK(effects >= 0), checkpoint jsonb NOT NULL DEFAULT '{}'::jsonb);
CREATE TABLE app_hello_diagnostics.state(id text PRIMARY KEY, value text NOT NULL);
CREATE TABLE app_sample_file_index.state(id text PRIMARY KEY, value text NOT NULL);
INSERT INTO macnas.schema_migrations(version) VALUES(1);
COMMIT;
"""#
    static let migration2SQL = #"""
BEGIN;
ALTER TABLE app_hello_diagnostics.state ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision > 0);
ALTER TABLE app_sample_file_index.state ADD COLUMN revision integer NOT NULL DEFAULT 1 CHECK(revision > 0);
INSERT INTO macnas.schema_migrations(version) VALUES(2);
COMMIT;
"""#
    static let migration3SQL = #"""
BEGIN;
ALTER TABLE macnas.jobs
 ADD COLUMN kind text NOT NULL DEFAULT 'legacy' CHECK(kind IN ('legacy','label','appValue','fixtureHash')),
 ADD COLUMN owner_user text,
 ADD COLUMN app_id text CHECK(app_id IN ('hello-diagnostics','sample-file-index')),
 ADD COLUMN payload jsonb NOT NULL DEFAULT '{}'::jsonb,
 ADD COLUMN attempts integer NOT NULL DEFAULT 0 CHECK(attempts>=0),
 ADD COLUMN max_attempts integer NOT NULL DEFAULT 3 CHECK(max_attempts BETWEEN 1 AND 8),
 ADD COLUMN next_run_at timestamptz NOT NULL DEFAULT 'epoch',
 ADD COLUMN lease_token uuid,
 ADD COLUMN lease_until timestamptz,
 ADD COLUMN revision integer NOT NULL DEFAULT 0 CHECK(revision>=0),
 ADD COLUMN last_error text,
 ADD CONSTRAINT managed_job_scope CHECK(kind='legacy' OR ((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1),
 ADD CONSTRAINT lease_pair CHECK((lease_token IS NULL)=(lease_until IS NULL));
CREATE INDEX jobs_runnable ON macnas.jobs(next_run_at,id) WHERE kind<>'legacy' AND state IN ('queued','waiting_for_volume','running');
CREATE TABLE macnas.job_steps(
 job_id text NOT NULL REFERENCES macnas.jobs(id), step integer NOT NULL CHECK(step IN (0,1)),
 result jsonb NOT NULL, PRIMARY KEY(job_id,step));
CREATE TABLE macnas.event_clock(singleton boolean PRIMARY KEY DEFAULT true CHECK(singleton),next_sequence bigint NOT NULL CHECK(next_sequence>0));
INSERT INTO macnas.event_clock VALUES(true,1);
CREATE TABLE macnas.job_events(
 sequence bigint PRIMARY KEY CHECK(sequence>0), job_id text NOT NULL REFERENCES macnas.jobs(id),
 revision integer NOT NULL, owner_user text, app_id text, type text NOT NULL, state text NOT NULL,
 UNIQUE(job_id,revision), CHECK(((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1));
CREATE TABLE macnas.event_consumers(
 id text PRIMARY KEY, owner_user text, app_id text,
 ack_sequence bigint NOT NULL DEFAULT 0 CHECK(ack_sequence>=0),
 delivered_sequence bigint NOT NULL DEFAULT 0 CHECK(delivered_sequence>=ack_sequence),
 CHECK(((owner_user IS NOT NULL)::int+(app_id IS NOT NULL)::int)=1));
CREATE TABLE macnas.event_receipts(
 consumer_id text NOT NULL REFERENCES macnas.event_consumers(id), sequence bigint NOT NULL REFERENCES macnas.job_events(sequence),
 PRIMARY KEY(consumer_id,sequence));
INSERT INTO macnas.schema_migrations(version) VALUES(3);
COMMIT;
"""#
    public init(databaseName: String, instanceRoot: URL? = nil) throws {
        try PostgreSQLTools.fixtureName(databaseName)
        self.tools = try PostgreSQLTools(); self.databaseName = databaseName; self.instanceRoot = instanceRoot
    }
    static func plannedName(_ id: UUID) -> String { "macnas_fixture_" + id.uuidString.replacingOccurrences(of: "-", with: "").lowercased() }
    static func quote(_ value: String) throws -> String {
        try require(!value.contains("\0") && !value.contains("\n") && !value.contains("\r") && value.utf8.count <= 4096, .invalidSchema)
        return "'" + value.replacingOccurrences(of: "'", with: "''") + "'"
    }
    func exists() throws -> Bool {
        try tools.sql("SELECT count(*) FROM pg_database WHERE datname=\(Self.quote(databaseName));", database: "postgres", admin: true) == "1"
    }
    func ownerName() throws -> String {
        try tools.sql("SELECT pg_get_userbyid(datdba) FROM pg_database WHERE datname=\(Self.quote(databaseName));",database:"postgres",admin:true)
    }
    func attestation() throws -> String {
        try tools.sql("SELECT coalesce(shobj_description(oid,'pg_database'),'') FROM pg_database WHERE datname=\(Self.quote(databaseName)) AND pg_get_userbyid(datdba)='macnas_test_owner';", database: "postgres", admin: true)
    }
    static func createEmpty(name: String, attestation: String) throws -> StateStore {
        let store = try StateStore(databaseName: name)
        if try store.exists() { try require(try store.attestation() == attestation, .collision); return store }
        _ = try store.tools.run("createdb", ["--host", store.tools.socket.path, "--port", "55432", "--username", "macnas_test_admin", "--no-password", "--owner", "macnas_test_owner", "--template", "template0", name])
        _ = try store.tools.sql("COMMENT ON DATABASE \(name) IS \(quote(attestation)); REVOKE ALL ON DATABASE \(name) FROM PUBLIC; GRANT CONNECT ON DATABASE \(name) TO macnas_test_owner;", database: "postgres", admin: true)
        return store
    }
    public static func createSynthetic(schemaVersion:Int=1) throws -> StateStore {
        try require([1,2,3,4].contains(schemaVersion),.invalidSchema)
        let store = try createEmpty(name: plannedName(UUID()), attestation: "macnas-synthetic-development")
        try store.execute(migrationSQL); if schemaVersion>1 { try store.migrate(toVersion:schemaVersion) }; try store.installAppRoles()
        return store
    }
    func tableCount() throws -> Int {
        let result = try tools.sql("SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('macnas','app_hello_diagnostics','app_sample_file_index') AND table_type='BASE TABLE';", database: databaseName)
        guard let count = Int(result) else { throw NASError.invalidSchema }; return count
    }
    func importArchive(_ archive: URL) throws {
        try require(try tableCount() == 0, .collision)
        try tools.inspectArchive(archive)
        _ = try tools.run("pg_restore", tools.connection(databaseName) + ["--no-owner", "--no-privileges", "--no-tablespaces", "--exit-on-error", "--single-transaction", archive.path])
        try hardenImportedSchema4FunctionPrivileges()
        try validate()
    }
    /// pg_restore --no-privileges recreates functions with PUBLIC EXECUTE. Tighten only those
    /// fixed signatures before validating an isolated import, including import-COMMIT recovery.
    /// Never call this from ordinary validation or after the migration's imported phase.
    func hardenImportedSchema4FunctionPrivileges() throws {
        guard try schemaVersion() >= 4 else { return }
        let statements=Self.schema4Functions.map { name,arguments,_ in
            "REVOKE EXECUTE ON FUNCTION macnas.\(name)(\(arguments)) FROM PUBLIC;"
        }.joined(separator:"\n")
        try execute("BEGIN; SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms';\n"+statements+"\nCOMMIT;")
    }
    static func restoreSynthetic(archive: URL) throws -> StateStore {
        let store = try createEmpty(name: plannedName(UUID()), attestation: "macnas-synthetic-restore")
        try store.importArchive(archive); try store.installAppRoles(); try store.setDefaultReadOnly()
        return store
    }
    func installAppRoles() throws {
        for app in SampleApp.allCases {
            let role = app.role(database: databaseName)
            _ = try tools.sql("DO $$ BEGIN IF NOT EXISTS(SELECT 1 FROM pg_roles WHERE rolname=\(Self.quote(role))) THEN CREATE ROLE \(role) LOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOREPLICATION; END IF; END $$; GRANT CONNECT ON DATABASE \(databaseName) TO \(role);", database: "postgres", admin: true)
            _ = try tools.sql("REVOKE ALL ON SCHEMA public FROM PUBLIC; REVOKE ALL ON SCHEMA macnas,app_hello_diagnostics,app_sample_file_index FROM PUBLIC; GRANT USAGE ON SCHEMA \(app.schema) TO \(role); GRANT SELECT,INSERT,UPDATE,DELETE ON ALL TABLES IN SCHEMA \(app.schema) TO \(role);", database: databaseName, admin: true)
        }
    }
    func setDefaultReadOnly() throws {
        _ = try tools.sql("ALTER DATABASE \(databaseName) SET default_transaction_read_only=on;", database: "postgres", admin: true)
    }
    func withMutation<T>(_ body: () throws -> T) throws -> T {
        let lock = try instanceRoot.map { try InstanceLock($0, mode: .shared, timeout: 10) }
        return try withExtendedLifetime(lock, body)
    }
    func execute(_ sql: String) throws { _ = try tools.sql(sql, database: databaseName) }
    public func label(_ id: String, _ value: String) throws {
        try withMutation { try execute("INSERT INTO macnas.labels VALUES(\(Self.quote(id)),\(Self.quote(value))) ON CONFLICT(id) DO UPDATE SET value=excluded.value;") }
    }
    public func enqueue(_ id: String, key: String) throws {
        try withMutation { try execute("INSERT INTO macnas.jobs(id,idempotency_key,state) VALUES(\(Self.quote(id)),\(Self.quote(key)),'queued') ON CONFLICT DO NOTHING;") }
    }
    public func complete(_ id: String) throws {
        try withMutation { try execute("UPDATE macnas.jobs SET effects=effects+1,state='completed' WHERE id=\(Self.quote(id)) AND state!='completed'"+(try schemaVersion()>=3 ? " AND kind='legacy'" : "")+";") }
    }
    public func rows(_ sql: String) throws -> [[String]] {
        let output = try tools.sql(sql, database: databaseName)
        return output.isEmpty ? [] : output.split(separator: "\n").map { $0.split(separator: "\t", omittingEmptySubsequences: false).map(String.init) }
    }
    public func schemaVersion() throws -> Int {
        let versions = try rows("SELECT version FROM macnas.schema_migrations ORDER BY version;")
        if versions == [["1"]] { return 1 }; if versions == [["1"],["2"]] { return 2 }; if versions == [["1"],["2"],["3"]] { return 3 }; if versions == [["1"],["2"],["3"],["4"]] { return 4 }; throw NASError.invalidSchema
    }
    public func validate(expectedVersion: Int? = nil) throws {
        let version = try schemaVersion()
        if let expectedVersion { try require(version == expectedVersion, .invalidSchema) }
        var expectedTables = [["app_hello_diagnostics","state"],["app_sample_file_index","state"],["macnas","jobs"],["macnas","labels"],["macnas","schema_migrations"]]
        if version>=3 {
            expectedTables += ["event_clock","event_consumers","event_receipts","job_events","job_steps"].map { ["macnas",$0] }
        }
        if version>=4 { expectedTables += ["file_effect_operations","recycle_entries"].map { ["macnas",$0] } }
        expectedTables.sort { $0.joined(separator:".") < $1.joined(separator:".") }
        try require(try rows("SELECT table_schema,table_name FROM information_schema.tables WHERE table_schema IN ('macnas','app_hello_diagnostics','app_sample_file_index') AND table_type='BASE TABLE' ORDER BY table_schema,table_name;") == expectedTables, .invalidSchema)
        try require(try rows("SELECT current_setting('server_version_num')::int / 10000;") == [["18"]], .unsupported)
        _ = try rows("SELECT id,value FROM macnas.labels LIMIT 1;")
        _ = try rows("SELECT id,idempotency_key,state,effects,checkpoint FROM macnas.jobs LIMIT 1;")
        if version>=3 {
            _=try rows("SELECT kind,owner_user,app_id,payload,attempts,max_attempts,next_run_at,lease_token,lease_until,revision,last_error FROM macnas.jobs LIMIT 1;")
            _=try rows("SELECT job_id,step,result FROM macnas.job_steps LIMIT 1;")
            _=try rows("SELECT sequence,job_id,revision,owner_user,app_id,type,state FROM macnas.job_events LIMIT 1;")
            _=try rows("SELECT id,owner_user,app_id,ack_sequence,delivered_sequence FROM macnas.event_consumers LIMIT 1;")
            _=try rows("SELECT consumer_id,sequence FROM macnas.event_receipts LIMIT 1;")
            try require(try rows("SELECT count(*) FROM macnas.event_clock WHERE singleton AND next_sequence>(SELECT coalesce(max(sequence),0) FROM macnas.job_events);")==[["1"]],.invalidSchema)
        }
        for app in SampleApp.allCases {
            let columns = try rows("SELECT column_name FROM information_schema.columns WHERE table_schema='\(app.schema)' AND table_name='state' ORDER BY ordinal_position;")
            try require(columns == (version == 1 ? [["id"],["value"]] : [["id"],["value"],["revision"]]), .invalidSchema)
        }
        if version >= 4 { try validateSchema4() }
    }
    @discardableResult func migrateToVersion2(injectFailure: Bool = false) throws -> Bool {
        try validate(); let version=try schemaVersion(); if version == 2 { return false }; try require(version == 1,.unsupported)
        let sql = injectFailure ? Self.migration2SQL.replacingOccurrences(of: "COMMIT;", with: "SELECT 1/0; COMMIT;") : Self.migration2SQL
        try execute(sql); try validate(expectedVersion: 2); return true
    }
    @discardableResult func migrate(toVersion target:Int,injectFailure:Bool=false) throws -> Bool {
        try require([1,2,3,4].contains(target),.unsupported);try validate()
        let source=try schemaVersion();try require(target>=source,.unsupported)
        if source<2 && target>=2 { try migrateToVersion2(injectFailure:injectFailure) }
        if try schemaVersion()<3 && target>=3 {
            let sql=injectFailure ? Self.migration3SQL.replacingOccurrences(of:"COMMIT;",with:"SELECT 1/0; COMMIT;") : Self.migration3SQL
            try execute(sql)
        }
        if try schemaVersion()<4 && target>=4 {
            let sql=injectFailure ? Self.migration4SQL.replacingOccurrences(of:"COMMIT;",with:"SELECT 1/0; COMMIT;") : Self.migration4SQL
            try execute(sql)
        }
        try validate(expectedVersion:target);return source != target
    }
    func validateUpgradeDefaults(from source:Int) throws {
        if source==1 {
            for app in SampleApp.allCases { try require(try rows("SELECT count(*) FROM \(app.schema).state WHERE revision<>1;")==[["0"]],.integrity) }
        }
        if try source<3 && schemaVersion()>=3 {
            try require(try rows("SELECT count(*) FROM macnas.jobs WHERE kind<>'legacy' OR owner_user IS NOT NULL OR app_id IS NOT NULL OR payload<>'{}'::jsonb OR attempts<>0 OR max_attempts<>3 OR next_run_at<>'epoch'::timestamptz OR lease_token IS NOT NULL OR lease_until IS NOT NULL OR revision<>0 OR last_error IS NOT NULL;")==[["0"]],.integrity)
            for table in ["job_steps","job_events","event_consumers","event_receipts"] { try require(try rows("SELECT count(*) FROM macnas.\(table);")==[["0"]],.integrity) }
            try require(try rows("SELECT next_sequence FROM macnas.event_clock WHERE singleton;")==[["1"]],.integrity)
        }
        if try source<4 && schemaVersion()>=4 { try requirePortableRecycleEmpty() }
    }
    func baseDataDigest() throws -> String { try dataDigest(includeSchema:false,asVersion:nil) }
    func contentDigest(asVersion:Int?=nil) throws -> String { try dataDigest(includeSchema:true,asVersion:asVersion) }
    /// Only the DB half of the ordinary portable gate; the caller must separately verify every approved vault.
    func hasRecycleHistory() throws -> Bool {
        guard try schemaVersion() >= 4 else { return false }
        return try rows("SELECT EXISTS(SELECT 1 FROM macnas.recycle_entries) OR EXISTS(SELECT 1 FROM macnas.file_effect_operations);") != [["f"]]
    }
    func requirePortableRecycleEmpty() throws { try require(try !hasRecycleHistory(), .unsupported) }
    private static func definition(_ value: String) -> String {
        // The two CHECKs contain one closed, exactly verified function call. Parentheses/row casts
        // are deparser spelling only; no boolean expression is discarded or rewritten here.
        value.replacingOccurrences(of:"::macnas.recycle_entries",with:"")
            .replacingOccurrences(of:"::macnas.file_effect_operations",with:"")
            .filter{!$0.isWhitespace && $0 != "(" && $0 != ")"}
    }
    private func validateSchema4() throws {
        for table in ["recycle_entries","file_effect_operations"] {
            let columns = try rows("SELECT a.attname,format_type(a.atttypid,a.atttypmod),CASE WHEN a.attnotnull THEN 'NO' ELSE 'YES' END FROM pg_attribute a JOIN pg_class c ON c.oid=a.attrelid JOIN pg_namespace n ON n.oid=c.relnamespace WHERE n.nspname='macnas' AND c.relname='\(table)' AND a.attnum>0 AND NOT a.attisdropped ORDER BY a.attnum;")
            try require(columns == Self.schema4Columns[table], .invalidSchema)
            try require(try rows("SELECT relkind,relispartition,relrowsecurity,relforcerowsecurity FROM pg_class WHERE oid='macnas.\(table)'::regclass;") == [["r","f","f","f"]], .invalidSchema)
            try require(try rows("SELECT count(*) FROM pg_attribute a WHERE a.attrelid='macnas.\(table)'::regclass AND a.attnum>0 AND (a.attisdropped OR a.atthasdef OR a.attidentity<>'' OR a.attgenerated<>'');") == [["0"]], .invalidSchema)
        }
        let constraints=try rows("SELECT c.relname||'.'||p.conname,pg_get_constraintdef(p.oid),p.convalidated,p.conislocal FROM pg_constraint p JOIN pg_class c ON c.oid=p.conrelid WHERE p.conrelid IN ('macnas.recycle_entries'::regclass,'macnas.file_effect_operations'::regclass) AND p.contype IN ('c','p','u','f','x') ORDER BY 1;")
        try require(constraints.count == Self.schema4Constraints.count, .invalidSchema)
        for row in constraints {
            guard row.count==4, let expected=Self.schema4Constraints[row[0]] else { throw NASError.invalidSchema }
            try require(row[2]=="t" && row[3]=="t" && Self.definition(row[1])==Self.definition(expected), .invalidSchema)
        }
        let functions=try rows("SELECT p.proname,oidvectortypes(p.proargtypes),encode(convert_to(p.prosrc,'UTF8'),'hex'),l.lanname,p.provolatile,p.proisstrict,p.prosecdef,p.proleakproof,p.prokind,format_type(p.prorettype,NULL),array_to_string(p.proconfig,'|'),EXISTS(SELECT 1 FROM aclexplode(coalesce(p.proacl,acldefault('f',p.proowner))) acl WHERE acl.grantee=0 AND acl.privilege_type='EXECUTE') FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace JOIN pg_language l ON l.oid=p.prolang WHERE n.nspname='macnas' ORDER BY p.proname;")
        try require(functions.count == Self.schema4Functions.count, .invalidSchema)
        for row in functions {
            guard row.count==12,let expected=Self.schema4Functions.first(where:{$0.0==row[0]}) else { throw NASError.invalidSchema }
            let hex=Data(("\n"+expected.2+"\n").utf8).map{String(format:"%02x",$0)}.joined()
            try require(row[1]==expected.1 && row[2]==hex && Array(row[3...]) == ["sql","i","t","f","f","f","boolean","search_path=pg_catalog|TimeZone=UTC","f"], .invalidSchema)
        }
        // Restoring a CHECK function does not recheck rows written while its body was different.
        // Recheck current data only after every called function has passed its exact fingerprint.
        try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM macnas.recycle_entries e WHERE macnas.valid_recycle_entry(e) IS NOT TRUE) AND NOT EXISTS(SELECT 1 FROM macnas.file_effect_operations o WHERE macnas.valid_file_effect_operation(o) IS NOT TRUE);")==[["t"]], .invalidSchema)
        let indexes=try rows("SELECT i.relname,pg_get_indexdef(i.oid),x.indisvalid,x.indisready FROM pg_index x JOIN pg_class i ON i.oid=x.indexrelid WHERE x.indrelid IN ('macnas.recycle_entries'::regclass,'macnas.file_effect_operations'::regclass) ORDER BY i.relname;")
        let automatic=Set(["recycle_entries_pkey","recycle_entries_payload_unique","file_effect_operations_pkey","file_effect_operations_entry_operation_unique","file_effect_operations_idempotency_unique"])
        try require(indexes.count==automatic.count+Self.schema4Indexes.count, .invalidSchema)
        for row in indexes {
            try require(row.count==4 && row[2]=="t" && row[3]=="t", .invalidSchema)
            if let expected=Self.schema4Indexes[row[0]] { try require(Self.definition(row[1])==Self.definition(expected), .invalidSchema) }
            else { try require(automatic.contains(row[0]), .invalidSchema) }
        }
        try require(try rows("SELECT count(*) FROM pg_trigger WHERE tgrelid IN ('macnas.recycle_entries'::regclass,'macnas.file_effect_operations'::regclass) AND NOT tgisinternal;")==[["0"]], .invalidSchema)
        try require(try rows("SELECT count(*) FROM macnas.file_effect_operations o JOIN macnas.recycle_entries e ON e.entry_id=o.entry_id WHERE o.instance_id<>e.instance_id OR o.origin_generation<>e.origin_generation OR o.actor_user_utf8<>e.owner_user_utf8 OR convert_to(o.intent->>'libraryID','UTF8')<>e.library_id_utf8 OR convert_to(o.intent->>'sourcePath','UTF8')<>e.original_path_utf8 OR o.pre_evidence->>'sha256'<>e.sha256 OR (o.pre_evidence->'object'->>'bytes')::bigint<>e.byte_count OR o.pre_evidence->'object'->>'device'<>o.pre_evidence->'sourceParent'->>'device' OR o.pre_evidence->'object'->>'device'<>o.pre_evidence->'targetParent'->>'device' OR (o.phase IN ('prepared','armed','observed','uncertain') AND (e.active_operation_id IS DISTINCT FROM o.operation_id OR e.charge_state<>CASE WHEN o.kind='recycle' THEN 'reserved' ELSE 'retained' END)) OR (o.phase IN ('completed','cancelled') AND e.active_operation_id=o.operation_id) OR (o.post_evidence IS NOT NULL AND (o.post_evidence->>'sha256'<>e.sha256 OR ((o.post_evidence->'object') - ARRAY['ctimeSeconds','ctimeNanos'])<>((o.pre_evidence->'object') - ARRAY['ctimeSeconds','ctimeNanos']) OR o.post_evidence->'sourceParent'->>'device'<>o.pre_evidence->'sourceParent'->>'device' OR o.post_evidence->'sourceParent'->>'inode'<>o.pre_evidence->'sourceParent'->>'inode' OR o.post_evidence->'targetParent'->>'device'<>o.pre_evidence->'targetParent'->>'device' OR o.post_evidence->'targetParent'->>'inode'<>o.pre_evidence->'targetParent'->>'inode'));")==[["0"]], .invalidSchema)
        try require(try rows("SELECT count(*) FROM macnas.recycle_entries e WHERE (e.charge_state='reserved' AND NOT EXISTS(SELECT 1 FROM macnas.file_effect_operations o WHERE o.entry_id=e.entry_id AND o.operation_id=e.active_operation_id AND o.kind='recycle' AND o.phase IN ('prepared','armed','observed','uncertain'))) OR (e.charge_state='retained' AND NOT EXISTS(SELECT 1 FROM macnas.file_effect_operations o WHERE o.entry_id=e.entry_id AND o.kind='recycle' AND o.phase='completed')) OR (e.charge_state='released' AND NOT EXISTS(SELECT 1 FROM macnas.file_effect_operations o WHERE o.entry_id=e.entry_id AND ((o.kind='recycle' AND o.phase='cancelled') OR (o.kind='restore' AND o.phase='completed'))));")==[["0"]], .invalidSchema)
        try require(try rows("SELECT (SELECT count(*) FROM macnas.recycle_entries)<=64 AND (SELECT count(*) FROM macnas.file_effect_operations)<=256 AND (SELECT count(*) FROM macnas.file_effect_operations WHERE phase IN ('prepared','armed','observed','uncertain'))<=8 AND (SELECT coalesce(sum(byte_count),0) FROM macnas.recycle_entries WHERE charge_state IN ('reserved','retained'))<=67108864;")==[["t"]], .invalidSchema)
        for app in SampleApp.allCases {
            let role=app.role(database:databaseName)
            try require(try rows("SELECT NOT EXISTS(SELECT 1 FROM pg_roles r WHERE r.rolname=\(Self.quote(role)) AND (has_schema_privilege(r.oid,'macnas','USAGE,CREATE') OR has_table_privilege(r.oid,'macnas.recycle_entries','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN') OR has_table_privilege(r.oid,'macnas.file_effect_operations','SELECT,INSERT,UPDATE,DELETE,TRUNCATE,REFERENCES,TRIGGER,MAINTAIN') OR EXISTS(SELECT 1 FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace WHERE n.nspname='macnas' AND has_function_privilege(r.oid,p.oid,'EXECUTE'))));")==[["t"]], .denied)
        }
    }
    private static func digestTables(includeSchema: Bool, version: Int) -> [(String,String,String)] {
        let app=includeSchema && version>=2 ? "id,value,revision":"id,value"
        let jobs=includeSchema && version>=3 ? "id,idempotency_key,state,effects,checkpoint,kind,owner_user,app_id,payload,attempts,max_attempts,next_run_at,lease_token,lease_until,revision,last_error":"id,idempotency_key,state,effects,checkpoint"
        var tables=[("labels","macnas.labels","id,value"),("jobs","macnas.jobs",jobs),("diagnostics","app_hello_diagnostics.state",app),("fileIndex","app_sample_file_index.state",app)]
        if includeSchema && version>=3 {
            tables += [("job_steps","macnas.job_steps","job_id,step,result"),("job_events","macnas.job_events","sequence,job_id,revision,owner_user,app_id,type,state"),("event_clock","macnas.event_clock","singleton,next_sequence"),("event_consumers","macnas.event_consumers","id,owner_user,app_id,ack_sequence,delivered_sequence"),("event_receipts","macnas.event_receipts","consumer_id,sequence")]
        }
        if includeSchema && version>=4 {
            for table in ["recycle_entries","file_effect_operations"] { tables.append((table,"macnas."+table,Self.schema4Columns[table]!.map{$0[0]}.joined(separator:","))) }
        }
        return tables
    }
    private static func digestOrder(_ table: String) -> String {
        switch table { case "job_steps":return "job_id,step";case "job_events":return "sequence";case "event_clock":return "singleton";case "event_receipts":return "consumer_id,sequence";case "recycle_entries":return "entry_id";case "file_effect_operations":return "operation_id";default:return "id" }
    }
    private static func canonicalDataExpression(includeSchema: Bool, version: Int) -> String {
        let fields=digestTables(includeSchema:includeSchema,version:version).map{key,table,columns in
            "'\(key)',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY \(digestOrder(key))),'[]'::jsonb) FROM (SELECT \(columns) FROM \(table)) t)"
        }
        return "jsonb_build_object('schema',\(includeSchema ? version:0),"+fields.joined(separator:",")+")"
    }
    /// Exact serialized size without building any jsonb_agg array. The caller must set UTC and a statement timeout.
    private static func metadataBytesExpression(includeSchema: Bool, version: Int) -> String {
        let tables=digestTables(includeSchema:includeSchema,version:version)
        let header="octet_length(jsonb_build_object('schema',\(includeSchema ? version:0),"+tables.map{"'\($0.0)','[]'::jsonb"}.joined(separator:",")+")::text)"
        return header+tables.map{_,table,columns in
            "+(SELECT coalesce(sum(octet_length(to_jsonb(t)::text)+2),0)-CASE WHEN count(*)>0 THEN 2 ELSE 0 END FROM (SELECT \(columns) FROM \(table)) t)"
        }.joined()
    }
    static var legacyMetadataBytesSQL: String { "SELECT "+metadataBytesExpression(includeSchema:true,version:3) }
    private func dataDigest(includeSchema:Bool,asVersion:Int?) throws -> String {
        let current=try schemaVersion(),version=asVersion ?? current
        try require(version<=current && [1,2,3,4].contains(version),.invalidSchema)
        let expression=Self.canonicalDataExpression(includeSchema:includeSchema,version:version)
        let actualBytes=Self.metadataBytesExpression(includeSchema:includeSchema,version:version)
        let bytes: String
        if includeSchema && version>=4 {
            let reservedBytes="(\(Self.legacyMetadataBytesSQL))+(SELECT count(*)*4096 FROM macnas.recycle_entries)+(SELECT count(*)*8192 FROM macnas.file_effect_operations)+4096"
            // A digest may be requested without validation; never trust historical row CHECKs
            // to imply current row sizes, while retaining room for each row's worst final form.
            bytes="GREATEST((\(actualBytes)),(\(reservedBytes)))"
        } else { bytes=actualBytes }
        // CASE avoids constructing any aggregate arrays after either size precheck fails.
        // One repeatable-read snapshot prevents a concurrent writer invalidating that precheck.
        let sql="BEGIN ISOLATION LEVEL REPEATABLE READ READ ONLY; SET LOCAL statement_timeout='10000ms'; SELECT CASE WHEN (\(bytes))>4000000 THEN 'BUDGET' ELSE encode(sha256(convert_to(btrim((\(expression))::text,E' \\t\\n\\r'),'UTF8')),'hex') END; COMMIT;"
        let digest=try tools.sql(sql,database:databaseName)
        try require(digest != "BUDGET", .budgetExceeded); try TransferEncoding.hash(digest); return digest
    }
    public func snapshot(to url: URL, cancellation: CancellationToken? = nil) throws {
        try SafeFS.inspect(url); try require(!FileManager.default.fileExists(atPath: url.path), .collision)
        _ = try tools.run("pg_dump", tools.connection(databaseName) + ["--format=custom", "--compress=none", "--no-owner", "--no-privileges", "--no-tablespaces", "--schema=macnas", "--schema=app_hello_diagnostics", "--schema=app_sample_file_index", "--file", url.path], cancellation: cancellation)
        try tools.inspectArchive(url)
    }
}
