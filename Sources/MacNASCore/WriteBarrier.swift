import Foundation
import Darwin

public final class CancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var cancelled = false
    public init() {}
    public func cancel() { lock.lock(); cancelled = true; lock.unlock() }
    public var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return cancelled }
    func check() throws { try require(!isCancelled, .cancelled) }
}

enum ChildControl {
    static func stop(_ process: Process) {
        guard process.isRunning else { process.waitUntilExit(); return }
        process.terminate()
        let deadline = ProcessInfo.processInfo.systemUptime + 0.3
        while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline { Thread.sleep(forTimeInterval: 0.01) }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
        process.waitUntilExit()
    }
}

/// Holds SHARE locks in one live PostgreSQL transaction; readers/pg_dump continue, writers drain or wait.
/// The enclosing instance's exclusive file lock coordinates its mutable configuration files.
public final class DatabaseSnapshotBarrier {
    private let process = Process()
    private let application = "macnas-freeze-" + UUID().uuidString.lowercased()
    private var tools: PostgreSQLTools?
    private var databaseName: String?
    private var closed = false
    private let pipe = Pipe()
    private var outputHandle: FileHandle?
    private var inputHandle: FileHandle?
    private var outputURL: URL?
    public init(store: StateStore, timeout: TimeInterval = 10, cancellation: CancellationToken? = nil) throws {
        tools=store.tools;databaseName=store.databaseName
        try require(timeout > 0 && timeout <= 60, .invalidSchema)
        try cancellation?.check()
        let output = store.tools.scratch.appendingPathComponent("snapshot-barrier-\(UUID().uuidString).log")
        outputURL = output
        FileManager.default.createFile(atPath: output.path, contents: nil)
        outputHandle = try FileHandle(forWritingTo: output)
        inputHandle = pipe.fileHandleForWriting
        process.executableURL = try SafeFS.resolve(store.tools.bin, "psql")
        process.arguments = try store.tools.connection(store.databaseName) + ["-X", "-q", "-t", "-A", "--set", "ON_ERROR_STOP=1"]
        process.environment = store.tools.environment(application: application)
        process.standardInput = pipe; process.standardOutput = outputHandle; process.standardError = outputHandle
        do {
            try process.run()
            let marker = "MACNAS_BARRIER_READY_" + UUID().uuidString.replacingOccurrences(of: "-", with: "")
            let tables = ["macnas.schema_migrations","macnas.labels","macnas.jobs","app_hello_diagnostics.state","app_sample_file_index.state"] + ((try store.schemaVersion())>=3 ? ["macnas.job_steps","macnas.event_clock","macnas.job_events","macnas.event_consumers","macnas.event_receipts"] : [])
            let sql = "BEGIN READ WRITE; SET LOCAL lock_timeout='\(Int(timeout * 1000))ms'; SET LOCAL idle_in_transaction_session_timeout='60000ms'; LOCK TABLE \(tables.joined(separator:", ")) IN SHARE MODE;\n\\echo \(marker)\n"
            try inputHandle?.write(contentsOf: Data(sql.utf8))
            let deadline = ProcessInfo.processInfo.systemUptime + timeout + 0.1
            while true {
                try cancellation?.check()
                let data = try SafeFS.readData(output, maximumBytes: 65536)
                if String(decoding: data, as: UTF8.self).contains(marker) { break }
                try require(process.isRunning, .timedOut)
                try require(ProcessInfo.processInfo.systemUptime < deadline, .timedOut)
                Thread.sleep(forTimeInterval: 0.01)
            }
        } catch { close(); throw error }
    }
    public func check() throws { try require(process.isRunning, .staleState) }
    private func close() {
        guard !closed else { return };closed=true
        if process.isRunning, let tools, let databaseName {
            _ = try? tools.sql("SELECT pg_cancel_backend(pid) FROM pg_stat_activity WHERE application_name='\(application)' AND datname='\(databaseName)' AND usename='macnas_test_owner';",database:databaseName)
        }
        if process.isRunning { try? inputHandle?.write(contentsOf: Data("ROLLBACK;\n\\q\n".utf8)) }
        try? inputHandle?.close(); inputHandle = nil
        if process.processIdentifier > 0 { ChildControl.stop(process) }
        try? outputHandle?.close(); outputHandle = nil
        if let outputURL { try? FileManager.default.removeItem(at: outputURL) }
    }
    deinit { close() }
}
