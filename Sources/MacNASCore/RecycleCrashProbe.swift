import Foundation
import Darwin

/// Deliberately restricted test worker, not a desktop operation or production filesystem API.
/// The parent test must supply the TestLab environment, explicit confirmation and an already-created fixture.
public enum SyntheticRecycleCrashProbe {
    public static func run(root: URL, path: String, stopAfter: String, confirmed: Bool) throws -> [String: String] {
        try require(ProcessInfo.processInfo.environment["MACNAS_RECYCLE_PROBE_ENABLED"] == "1" && confirmed, .denied)
        try require(["beforeRename", "afterRename", "observed"].contains(stopAfter), .invalidSchema)
        try RecycleVault.requireLabRoot(root); try FileEffectMetadata.path(path)
        let marker = try SafeFS.resolve(root, "host-binding/recycle-test-checkpoint.json")
        try require(!FileManager.default.fileExists(atPath: marker.path), .collision)
        let host = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        let grant = try host.approve(.recycle, confirmed: true), coordinator = FixtureRecycleCoordinator(authority: host)
        let preview = try coordinator.preview(path: path, grant: grant)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true, key: Data(UUID().uuidString.utf8)) { point in
            if point.rawValue == stopAfter {
                try waitForParent(root: root, point: stopAfter, preview: preview, direction: "recycle")
            }
        }
        return ["status": result.state, "operationID": result.operationID.uuidString]
    }
    public static func restore(root: URL, entryID: UUID, parentPath: String, name: String,
                               stopAfter: String, confirmed: Bool, destinationConfirmed: Bool) throws -> [String: String] {
        try require(ProcessInfo.processInfo.environment["MACNAS_RECYCLE_PROBE_ENABLED"] == "1" && confirmed && destinationConfirmed, .denied)
        try require(["beforeRename", "afterRename", "observed"].contains(stopAfter), .invalidSchema)
        try RecycleVault.requireLabRoot(root); try FileEffectMetadata.path(parentPath, empty: true)
        try FixtureFileOperationIntent.component(name)
        let marker = try SafeFS.resolve(root, "host-binding/recycle-test-checkpoint.json")
        try require(!FileManager.default.fileExists(atPath: marker.path), .collision)
        let host = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        let grant = try host.approve(.restore, confirmed: true)
        let target = try host.approveRestoreDestination(parentPath: parentPath, confirmed: true)
        let coordinator = FixtureRecycleCoordinator(authority: host)
        let preview = try coordinator.previewRestore(entryID: entryID, parentPath: parentPath, name: name, grant: grant, destinationGrant: target)
        let result = try coordinator.commit(previewID: preview.previewID, grant: grant, confirmed: true,
            key: Data(UUID().uuidString.utf8), destinationGrant: target) { point in
            if point.rawValue == stopAfter { try waitForParent(root: root, point: stopAfter, preview: preview, direction: "restore") }
        }
        return ["status": result.state, "operationID": result.operationID.uuidString]
    }
    private static func waitForParent(root: URL, point: String, preview: RecycleFilePreview, direction: String) throws {
        let marker = try SafeFS.resolve(root, "host-binding/recycle-test-checkpoint.json")
        let value = ["point": point, "direction": direction, "pid": String(getpid()), "operationID": preview.operationID.uuidString,
            "entryID": preview.entryID.uuidString, "status": "waiting-for-parent-sigkill"]
        let bytes = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        let fd = open(marker.path, O_CREAT | O_EXCL | O_WRONLY | O_CLOEXEC | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw NASError.collision }
        do {
            try bytes.withUnsafeBytes { data in
                var offset = 0
                while offset < data.count {
                    let n = write(fd, data.baseAddress!.advanced(by: offset), data.count - offset)
                    if n < 0 && errno == EINTR { continue }
                    try require(n > 0, .unsafeFile); offset += n
                }
            }
            try require(fsync(fd) == 0, .unsafeFile); close(fd)
        } catch { close(fd); throw error }
        while true { Thread.sleep(forTimeInterval: 0.05) }
    }
}
