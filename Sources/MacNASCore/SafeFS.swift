import Foundation
import CryptoKit
import Darwin

public enum NASError: String, Error, Codable {
    case unsafePath, unsafeFile, collision, invalidSchema, integrity, database
    case busy, denied, expired, replay, staleState, unsupported, interrupted, missingVolume
    case timedOut, cancelled, budgetExceeded, pluginFailed
}

func require(_ condition: @autoclosure () throws -> Bool, _ error: NASError) throws {
    guard try condition() else { throw error }
}

public enum SafeFS {
    public static func relative(_ path: String) throws {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        try require(!path.isEmpty && !path.hasPrefix("/") && !path.contains("\\") && !path.contains("\0"), .unsafePath)
        try require(parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." && !$0.contains(":") }, .unsafePath)
    }
    public static func inspect(_ url: URL) throws {
        // Fail closed on symlinks in any existing path component, including the root.
        let components = url.standardizedFileURL.pathComponents
        var current = URL(fileURLWithPath: "/", isDirectory: true)
        for component in components.dropFirst() {
            current.appendPathComponent(component)
            var s = stat()
            if lstat(current.path, &s) != 0 {
                if errno == ENOENT { continue }
                throw NASError.unsafeFile
            }
            let kind = s.st_mode & S_IFMT
            try require(kind == S_IFDIR || kind == S_IFREG, .unsafeFile)
            if kind == S_IFREG { try require(s.st_nlink == 1, .unsafeFile) }
        }
    }
    public static func resolve(_ root: URL, _ path: String) throws -> URL {
        try relative(path)
        let out = root.appendingPathComponent(path).standardizedFileURL
        try require(out.path.hasPrefix(root.standardizedFileURL.path + "/"), .unsafePath)
        try inspect(out)
        return out
    }
    public static func freshDirectory(_ url: URL) throws {
        try inspect(url)
        try require(!FileManager.default.fileExists(atPath: url.path), .collision)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false,
                                                 attributes: [.posixPermissions: 0o700])
    }
    public static func write<T: Encodable>(_ value: T, to url: URL) throws {
        try inspect(url)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(value).write(to: url, options: .atomic)
    }
    public static func readData(_ url: URL, maximumBytes: Int = 4_000_000) throws -> Data {
        try inspect(url)
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NASError.unsafeFile }
        let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? file.close() }
        var s = stat()
        try require(fstat(fd, &s) == 0 && (s.st_mode & S_IFMT) == S_IFREG && s.st_nlink == 1 && s.st_size <= maximumBytes, .unsafeFile)
        let bytes = try file.read(upToCount: maximumBytes + 1) ?? Data()
        try require(bytes.count <= maximumBytes, .unsafeFile)
        return bytes
    }
    public static func read<T: Decodable>(_ type: T.Type, _ url: URL) throws -> T {
        try inspect(url)
        return try JSONDecoder().decode(type, from: readData(url))
    }
    public static func digest(_ url: URL) throws -> String {
        try inspect(url)
        let stream = try FileHandle(forReadingFrom: url)
        defer { try? stream.close() }
        var hash = SHA256()
        while let data = try stream.read(upToCount: 64 * 1024), !data.isEmpty { hash.update(data: data) }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    public static func files(_ root: URL, ignoring: Set<String> = []) throws -> [String] {
        try inspect(root)
        var result: [String] = []
        func visit(_ directory: URL, _ prefix: String) throws {
            var folded: Set<String> = []
            for url in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
                let name = url.lastPathComponent
                if prefix.isEmpty && ignoring.contains(name) { continue }
                let key = name.precomposedStringWithCanonicalMapping.lowercased()
                try require(folded.insert(key).inserted, .collision)
                try inspect(url)
                let relative = prefix + name
                try Self.relative(relative)
                let attrs = try FileManager.default.attributesOfItem(atPath: url.path)
                if attrs[.type] as? FileAttributeType == .typeDirectory { try visit(url, relative + "/") }
                else { result.append(relative) }
            }
        }
        try visit(root, "")
        return result.sorted()
    }
}

/// Local cooperative process exclusion only. Never a distributed fencing mechanism.
public final class InstanceLock {
    public enum Mode { case shared, exclusive }
    private let descriptor: Int32
    public convenience init(_ root: URL, mode: Mode = .exclusive, timeout: TimeInterval = 0, cancellation: CancellationToken? = nil) throws {
        try self.init(file: SafeFS.resolve(root, ".instance.lock"), mode: mode, timeout: timeout, cancellation: cancellation)
    }
    init(file: URL, mode: Mode = .exclusive, timeout: TimeInterval = 0, cancellation: CancellationToken? = nil) throws {
        try SafeFS.inspect(file)
        descriptor = open(file.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard descriptor >= 0 else { throw NASError.busy }
        var s = stat()
        guard fstat(descriptor, &s) == 0, s.st_nlink == 1, (s.st_mode & S_IFMT) == S_IFREG else {
            close(descriptor); throw NASError.unsafeFile
        }
        let deadline = ProcessInfo.processInfo.systemUptime + max(0, timeout)
        while flock(descriptor, (mode == .shared ? LOCK_SH : LOCK_EX) | LOCK_NB) != 0 {
            if cancellation?.isCancelled == true { close(descriptor); throw NASError.cancelled }
            if ProcessInfo.processInfo.systemUptime >= deadline { close(descriptor); throw timeout > 0 ? NASError.timedOut : NASError.busy }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if cancellation?.isCancelled == true { flock(descriptor, LOCK_UN); close(descriptor); throw NASError.cancelled }
    }
    deinit { flock(descriptor, LOCK_UN); close(descriptor) }
}
