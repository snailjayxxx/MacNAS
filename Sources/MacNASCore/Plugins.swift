import Foundation

public struct PluginManifest: Codable, Equatable {
    public var id: String
    public var vendor: String = "MacNAS-first-party"
    public var version: String = "0.1.0"
    public var apiRange: String = "1"
    public var minimumMacOS: Int = 15
    public var architectures: [String] = ["arm64"]
    public var entrypoint: String
    public var permissions: [String]
    public var storageMounts: [String]
    public var networkPolicy: String = "none-declared-not-os-enforced"
    public var resources: [String: Int] = ["timeoutSeconds": 5, "maximumOutputBytes": 65536]
    public var dataSchema: Int = 1
    public var migrations: [Int] = [1]
    public var signedDigest: String = "UNSIGNED_DEVELOPMENT_FIXTURE"
    public static func sample(_ id: String, dataSchema: Int = 1) -> PluginManifest {
        var manifest = PluginManifest(id: id, entrypoint: id,
                       permissions: id == "sample-file-index" ? ["fixture-directory-read"] : ["diagnostics-read"],
                       storageMounts: id == "sample-file-index" ? ["fixture-library"] : [])
        manifest.dataSchema = dataSchema; manifest.migrations = Array(1...dataSchema)
        manifest.version = "0.\(dataSchema).0"
        return manifest
    }
}

public enum PluginState: String, Sendable { case registered, disabled, failed }
public struct PluginGrant: Sendable {
    public let id: UUID
    public let app: SampleApp
    public let instanceID: UUID
    fileprivate init(id: UUID, app: SampleApp, instanceID: UUID) { self.id=id;self.app=app;self.instanceID=instanceID }
}
/// Trusted first-party registry. Its opaque grants authorize the in-process API; they are not OS sandbox tokens.
public final class SamplePluginRegistry: @unchecked Sendable {
    private struct Entry { var state:PluginState;var epoch:UUID;var manifest:PluginManifest }
    private struct Ticket { var app:SampleApp;var epoch:UUID;var instanceID:UUID;var permissions:Set<String>;var deadline:TimeInterval }
    private let lock=NSLock()
    private var entries:[String:Entry]=[:]
    private var tickets:[UUID:Ticket]=[:]
    public init() {}
    private func locked<T>(_ body:() throws -> T) rethrows -> T { lock.lock();defer { lock.unlock() };return try body() }
    public var states:[String:PluginState] { locked { entries.mapValues(\.state) } }
    public func register(_ manifest:PluginManifest) throws {
        try require(SampleApp(rawValue:manifest.id) != nil && [1,2,3].contains(manifest.dataSchema) && manifest == .sample(manifest.id,dataSchema:manifest.dataSchema),.denied)
        locked { entries[manifest.id]=Entry(state:.registered,epoch:UUID(),manifest:manifest) }
    }
    public func disable(_ id:String) { locked { if entries[id] != nil { entries[id]?.state = .disabled;entries[id]?.epoch=UUID() } } }
    public func uninstall(_ id:String) { _=locked { entries.removeValue(forKey:id) } }
    public func authorize(_ id:String,permission:String,grants:Set<String>) throws {
        try locked { try require(entries[id]?.state == .registered && entries[id]?.manifest.permissions.contains(permission) == true && grants.contains(permission),.denied) }
    }
    public func recordExit(_ id:String,status:Int32) { locked { if status != 0 && entries[id]?.state == .registered { entries[id]?.state = .failed;entries[id]?.epoch=UUID() } } }
    public func issue(app:SampleApp,instanceID:UUID,permissions:Set<String>,lifetime:TimeInterval=300) throws -> PluginGrant {
        try locked {
            guard let entry=entries[app.rawValue],entry.state == .registered else { throw NASError.denied }
            try require(!permissions.isEmpty && permissions.isSubset(of:Set(entry.manifest.permissions)),.denied)
            try require(lifetime>0 && lifetime<=3600 && tickets.count<1000,.invalidSchema)
            let id=UUID();tickets[id]=Ticket(app:app,epoch:entry.epoch,instanceID:instanceID,permissions:permissions,deadline:ProcessInfo.processInfo.systemUptime+lifetime)
            return PluginGrant(id:id,app:app,instanceID:instanceID)
        }
    }
    private func checkLocked(_ grant:PluginGrant,permission:String) throws {
        guard let ticket=tickets[grant.id],let entry=entries[grant.app.rawValue] else { throw NASError.denied }
        try require(entry.state == .registered && ticket.epoch == entry.epoch && ticket.app == grant.app && ticket.instanceID == grant.instanceID && ticket.permissions.contains(permission),.denied)
        try require(ProcessInfo.processInfo.systemUptime<ticket.deadline,.expired)
    }
    public func check(_ grant:PluginGrant,permission:String) throws { try locked { try checkLocked(grant,permission:permission) } }
    func withGrant<T>(_ grant:PluginGrant,permission:String,_ body:() throws -> T) throws -> T {
        try locked { try checkLocked(grant,permission:permission);return try body() }
    }
    func manifest(_ grant:PluginGrant,permission:String) throws -> PluginManifest {
        try locked { try checkLocked(grant,permission:permission);return entries[grant.app.rawValue]!.manifest }
    }
}
public enum SampleFileIndex {
    public static func inspect(root: URL) throws -> [String] {
        try SafeFS.files(root) // Only the explicitly granted synthetic directory; rejects links.
    }
}
