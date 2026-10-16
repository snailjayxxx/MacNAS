import Foundation
import Darwin
import CryptoKit

public enum PortableInstance {
    public static let sampleIDs = ["hello-diagnostics", "sample-file-index"]
    static let excluded: Set<String> = ["host-binding", "secrets", "sessions", "optional-cache", "restore", ".instance.lock"]
    public static var requiredFiles: [String] {
        ["instance.json", "config/platform.json", "state/database.json", "state/platform.pgdump", "logical-storage/references.json"]
        + sampleIDs.flatMap { ["apps/\($0)/manifest.json", "app-data/\($0)/schema.json"] }
    }
    static func strictRead<T: Codable>(_ type: T.Type, _ url: URL) throws -> T {
        let value = try SafeFS.read(type, url)
        let original = try JSONSerialization.jsonObject(with: SafeFS.readData(url)) as? NSObject
        let canonical = try JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? NSObject
        try require(original == canonical, .invalidSchema) // Unknown fields cannot smuggle secrets/paths.
        return value
    }
    public static func createSynthetic(at root: URL, hostID: String = "mock-source", databaseVersion:Int=1) throws {
        try require([1,2,3,4,5,6].contains(databaseVersion),.invalidSchema)
        try SafeFS.freshDirectory(root)
        for dir in ["config", "state", "logical-storage", "host-binding", "apps", "app-data"] {
            try FileManager.default.createDirectory(at: root.appendingPathComponent(dir), withIntermediateDirectories: false)
        }
        try SafeFS.write(InstanceIdentity(), to: SafeFS.resolve(root, "instance.json"))
        try SafeFS.write(PortableConfig(), to: SafeFS.resolve(root, "config/platform.json"))
        let volumes = [VolumeReference(libraryID: "fixture-photo-library", volumeID: UUID(), relativePath: "合成资料/写真", estimatedBytes: 35_000_000_000_000)]
        try SafeFS.write(volumes, to: SafeFS.resolve(root, "logical-storage/references.json"))
        let state = try StateStore.createSynthetic(schemaVersion:databaseVersion)
        var binding = HostBinding(hostID: hostID); binding.databaseName = state.databaseName; binding.mode = "synthetic_development"
        try SafeFS.write(binding, to: SafeFS.resolve(root, "host-binding/binding.json"))
        try SafeFS.write(["engine": "PostgreSQL", "major": "18", "schemaVersion": String(databaseVersion), "snapshotFormat": "pgdump-custom"], to: SafeFS.resolve(root, "state/database.json"))
        try state.label("manual-tag", "合成测试・家族")
        try state.enqueue("fixture-job", key: "fixture-job-key")
        for id in sampleIDs {
            for parent in ["apps", "app-data"] {
                try FileManager.default.createDirectory(at: root.appendingPathComponent("\(parent)/\(id)"), withIntermediateDirectories: false)
            }
            try SafeFS.write(PluginManifest.sample(id,dataSchema:databaseVersion), to: SafeFS.resolve(root, "apps/\(id)/manifest.json"))
            let schema = id == "hello-diagnostics" ? "app_hello_diagnostics" : "app_sample_file_index"
            try SafeFS.write(["dataSchema": String(databaseVersion), "schema": schema], to: SafeFS.resolve(root, "app-data/\(id)/schema.json"))
            try state.execute("INSERT INTO \(schema).state(id,value) VALUES('sample-state','synthetic:\(id)');")
        }
    }
    public static func store(_ root: URL) throws -> StateStore {
        let binding = try strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        return try StateStore(databaseName: binding.databaseName, instanceRoot: root)
    }
    static func signingKey() throws -> Curve25519.Signing.PrivateKey {
        guard let value = ProcessInfo.processInfo.environment["MACNAS_TEST_EXPORT_SIGNING_KEY"], let bytes = Data(base64Encoded: value) else { throw NASError.denied }
        return try Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
    }
    static func trustedKey() throws -> Curve25519.Signing.PublicKey {
        guard let value = ProcessInfo.processInfo.environment["MACNAS_TRUSTED_EXPORT_PUBLIC_KEY"], let bytes = Data(base64Encoded: value) else { throw NASError.denied }
        return try Curve25519.Signing.PublicKey(rawRepresentation: bytes)
    }

