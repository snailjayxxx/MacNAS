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
        try require([1,2,3].contains(schemaVersion),.invalidSchema)
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
        try validate()
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
        if versions == [["1"]] { return 1 }; if versions == [["1"],["2"]] { return 2 }; if versions == [["1"],["2"],["3"]] { return 3 }; throw NASError.invalidSchema
    }
    public func validate(expectedVersion: Int? = nil) throws {
        let version = try schemaVersion()
        if let expectedVersion { try require(version == expectedVersion, .invalidSchema) }
        var expectedTables = [["app_hello_diagnostics","state"],["app_sample_file_index","state"],["macnas","jobs"],["macnas","labels"],["macnas","schema_migrations"]]
        if version>=3 {
            expectedTables += ["event_clock","event_consumers","event_receipts","job_events","job_steps"].map { ["macnas",$0] }
            expectedTables.sort { $0.joined(separator:".") < $1.joined(separator:".") }
        }
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
    }
    @discardableResult func migrateToVersion2(injectFailure: Bool = false) throws -> Bool {
        try validate(); let version=try schemaVersion(); if version == 2 { return false }; try require(version == 1,.unsupported)
        let sql = injectFailure ? Self.migration2SQL.replacingOccurrences(of: "COMMIT;", with: "SELECT 1/0; COMMIT;") : Self.migration2SQL
        try execute(sql); try validate(expectedVersion: 2); return true
    }
    @discardableResult func migrate(toVersion target:Int,injectFailure:Bool=false) throws -> Bool {
        try require([1,2,3].contains(target),.unsupported);try validate()
        let source=try schemaVersion();try require(target>=source,.unsupported)
        if source<2 && target>=2 { try migrateToVersion2(injectFailure:injectFailure) }
        if try schemaVersion()<3 && target>=3 {
            let sql=injectFailure ? Self.migration3SQL.replacingOccurrences(of:"COMMIT;",with:"SELECT 1/0; COMMIT;") : Self.migration3SQL
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
    }
    func baseDataDigest() throws -> String { try dataDigest(includeSchema:false,asVersion:nil) }
    func contentDigest(asVersion:Int?=nil) throws -> String { try dataDigest(includeSchema:true,asVersion:asVersion) }
    private func dataDigest(includeSchema:Bool,asVersion:Int?) throws -> String {
        let current=try schemaVersion(),version=asVersion ?? current
        try require(version<=current && [1,2,3].contains(version),.invalidSchema)
        let appColumns=includeSchema && version>=2 ? "id,value,revision" : "id,value"
        let jobColumns=includeSchema && version>=3 ? "*" : "id,idempotency_key,state,effects,checkpoint"
        var extra=""
        if includeSchema && version>=3 {
            for (table,order) in [("job_steps","job_id,step"),("job_events","sequence"),("event_clock","singleton"),("event_consumers","id"),("event_receipts","consumer_id,sequence")] {
                extra += ",'\(table)',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY \(order)),'[]') FROM macnas.\(table) t)"
            }
        }
        let sql="SELECT jsonb_build_object('schema',\(includeSchema ? version : 0),'labels',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT id,value FROM macnas.labels) t),'jobs',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(jobColumns) FROM macnas.jobs) t),'diagnostics',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(appColumns) FROM app_hello_diagnostics.state) t),'fileIndex',(SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id),'[]') FROM (SELECT \(appColumns) FROM app_sample_file_index.state) t)\(extra))::text;"
        return SHA256.hash(data:Data(try tools.sql(sql,database:databaseName).utf8)).map { String(format:"%02x",$0) }.joined()
    }
    public func snapshot(to url: URL, cancellation: CancellationToken? = nil) throws {
        try SafeFS.inspect(url); try require(!FileManager.default.fileExists(atPath: url.path), .collision)
        _ = try tools.run("pg_dump", tools.connection(databaseName) + ["--format=custom", "--compress=none", "--no-owner", "--no-privileges", "--no-tablespaces", "--schema=macnas", "--schema=app_hello_diagnostics", "--schema=app_sample_file_index", "--file", url.path], cancellation: cancellation)
        try tools.inspectArchive(url)
    }
}
