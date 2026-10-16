import Foundation
import Darwin
import CryptoKit

enum TransferIO {
    static func attributes(_ fd: Int32) throws -> stat {
        var value = stat(); try require(fstat(fd, &value) == 0, .unsafeFile); return value
    }
    static func sameNode(_ a: stat, _ b: stat) -> Bool {
        a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_mode == b.st_mode && a.st_nlink == b.st_nlink
    }
}

/// Owns only one random, exclusive staging file. Never removes a replaced name or a published target.
final class TransferStaging {
    let directory: Int32
    let file: Int32
    let name: String
    private let validateDirectory: () throws -> Void
    private var stamp: DirectoryStamp
    private(set) var published = false
    init(directory: Int32, file: Int32, name: String, validate: @escaping () throws -> Void) throws {
        self.directory = directory; self.file = file; self.name = name; self.validateDirectory = validate
        stamp = DirectoryStamp(try TransferIO.attributes(file))
    }
    deinit {
        if !published {
            var named = stat()
            if (try? validateDirectory()) != nil, fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0,
               let current = try? TransferIO.attributes(file), TransferIO.sameNode(named, current) {
                _ = unlinkat(directory, name, 0)
            }
        }
        close(file); close(directory)
    }
    func validate() throws {
        try validateDirectory()
        let current = try TransferIO.attributes(file); var named = stat()
        try require(fstatat(directory, name, &named, AT_SYMLINK_NOFOLLOW) == 0, .staleState)
        try require(DirectoryStamp(current) == stamp && TransferIO.sameNode(current, named)
                    && current.st_nlink == 1 && (current.st_mode & S_IFMT) == S_IFREG, .staleState)
    }
    func append(_ data: Data, offset: Int64,
                writer: (Int32, UnsafeRawPointer, Int, off_t) -> Int = { pwrite($0, $1, $2, $3) }) throws {
        try validate(); try require(stamp.size == offset, .staleState)
        try data.withUnsafeBytes { bytes in
            var written = 0
            while written < data.count {
                let count = writer(file, bytes.baseAddress!.advanced(by: written), data.count - written, off_t(offset) + off_t(written))
                if count < 0 && errno == EINTR { continue }
                try require(count > 0 && count <= data.count - written, .unsafeFile); written += count
            }
        }
        let current = try TransferIO.attributes(file)
        try require(current.st_size == offset + Int64(data.count) && current.st_nlink == 1, .staleState)
        stamp = DirectoryStamp(current); try validate()
    }
    func digest(bytes: Int64, checkDeadline: () throws -> Void) throws -> String {
        try validate(); try require(bytes == stamp.size && bytes <= FixtureTransferLimits.fileBytes, .integrity)
        var hash = SHA256(), offset: Int64 = 0
        while offset < bytes {
            try checkDeadline()
            var data = Data(count: Int(min(Int64(FixtureTransferLimits.chunkBytes), bytes-offset)))
            try data.withUnsafeMutableBytes { buffer in
                var loaded = 0
                while loaded < buffer.count {
                    try checkDeadline()
                    let count = pread(file, buffer.baseAddress!.advanced(by:loaded), buffer.count-loaded, off_t(offset)+off_t(loaded))
                    if count < 0 && errno == EINTR { continue }
                    try require(count > 0 && count <= buffer.count-loaded, .unsafeFile); loaded += count
                }
            }
            hash.update(data:data); offset += Int64(data.count)
        }
        try validate();try checkDeadline();return TransferEncoding.digest(hash)
    }
    func publish(to plan: DescriptorMutation, validate: () throws -> Void,
                 afterPublication: () throws -> Void = {}) throws {
        try self.validate(); try validate()
        try require(stamp.device == plan.parent.device, .unsupported)
        try require(fsync(file) == 0, .unsafeFile)
        try self.validate(); try validate()
        let result = renameatx_np(directory, name, plan.descriptor, plan.intent.name, UInt32(RENAME_EXCL))
        if result != 0 {
            if errno == EEXIST || errno == ENOTEMPTY { throw NASError.collision }
            if errno == EXDEV || errno == ENOTSUP { throw NASError.unsupported }
            throw NASError.unsafeFile
        }
        published = true
        // rename changes ctime. Capture that expected transition before any post-publication work,
        // then require the complete stamp to stay fixed (including ctime after a restored-mtime rewrite).
        let publishedStamp = DirectoryStamp(try TransferIO.attributes(file))
        try validatePublished(plan, expected: publishedStamp)
        try afterPublication()
        try validatePublished(plan, expected: publishedStamp)
        try require(fsync(plan.descriptor) == 0 && fsync(directory) == 0, .unsafeFile)
        try validatePublished(plan, expected: publishedStamp)
    }
    private func validatePublished(_ plan: DescriptorMutation, expected: DirectoryStamp) throws {
        var target = stat(); let current = try TransferIO.attributes(file)
        let observed = DirectoryStamp(current)
        try require(fstatat(plan.descriptor, plan.intent.name, &target, AT_SYMLINK_NOFOLLOW) == 0
                    && DirectoryStamp(target) == observed && observed == expected
                    && observed.device == stamp.device && observed.inode == stamp.inode
                    && observed.mode == stamp.mode && observed.links == stamp.links && observed.size == stamp.size
                    && observed.modifiedSeconds == stamp.modifiedSeconds && observed.modifiedNanos == stamp.modifiedNanos, .staleState)
        // The first check still matches all content/identity fields from private staging; only rename's ctime transition is allowed.
    }
}

/// A pinned regular file; each read checks both its descriptor stamp and its original name.
final class TransferDownload {
    let bytes: Int64
    let device: dev_t
    private let file: Int32
    private let parent: Int32
    private let name: String
    private let stamp: DirectoryStamp
    private let validateDirectory: () throws -> Void
    init(file: Int32, parent: Int32, name: String, validate: @escaping () throws -> Void) throws {
        let info = try TransferIO.attributes(file)
        try require((info.st_mode & S_IFMT) == S_IFREG && info.st_nlink == 1 && info.st_size >= 0, .unsafeFile)
        self.file = file; self.parent = parent; self.name = name; self.validateDirectory = validate
        stamp = DirectoryStamp(info); bytes = Int64(info.st_size); device = info.st_dev
    }
    deinit { close(file); close(parent) }
    func validate() throws {
        try validateDirectory(); var named = stat()
        try require(fstatat(parent, name, &named, AT_SYMLINK_NOFOLLOW) == 0, .staleState)
        try require(DirectoryStamp(try TransferIO.attributes(file)) == stamp && DirectoryStamp(named) == stamp, .staleState)
    }
    func read(offset: Int64, maximum: Int) throws -> Data {
        try require(offset >= 0 && offset <= bytes && (1...32768).contains(maximum), .invalidSchema)
        try validate(); let size = min(Int64(maximum), bytes - offset)
        var data = Data(count: Int(size))
        try data.withUnsafeMutableBytes { buffer in
            var loaded = 0
            while loaded < buffer.count {
                let count = pread(file, buffer.baseAddress!.advanced(by: loaded), buffer.count - loaded, off_t(offset) + off_t(loaded))
                if count < 0 && errno == EINTR { continue }
                try require(count > 0 && count <= buffer.count - loaded, .unsafeFile); loaded += count
            }
        }
        try validate(); return data
    }
}