    static func validateLayout(_ root: URL, exported: Bool) throws -> InstanceIdentity {
        let identity = try strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        try require(identity.schemaVersion == 1 && identity.kind == "synthetic-prototype" && identity.generation >= 0, .invalidSchema)
        let config = try strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
        try require(config.schemaVersion == 1 && Set(config.languages).isSubset(of: ["zh-CN", "ja-JP"]), .invalidSchema)
        try require(Set(config.users.map(\.id)).count == config.users.count, .invalidSchema)
        try require(config.users.allSatisfy { ["administrator", "reader"].contains($0.role) && !$0.id.contains("/") }, .invalidSchema)
        let volumes = try strictRead([VolumeReference].self, SafeFS.resolve(root, "logical-storage/references.json"))
        try require(Set(volumes.map(\.libraryID)).count == volumes.count, .invalidSchema)
        for ref in volumes { try SafeFS.relative(ref.relativePath); try require(ref.estimatedBytes >= 0, .invalidSchema) }
        let descriptor = try databaseDescriptor(root)
        let databaseVersion = try descriptor.version()
        for id in sampleIDs {
            let manifest = try strictRead(PluginManifest.self, SafeFS.resolve(root, "apps/\(id)/manifest.json"))
            try require(manifest == PluginManifest.sample(id, dataSchema: databaseVersion), .unsupported)
        }
        for id in sampleIDs {
            let schema = id == "hello-diagnostics" ? "app_hello_diagnostics" : "app_sample_file_index"
            let app = try strictRead([String: String].self, SafeFS.resolve(root, "app-data/\(id)/schema.json"))
            try require(app == ["dataSchema": String(databaseVersion), "schema": schema], .invalidSchema)
        }
        let ignored: Set<String> = exported ? ["host-binding", "restore", ".instance.lock"] : excluded
        let found = Set(try SafeFS.files(root, ignoring: ignored))
        var required = Set(requiredFiles)
        if !exported { required.remove("state/platform.pgdump") }
        var allowed = required
        if exported { allowed.formUnion(["manifest.json", "manifest.sig"]) }
        else { allowed.formUnion(["manifest.json", "manifest.sig", "state/platform.pgdump"]) }
        try require(found.isSubset(of: allowed) && required.isSubset(of: found), .invalidSchema)
        if exported { try PostgreSQLTools().inspectArchive(SafeFS.resolve(root, "state/platform.pgdump")) }
        else { try store(root).validate(expectedVersion: databaseVersion) }

        return identity
    }
    /// A has no vault registration or file executor. This gate proves only the
    /// explicitly disabled/unregistered host layout; B must replace it with a vault registry.
    enum FileEffectPortableBoundary { case legacy, unboundPackage, disabledUnregistered }
    @discardableResult static func validateFileEffectHostBoundary(_ root: URL, version: Int, store: StateStore? = nil) throws -> FileEffectPortableBoundary {
        for path in [FixturePhysicalCapacityNamespace.markerPath, RecycleVault.registrationPath] {
            let marker = try SafeFS.resolve(root, path)
            try require(!FileManager.default.fileExists(atPath: marker.path), .unsupported)
        }
        if version < 4 { return .legacy }
        let host = try SafeFS.resolve(root, "host-binding")
        guard FileManager.default.fileExists(atPath: host.path) else { return .unboundPackage }
        let attributes = try FileManager.default.attributesOfItem(atPath: host.path)
        try require(attributes[.type] as? FileAttributeType == .typeDirectory, .unsafeFile)
        let names = try FileManager.default.contentsOfDirectory(atPath: host.path)
        let allowed: Set<String> = ["binding.json", "configuration.lock", "file-operations.lock"]
        try require(Set(names).isSubset(of: allowed) && names.contains("binding.json"), .unsupported)
        for name in names {
            let file = try SafeFS.resolve(host, name)
            let info = try FileManager.default.attributesOfItem(atPath: file.path)
            try require(info[.type] as? FileAttributeType == .typeRegular, .unsafeFile)
        }
        // strictRead rejects unknown JSON fields, including future vault registrations.
        let binding = try strictRead(HostBinding.self, SafeFS.resolve(host, "binding.json"))
        try require(!binding.hostID.isEmpty && binding.hostID.utf8.count <= 256 && !binding.hostID.contains("\0"), .invalidSchema)
        try require(["synthetic_development", "read_only_recovery", "rolled_back_recovery"].contains(binding.mode), .unsupported)
        try PostgreSQLTools.fixtureName(binding.databaseName)
        if let store { try require(binding.databaseName == store.databaseName, .staleState) }
        return .disabledUnregistered
    }
    static func requirePortableFileEffectsDisabled(_ root: URL, store: StateStore) throws {
        let version = try store.schemaVersion()
        for path in [FixturePhysicalCapacityNamespace.markerPath, RecycleVault.registrationPath] {
            let marker = try SafeFS.resolve(root, path)
            try require(!FileManager.default.fileExists(atPath: marker.path), .unsupported)
        }
        if version < 4 { return }
        try store.requirePortableRecycleEmpty()
        _ = try validateFileEffectHostBoundary(root, version: version, store: store)
    }
    public static func preview(_ root: URL, exported: Bool = false) throws -> MigrationPreview {
        let identity = try validateLayout(root, exported: exported)
        if exported { _ = try validateFileEffectHostBoundary(root, version: databaseDescriptor(root).version()) }
        else { try requirePortableFileEffectsDisabled(root, store: store(root)) }
        let refs = try strictRead([VolumeReference].self, SafeFS.resolve(root, "logical-storage/references.json"))
        var total: Int64 = 0
        for ref in refs {
            let addition = total.addingReportingOverflow(ref.estimatedBytes)
            try require(!addition.overflow, .invalidSchema); total = addition.partialValue
        }
        return MigrationPreview(instanceID: identity.instanceID, fileCount: requiredFiles.count, externalBytesNotIncluded: total)
    }
    public static func verify(_ root: URL) throws -> ExportManifest {
        let manifestURL = try SafeFS.resolve(root, "manifest.json")
        let signatureText = String(decoding: try SafeFS.readData(SafeFS.resolve(root, "manifest.sig"), maximumBytes: 1024), as: UTF8.self)
        guard let signature = Data(base64Encoded: signatureText) else { throw NASError.integrity }
        let manifestBytes = try SafeFS.readData(manifestURL)
        try require(manifestBytes.count < 4_000_000, .integrity)
        try require(try trustedKey().isValidSignature(signature, for: manifestBytes), .integrity)
        let manifest = try strictRead(ExportManifest.self, manifestURL)
        try require(manifest.schemaVersion == 1 && manifest.trust == "ed25519-signed-synthetic-fixture", .invalidSchema)
        try require(manifest.files.count == requiredFiles.count && Set(manifest.files.map(\.path)) == Set(requiredFiles), .integrity)
        for record in manifest.files {
            let file = try SafeFS.resolve(root, record.path)
            let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
            try require((attrs[.size] as? NSNumber)?.uint64Value == record.bytes, .integrity)
            try require(try SafeFS.digest(file) == record.sha256, .integrity)
        }
        let identity = try validateLayout(root, exported: true)
        _ = try validateFileEffectHostBoundary(root, version: databaseDescriptor(root).version())
        try require(identity.instanceID == manifest.instanceID && identity.generation == manifest.generation, .integrity)
        return manifest
    }
    static func prepareDestination(_ dest: URL, source: URL) throws -> URL {
        try SafeFS.inspect(dest)
        let d = dest.standardizedFileURL.path, s = source.standardizedFileURL.path
        try require(d != s && !d.hasPrefix(s + "/") && !s.hasPrefix(d + "/"), .unsafePath)
        try require(!FileManager.default.fileExists(atPath: d), .collision)
        let partial = dest.deletingLastPathComponent().appendingPathComponent(".\(dest.lastPathComponent).partial-\(UUID().uuidString)")
        try SafeFS.freshDirectory(partial)
        return partial
    }
    static func copyFiles(from source: URL, to stage: URL, snapshot: Bool, interruptAfter: Int?) throws {
        for (index, path) in requiredFiles.sorted().enumerated() {
            let from = try SafeFS.resolve(source, path), to = try SafeFS.resolve(stage, path)
            try FileManager.default.createDirectory(at: to.deletingLastPathComponent(), withIntermediateDirectories: true)
            if snapshot && path == "state/platform.pgdump" {
                try store(source).snapshot(to: to)
            } else { try FileManager.default.copyItem(at: from, to: to) }
            let file = try FileHandle(forWritingTo: to); try file.synchronize(); try file.close()
            if interruptAfter == index + 1 { throw NASError.interrupted }
        }
    }
    static func publish(_ stage: URL, _ dest: URL) throws {
        // Both are siblings on one filesystem; EXCL refuses a target created by a racing process.
        try require(renamex_np(stage.path, dest.path, UInt32(RENAME_EXCL)) == 0, .collision)
        let fd = open(dest.deletingLastPathComponent().path, O_RDONLY | O_DIRECTORY)
        if fd >= 0 { _ = fsync(fd); close(fd) }
        // Directory fsync is best effort; process interruption tests do not prove power-loss durability.
    }
    static func databaseDescriptor(_ root: URL) throws -> DatabaseDescriptor {
        let descriptor = try strictRead(DatabaseDescriptor.self, SafeFS.resolve(root, "state/database.json"))
        _ = try descriptor.version(); return descriptor
    }
    static func writeDatabaseDescriptor(_ root: URL, store: StateStore) throws {
        var descriptor = DatabaseDescriptor(); descriptor.schemaVersion = String(try store.schemaVersion())
        descriptor.baseDataSHA256 = try store.baseDataDigest(); descriptor.contentSHA256 = try store.contentDigest()
        try SafeFS.write(descriptor, to: SafeFS.resolve(root, "state/database.json"))
    }
    @discardableResult static func seal(_ root: URL, exportID: UUID = UUID(), parentExportID: UUID? = nil) throws -> ExportManifest {
        let identity = try strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        let records = try requiredFiles.sorted().map { path -> FileRecord in
            let file = try SafeFS.resolve(root, path)
            let size = (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as! NSNumber).uint64Value
            return FileRecord(path: path, sha256: try SafeFS.digest(file), bytes: size)
        }
        var manifest = ExportManifest(instanceID: identity.instanceID, generation: identity.generation, exportID: exportID, files: records)
        manifest.parentExportID = parentExportID
        try SafeFS.write(manifest, to: SafeFS.resolve(root, "manifest.json"))
        let signature = try signingKey().signature(for: SafeFS.readData(SafeFS.resolve(root, "manifest.json")))
        try signature.base64EncodedString().write(to: SafeFS.resolve(root, "manifest.sig"), atomically: true, encoding: .utf8)
        _ = try verify(root); return manifest
    }
    @discardableResult public static func export(from source: URL, to dest: URL, interruptAfter: Int? = nil, timeout: TimeInterval = 10, cancellation: CancellationToken? = nil) throws -> ExportManifest {
        try require(timeout >= 0 && timeout <= 60, .invalidSchema)
        let lock = try InstanceLock(source, timeout: timeout, cancellation: cancellation)
        return try withExtendedLifetime(lock) {
            _ = try validateLayout(source, exported: false)
            let state = try store(source)
            let databaseBarrier = try DatabaseSnapshotBarrier(store: state, timeout: max(0.1,timeout), cancellation: cancellation)
            return try withExtendedLifetime(databaseBarrier) {
                try cancellation?.check()
                try requirePortableFileEffectsDisabled(source, store: state)
                let stage = try prepareDestination(dest, source: source)
                try copyFiles(from: source, to: stage, snapshot: true, interruptAfter: interruptAfter)
                try writeDatabaseDescriptor(stage, store: state)
                try cancellation?.check(); try databaseBarrier.check()
                let manifest = try seal(stage)
                try databaseBarrier.check(); try requirePortableFileEffectsDisabled(source, store: state)
                try publish(stage, dest)
                return manifest
            }
        }
    }
    @discardableResult public static func restore(from source: URL, to dest: URL, hostID: String, confirmCreate: Bool = false, interruptAfter: Int? = nil) throws -> MigrationPreview {
        _ = try verify(source)
        let report = try preview(source, exported: true)
        guard confirmCreate else { return report }
        _ = try MigrationCoordinator.restore(from: source, to: dest, hostID: hostID, fault: interruptAfter.map { .afterCopiedFiles($0) })
        return report
    }
    public static func cutover() throws { throw NASError.unsupported }
}
