import Foundation
import CryptoKit
import Darwin

private enum BridgeFault: String, Error { case invalidResponse, readOnly, unavailable }
private struct BridgeSuccess<T: Encodable>: Encodable {
    let apiVersion = 1
    let requestId: String
    let data: T
}
struct BridgeLimits {
    let requests: Int
    let responseBytes: Int
    init(requests: Int = 4096, responseBytes: Int = 1_048_576) { self.requests = requests; self.responseBytes = responseBytes }
}
private extension Dictionary where Key == String, Value == BridgeJSON {
    func text(_ key: String, maximum: Int = 128, fallback: String? = nil, allowEmpty: Bool = false) throws -> String {
        if let value = self[key] { return try value.text(maximumBytes: maximum, allowEmpty: allowEmpty) }
        guard let fallback else { throw NASError.invalidSchema }
        return fallback
    }
    func integer(_ key: String, range: ClosedRange<Int64>, fallback: Int64? = nil) throws -> Int64 {
        if let value = self[key] { return try value.integer(in: range) }
        guard let fallback else { throw NASError.invalidSchema }
        return fallback
    }
}
private struct DesktopJob: Encodable {
    let id: String
    let idempotency_key: String
    let kind: String
    let owner_user: String?
    let app_id: String?
    let title: String?
    let titleKey: String
    let state: String
    let attempts: Int
    let max_attempts: Int
    let effects: Int
    let revision: Int
    let checkpoint: [String: String]
    let last_error: String?
    init(_ job: DurableJob) throws {
        let states: Set<String> = ["queued","running","waiting_for_volume","paused","failed","completed","cancelled"]
        guard states.contains(job.state), [job.attempts,job.max_attempts,job.effects,job.revision].allSatisfy({ $0 >= 0 && $0 <= 9_007_199_254_740_991 }) else {
            throw BridgeFault.invalidResponse
        }
        id = job.id; idempotency_key = job.idempotency_key; kind = job.kind.rawValue
        owner_user = job.owner_user; app_id = job.app_id
        title = job.kind == .label ? job.payload.value : nil
        titleKey = job.kind == .fixtureHash ? "jobHash" : "jobLabels"
        state = job.state; attempts = job.attempts; max_attempts = job.max_attempts
        effects = job.effects; revision = job.revision
        checkpoint = job.checkpoint.filter { ["step","sha256","bytes"].contains($0.key) }
        last_error = job.last_error.map { NASError(rawValue: $0) == nil ? "unavailable" : $0 }
    }
}
private struct DesktopOverview: Encodable {
    let apiVersion = 1
    let source = "fixture-host"
    let userID: String
    let role: String
    let mode: String
    let languages: [String]
    let databaseSchema: Int
    let active: Int
    let completed: Int
    let logicalReferenceBytes: Int64
    let physicalPool = "unbound"
    let taskTimestampsAvailable = false
    let libraries: [FixtureLibrarySummary]
}

