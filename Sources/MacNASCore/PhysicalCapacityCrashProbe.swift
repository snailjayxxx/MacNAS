import Foundation
import Darwin

/// A fixed synthetic test worker. No caller-selected source bytes or output path.
public enum SyntheticPhysicalCapacityCrashProbe {
    public static func run(root: URL, stopAfter: String, confirmed: Bool) throws -> [String: String] {
        try require(ProcessInfo.processInfo.environment["MACNAS_CAPACITY_PROBE_ENABLED"] == "1" && confirmed, .denied)
        try require(["reserved","armed","afterPublish","owned"].contains(stopAfter), .invalidSchema)
        try RecycleVault.requireLabRoot(root)
        let parent = try RecycleDirectory(root.appendingPathComponent("host-binding"))
        try require(try parent.named("capacity-test-checkpoint.json") == nil, .collision)
        let host = try FixturePhysicalCapacityNamespace(root: root, userID: Data("fixture-owner".utf8))
        try require(try host.store.rows("SELECT count(*) FROM macnas.capacity_allocations;") == [["0"]], .unsupported)
        let data = Data("physical-capacity-sigkill".utf8)
        let grant = try host.approveReceive(key: Data("crash-probe".utf8), bytes: Int64(data.count),
                                           sha256: TransferEncoding.digest(data), confirmed: true)
        let result = try host.receive(data, grant: grant) { point in
            if point.rawValue == stopAfter {
                let rows = try host.store.rows("SELECT allocation_id::text,state FROM macnas.capacity_allocations;")
                try require(rows.count == 1 && rows[0].count == 2, .invalidSchema)
                let payload = ["point":stopAfter,"pid":String(getpid()),"allocationID":rows[0][0],
                               "persistedState":rows[0][1],"status":"waiting-for-parent-sigkill"]
                let bytes = try JSONSerialization.data(withJSONObject:payload,options:[.sortedKeys])
                let fd = openat(parent.fd,"capacity-test-checkpoint.json",O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC,0o600)
                guard fd >= 0 else { throw NASError.collision }
                do {
                    try bytes.withUnsafeBytes { buffer in
                        var offset = 0
                        while offset < buffer.count {
                            let n = write(fd,buffer.baseAddress!.advanced(by:offset),buffer.count-offset)
                            if n < 0 && errno == EINTR { continue }
                            try require(n > 0 && n <= buffer.count-offset,.unsafeFile); offset += n
                        }
                    }
                    try require(fsync(fd) == 0,.unsafeFile)
                } catch { close(fd); throw error }
                close(fd); try parent.synchronize()
                while true { Thread.sleep(forTimeInterval:0.05) }
            }
        }
        return ["state":result.state,"allocationID":result.allocationID.uuidString]
    }
}
