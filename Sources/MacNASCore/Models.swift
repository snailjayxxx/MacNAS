import Foundation

public struct InstanceIdentity: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var kind: String = "synthetic-prototype"
    public var instanceID: UUID = UUID()
    public var generation: Int = 0
}
public struct LogicalUser: Codable, Equatable { public var id: String; public var role: String }
public struct PortableConfig: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var languages: [String] = ["zh-CN", "ja-JP"]
    public var users: [LogicalUser] = [.init(id: "fixture-owner", role: "administrator"), .init(id: "fixture-family", role: "reader")]
    public var secretReferences: [String] = ["tls-key-needs-reauthorization"]
}
public struct VolumeReference: Codable, Equatable {
    public var libraryID: String
    public var volumeID: UUID
    public var relativePath: String
    public var estimatedBytes: Int64
    public init(libraryID: String, volumeID: UUID, relativePath: String, estimatedBytes: Int64) {
        self.libraryID = libraryID; self.volumeID = volumeID; self.relativePath = relativePath; self.estimatedBytes = estimatedBytes
    }
}
public struct HostBinding: Codable, Equatable {
    public var hostID: String
    public var databaseName: String = ""
    public var migrationID: UUID? = nil
    public var mode: String = "read_only_recovery"
    public var needsAuthorization: [String] = ["keychain", "TCC", "SMB", "helper", "volume-rebinding", "source-fencing"]
    public init(hostID: String) { self.hostID = hostID }
}
public struct FileRecord: Codable, Equatable { public var path: String; public var sha256: String; public var bytes: UInt64 }
public struct ExportManifest: Codable {
    public var schemaVersion: Int = 1
    public var instanceID: UUID
    public var generation: Int
    public var exportID: UUID
    public var parentExportID: UUID? = nil
    public var files: [FileRecord]
    public var excluded: [String] = ["raw-user-data", "host-binding", "secrets", "sessions", "optional-cache", "system-services", "Keychain", "TCC"]
    public var trust: String = "ed25519-signed-synthetic-fixture"
}
public struct MigrationPreview: Codable {
    public var instanceID: UUID
    public var fileCount: Int
    public var externalBytesNotIncluded: Int64
    public var mode: String = "read_only_recovery"
    public var requires: [String] = HostBinding(hostID: "preview").needsAuthorization
}
public struct MountedVolume: Equatable {
    public var id: UUID
    public var displayName: String
    public var isSystem: Bool
    public var authorized: Bool
    public init(id: UUID, displayName: String, isSystem: Bool = false, authorized: Bool = false) {
        self.id = id; self.displayName = displayName; self.isSystem = isSystem; self.authorized = authorized
    }
}
public enum VolumeGuard {
    public static func canWrite(_ reference: VolumeReference, inventory: [MountedVolume]) throws {
        try SafeFS.relative(reference.relativePath)
        let matches = inventory.filter { $0.id == reference.volumeID }
        try require(matches.count == 1, .missingVolume)
        try require(!matches[0].isSystem && matches[0].authorized, .denied)
    }
}

/// A deterministic test authority. No production writer uses these proofs.
public final class MockLeaseAuthority {
    public private(set) var holder: String?
    public private(set) var generation: Int = 0
    public init() {}
    public func acquire(host: String, expectedGeneration: Int, sourceStopped: Bool, ownerApproved: Bool) throws -> Int {
        try require(ownerApproved && sourceStopped && holder == nil, .denied)
        try require(expectedGeneration == generation, .staleState)
        generation += 1; holder = host; return generation
    }
    public func release(host: String, generation: Int) throws {
        try require(holder == host && self.generation == generation, .denied)
        holder = nil
    }
}

struct DatabaseDescriptor: Codable, Equatable {
    var engine = "PostgreSQL"
    var major = "18"
    var schemaVersion = "1"
    var snapshotFormat = "pgdump-custom"
    var baseDataSHA256: String? = nil
    var contentSHA256: String? = nil
    func version() throws -> Int {
        guard let version = Int(schemaVersion), [1,2,3].contains(version) else { throw NASError.invalidSchema }
        try require(engine == "PostgreSQL" && major == "18" && snapshotFormat == "pgdump-custom", .invalidSchema)
        for hash in [baseDataSHA256, contentSHA256].compactMap({ $0 }) {
            try require(hash.count == 64 && hash.allSatisfy { $0.isASCII && ("0123456789abcdef".contains($0)) }, .invalidSchema)
        }
        try require((baseDataSHA256 == nil) == (contentSHA256 == nil), .invalidSchema)
        return version
    }
}