/// A serialized, session-bound message dispatcher. No socket, WebView, authentication or disk authorization is created.
public final class DesktopBridge: @unchecked Sendable {
    public static let maximumRequestBytes = 65536
    private let api: PrototypePlatformAPI
    private let session: PrototypeSession
    private let limits: BridgeLimits
    private let lock = NSLock()
    private var closed = false
    private var usedRequestIDs: Set<String> = []
    public convenience init(api: PrototypePlatformAPI, session: PrototypeSession) throws {
        try self.init(api: api, session: session, limits: BridgeLimits())
    }
    init(api: PrototypePlatformAPI, session: PrototypeSession, limits: BridgeLimits) throws {
        try require((1...4096).contains(limits.requests) && (128...1_048_576).contains(limits.responseBytes), .invalidSchema)
        let info = try api.overview(session: session)
        try require(info.databaseSchema == 3, .unsupported)
        self.api = api; self.session = session; self.limits = limits
    }
    deinit { api.endSession(session) }
    public func close() {
        lock.lock(); defer { lock.unlock() }
        if !closed { closed = true; api.endSession(session) }
    }
    static func rejection(requestID: String?, code: String) -> Data {
        let value: [String: Any] = ["apiVersion": 1, "requestId": requestID as Any? ?? NSNull(), "error": ["code": code]]
        return (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
            ?? Data(#"{"apiVersion":1,"requestId":null,"error":{"code":"unavailable"}}"#.utf8)
    }
    private func response<T: Encodable>(_ data: T, id: String) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]; encoder.dateEncodingStrategy = .iso8601
        let result = try encoder.encode(BridgeSuccess(requestId: id, data: data))
        try require(result.count <= limits.responseBytes, .budgetExceeded)
        return result
    }
    private func writable() throws {
        let info = try api.overview(session: session)
        guard info.mode == "synthetic_development" else { throw BridgeFault.readOnly }
    }
    private func events(_ events: [JobEvent]) throws -> [JobEvent] {
        guard events.allSatisfy({ $0.sequence > 0 && $0.sequence <= 9_007_199_254_740_991 && $0.revision > 0 && $0.revision <= 9_007_199_254_740_991 }) else {
            throw BridgeFault.invalidResponse
        }
        return events
    }
    private func libraries() throws -> [FixtureLibrarySummary] {
        let values = try api.fixtureLibraries(session: session)
        guard values.allSatisfy({ $0.estimatedBytes >= 0 && $0.estimatedBytes <= 9_007_199_254_740_991 }) else {
            throw BridgeFault.invalidResponse
        }
        return values
    }
    public func handle(_ bytes: Data) -> Data {
        lock.lock(); defer { lock.unlock() }
        var requestID: String?
        do {
            let envelope = try BridgeJSON.decode(bytes).fields(required: ["apiVersion","requestId","method","params"])
            let version = try envelope["apiVersion"]!.integer(in: 1...1)
            try require(version == 1, .invalidSchema)
            let id = try envelope["requestId"]!.text(maximumBytes: 128)
            try require(id.utf8.allSatisfy { (48...57).contains($0) || (65...90).contains($0) || (97...122).contains($0) || [45,46,95].contains($0) }, .invalidSchema)
            requestID = id
            try require(!closed, .denied)
            try require(!usedRequestIDs.contains(id), .replay)
            try require(usedRequestIDs.count < limits.requests, .budgetExceeded)
            usedRequestIDs.insert(id)
            let method = try envelope["method"]!.text(maximumBytes: 64)
            let params = envelope["params"]!
            switch method {
            case "overview":
                _ = try params.fields(required: [])
                let info = try api.overview(session: session)
                try require(info.databaseSchema == 3, .unsupported)
                let jobs = try api.durableJobs(session: session), libraries = try self.libraries()
                var total: Int64 = 0
                for library in libraries {
                    let sum = total.addingReportingOverflow(library.estimatedBytes)
                    guard !sum.overflow && sum.partialValue <= 9_007_199_254_740_991 else { throw BridgeFault.invalidResponse }
                    total = sum.partialValue
                }
                return try response(DesktopOverview(userID: info.userID, role: info.role, mode: info.mode, languages: info.languages,
                    databaseSchema: info.databaseSchema, active: jobs.filter { ["queued","running","waiting_for_volume"].contains($0.state) }.count,
                    completed: jobs.filter { $0.state == "completed" }.count, logicalReferenceBytes: total, libraries: libraries), id: id)
            case "authorizeApp":
                let p = try params.fields(required: ["id"]), app = try p.text("id", maximum: 32)
                try require(["overview","files","storage","apps","tasks","settings","preferences"].contains(app), .unsupported)
                let info = try api.overview(session: session)
                try require(app != "settings" || info.role == "administrator", .denied)
                return try response(true, id: id)
            case "listJobs":
                _ = try params.fields(required: [])
                return try response(api.durableJobs(session: session).map(DesktopJob.init), id: id)
            case "submitLabelJob":
                let p = try params.fields(required: ["id","key","value"])
                let jobID = try p.text("id"), key = try p.text("key"), value = try p.text("value", maximum: 1024)
                try require(value.count <= 80 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, .invalidSchema)
                try writable()
                let target = "desktop-" + SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
                return try response(DesktopJob(api.submitLabelJob(id: jobID, key: key, label: target, value: value, session: session)), id: id)
            case "cancelJob":
                let p = try params.fields(required: ["id"]), jobID = try p.text("id")
                try writable()
                return try response(DesktopJob(api.cancelJob(id: jobID, session: session)), id: id)
            case "pollEvents":
                let p = try params.fields(required: ["consumerID"], optional: ["limit"])
                let consumer = try p.text("consumerID"), limit = try p.integer("limit", range: 1...100, fallback: 50)
                try writable()
                return try response(events(api.jobEvents(consumerID: consumer, limit: Int(limit), session: session)), id: id)
            case "acknowledgeEvents":
                let p = try params.fields(required: ["consumerID","through"])
                let consumer = try p.text("consumerID"), through = try p.integer("through", range: 0...9_007_199_254_740_991)
                try writable(); try api.acknowledgeJobEvents(consumerID: consumer, through: through, session: session)
                return try response(true, id: id)
            case "listLibraries":
                _ = try params.fields(required: [])
                return try response(libraries(), id: id)
            case "listFiles":
                let p = try params.fields(required: ["libraryID"], optional: ["relativePath","maximumEntries"])
                let library = try p.text("libraryID"), path = try p.text("relativePath", maximum: 4096, fallback: "", allowEmpty: true)
                let count = try p.integer("maximumEntries", range: 1...1000, fallback: 1000)
                return try response(api.listFixtureLibrary(libraryID: library, relativePath: path, maximumEntries: Int(count), session: session), id: id)
            case "previewFile":
                let p = try params.fields(required: ["libraryID","relativePath"], optional: ["maximumBytes"])
                let library = try p.text("libraryID"), path = try p.text("relativePath", maximum: 4096)
                let count = try p.integer("maximumBytes", range: 1...65536, fallback: 65536)
                return try response(api.previewFixtureText(libraryID: library, relativePath: path, maximumBytes: Int(count), session: session), id: id)
            default: throw NASError.unsupported
            }
        } catch {
            let code: String
            if let fault = error as? BridgeFault { code = fault.rawValue }
            else if let error = error as? NASError { code = error == .invalidSchema ? "invalidInput" : error.rawValue }
            else { code = "unavailable" }
            return Self.rejection(requestID: requestID, code: code)
        }
    }
}

/// NDJSON transport over the caller-owned stdin/stdout only. No listener or browser is opened.
public enum DesktopBridgeCLI {
    public static func run(root: URL, fixtureUser: String) throws {
        let api = try PrototypePlatformAPI(root: root)
        let session = try api.beginFixtureSession(userID: fixtureUser)
        let bridge: DesktopBridge
        do { bridge = try DesktopBridge(api: api, session: session) }
        catch { api.endSession(session); throw error }
        defer { bridge.close() }
        var frame = Data(), buffer = [UInt8](repeating: 0, count: 4096), frames = 0
        while true {
            let count = buffer.withUnsafeMutableBytes { Darwin.read(STDIN_FILENO, $0.baseAddress, $0.count) }
            if count < 0 { if errno == EINTR { continue }; throw NASError.interrupted }
            if count == 0 {
                if !frame.isEmpty {
                    try FileHandle.standardOutput.write(contentsOf: DesktopBridge.rejection(requestID: nil, code: "invalidInput") + Data([10]))
                    throw NASError.invalidSchema
                }
                return
            }
            for byte in buffer.prefix(count) {
                if byte == 10 {
                    frames += 1
                    guard frames <= 4096 else {
                        try FileHandle.standardOutput.write(contentsOf: DesktopBridge.rejection(requestID: nil, code: "budgetExceeded") + Data([10]))
                        throw NASError.budgetExceeded
                    }
                    if frame.last == 13 { frame.removeLast() }
                    try FileHandle.standardOutput.write(contentsOf: bridge.handle(frame) + Data([10]))
                    frame.removeAll(keepingCapacity: true)
                } else {
                    guard frame.count < DesktopBridge.maximumRequestBytes else {
                        try FileHandle.standardOutput.write(contentsOf: DesktopBridge.rejection(requestID: nil, code: "budgetExceeded") + Data([10]))
                        throw NASError.budgetExceeded
                    }
                    frame.append(byte)
                }
            }
        }
    }
}
