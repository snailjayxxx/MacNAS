import Foundation
import XCTest
import Darwin
@testable import MacNASCore

class CopyLab: TransferLab {
    override func context() throws -> Context {
        let root = child("copy-" + UUID().uuidString); try SafeFS.freshDirectory(root)
        let library = root.appendingPathComponent("library"); try SafeFS.freshDirectory(library)
        let host = try DescriptorLibrary(mountRoot: root), reader = try DescriptorLibrary(mountRoot: library)
        let caller = JobPageScope(sessionID: UUID(), instanceID: UUID(), databaseName: "fixture", userID: Data("owner".utf8), role: "administrator", mode: "synthetic_development")
        let directory = DirectoryPageScope(caller: caller, libraryID: Data("library".utf8), relativePath: Data(), volumeID: UUID(), mediaID: UUID(), mountID: UUID(), approvalID: UUID(), inventoryRevision: 0, readerID: reader.identity)
        return .init(root: root, host: host, reader: reader, scope: .init(directory: directory, generation: 0, uploadApproval: nil))
    }
    func scope(_ c: Context) -> FileCopyScope { .init(source: c.scope.directory, target: c.scope.directory, generation: 0, copyApproval: UUID()) }
    func copyPreview(_ registry: FileCopyRegistry, _ c: Context, name: String = "copied.bin", source: String = "source.bin") throws -> FixtureFileCopyPreview {
        try registry.preview(intent: .init(sourceLibraryID: "library", sourcePath: source, targetLibraryID: "library", name: name), scope: scope(c),
            source: c.reader.transferDownload(relative: source), target: c.reader, validate: {}, render: { $0 })
    }
    @discardableResult func copyBegin(_ registry: FileCopyRegistry, _ c: Context, _ id: String) throws -> FixtureFileCopyStatus {
        try registry.begin(id: id, caller: c.scope.directory.caller, confirmed: true, validate: { _ in }, staging: { try c.host.transferStaging(id: id, targetDevice: $0.parent.device, prefix: "copy") })
    }
    @discardableResult func copyChunk(_ registry: FileCopyRegistry, _ c: Context, _ id: String, _ offset: Int64 = 0, after: () throws -> Void = {}) throws -> FixtureFileCopyStatus {
        try registry.chunk(id: id, offset: offset, caller: c.scope.directory.caller, validate: { _ in }, afterPublication: after)
    }
    func putSource(_ c: Context, _ data: Data = Data("data".utf8), name: String = "source.bin") throws {
        try data.write(to: c.root.appendingPathComponent("library/" + name))
    }
}

final class FileCopyRegistryTests: CopyLab {
    func testBinaryCopyProgressReplayAndSourcePreserved() throws {
        let c = try context(), registry = FileCopyRegistry(), data = Data((0..<70001).map { UInt8($0 % 251) })
        try putSource(c, data); let p = try copyPreview(registry, c, name: "中日-コピー.bin")
        XCTAssertEqual(p.state, "ready"); XCTAssertEqual(p.totalBytes, 70001)
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("library/中日-コピー.bin").path))
        XCTAssertEqual(try copyBegin(registry, c, p.copyID).copiedBytes, 0)
        denied(.replay) { _ = try self.copyChunk(registry, c, p.copyID, 1) }
        for start in stride(from: 0, to: data.count, by: 32768) {
            let result = try copyChunk(registry, c, p.copyID, Int64(start))
            XCTAssertEqual(result.copiedBytes, Int64(min(start + 32768, data.count)))
            XCTAssertEqual(try copyChunk(registry, c, p.copyID, Int64(start)).copiedBytes, result.copiedBytes)
        }
        let result = try registry.status(id: p.copyID, caller: c.scope.directory.caller, validate: { _ in })
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.sha256, TransferEncoding.digest(data))
        XCTAssertEqual(try copyBegin(registry, c, p.copyID).state, "completed")
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/中日-コピー.bin")), data)
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/source.bin")), data); XCTAssertEqual(try stageNames(c), [])
    }
    func testEmptySamePathConflictAndPreviewNeverWrite() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c, Data())
        let same = try copyPreview(registry, c, name: "source.bin")
        XCTAssertEqual(same.state, "unchanged"); XCTAssertEqual(same.expiresInSeconds, 0)
        denied(.replay) { _ = try self.copyBegin(registry, c, same.copyID) }
        try putSource(c, Data("keep".utf8), name: "conflict")
        XCTAssertEqual(try copyPreview(registry, c, name: "CONFLICT").state, "conflict")
        let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
        let result = try copyChunk(registry, c, p.copyID)
        XCTAssertEqual(result.state, "completed"); XCTAssertEqual(result.copiedBytes, 0); XCTAssertEqual(result.sha256, TransferEncoding.digest(Data()))
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/conflict")), Data("keep".utf8))
    }
    func testSourceContentChangeAndReplacementFailBeforePublication() throws {
        for replace in [false, true] {
            let c = try context(), registry = FileCopyRegistry(); try putSource(c, Data(repeating: 1, count: 40000))
            let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID); try copyChunk(registry, c, p.copyID)
            let file = c.root.appendingPathComponent("library/source.bin")
            if replace { try FileManager.default.moveItem(at: file, to: c.root.appendingPathComponent("retained-source")) }
            try Data(repeating: 2, count: 40000).write(to: file)
            XCTAssertEqual(try copyChunk(registry, c, p.copyID, 32768).state, "failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("library/copied.bin").path)); XCTAssertEqual(try stageNames(c), [])
            XCTAssertEqual(try Data(contentsOf: file), Data(repeating: 2, count: 40000))
        }
    }
    func testParentReplacementAndLateConflictNeverOverwrite() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c)
        let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
        try putSource(c, Data("keep".utf8), name: "copied.bin")
        XCTAssertEqual(try copyChunk(registry, c, p.copyID).state, "failed")
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/copied.bin")), Data("keep".utf8))
        let next = try copyPreview(registry, c, name: "new.bin"); try copyBegin(registry, c, next.copyID)
        try FileManager.default.moveItem(at: c.root.appendingPathComponent("library"), to: c.root.appendingPathComponent("retained-library"))
        try SafeFS.freshDirectory(c.root.appendingPathComponent("library"))
        XCTAssertEqual(try copyChunk(registry, c, next.copyID).state, "failed"); XCTAssertEqual(try stageNames(c), [])
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.root.appendingPathComponent("retained-library/new.bin").path))
    }
    func testPostPublicationTargetOrSourceChangeIsUncertainAndNeverRolledBack() throws {
        for changeSource in [false, true] {
            let c = try context(), registry = FileCopyRegistry(); try putSource(c)
            let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
            let result = try copyChunk(registry, c, p.copyID, after: {
                let path = changeSource ? "source.bin" : "copied.bin"
                let fd = open(c.root.appendingPathComponent("library/" + path).path, O_WRONLY | O_NOFOLLOW)
                try require(fd >= 0, .unsafeFile); defer { close(fd) }
                try Data("evil".utf8).withUnsafeBytes { try require(pwrite(fd, $0.baseAddress, 4, 0) == 4, .unsafeFile) }
            })
            XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.copiedBytes, 4); XCTAssertNotNil(result.sha256)
            XCTAssertEqual(try registry.cancel(id: p.copyID, caller: c.scope.directory.caller).state, "uncertain")
            XCTAssertEqual(try copyChunk(registry, c, p.copyID).state, "uncertain")
            XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/copied.bin")), Data((changeSource ? "data" : "evil").utf8))
            XCTAssertEqual(try stageNames(c), [])
        }
    }
    func testPreviewEncodingFailureAndRenderTimeSourceChangeDoNotRegister() throws {
        let c = try context(), registry = FileCopyRegistry(capacity: 1); try putSource(c)
        let intent = try FixtureFileCopyIntent(sourceLibraryID: "library", sourcePath: "source.bin", targetLibraryID: "library", name: "copy")
        denied(.budgetExceeded) {
            _ = try registry.preview(intent: intent, scope: self.scope(c), source: c.reader.transferDownload(relative: "source.bin"), target: c.reader, validate: {}, render: { _ -> Int in throw NASError.budgetExceeded })
        }
        XCTAssertThrowsError(try registry.preview(intent: intent, scope: scope(c), source: c.reader.transferDownload(relative: "source.bin"), target: c.reader, validate: {}, render: { result in
            try self.putSource(c, Data("evil".utf8)); return result
        }))
        XCTAssertEqual(try copyPreview(registry, c).state, "ready")
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.root.appendingPathComponent("library").path), ["source.bin"])
    }
    func testCopyPublicationSameLengthRewriteWithRestoredMTimeIsUncertain() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c)
        let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
        let file = c.root.appendingPathComponent("library/copied.bin")
        let result = try copyChunk(registry, c, p.copyID, after: { try self.overwritePreservingModificationTime(file, data: Data("evil".utf8)) })
        XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.sha256, TransferEncoding.digest(Data("data".utf8)))
        XCTAssertEqual(try Data(contentsOf: file), Data("evil".utf8))
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/source.bin")), Data("data".utf8))
        XCTAssertEqual(try stageNames(c), [])
    }
    func testCapacityReservationExpirySessionCleanupAndBoundedReceipts() throws {
        let c = try context(); try putSource(c); var time: TimeInterval = 0
        let registry = FileCopyRegistry(capacity: 2, quota: 5, now: { time })
        let one = try copyPreview(registry, c, name: "one"), two = try copyPreview(registry, c, name: "two")
        denied(.budgetExceeded) { _ = try self.copyPreview(registry, c, name: "three") }
        try copyBegin(registry, c, one.copyID); XCTAssertEqual(try copyBegin(registry, c, two.copyID).error, "budgetExceeded")
        XCTAssertEqual(try registry.cancel(id: one.copyID, caller: c.scope.directory.caller).state, "cancelled"); XCTAssertEqual(try stageNames(c), [])
        let expiring = try copyPreview(registry, c); time = 30
        XCTAssertEqual(try registry.status(id: expiring.copyID, caller: c.scope.directory.caller, validate: { _ in }).error, "expired")
        let active = try copyPreview(registry, c); try copyBegin(registry, c, active.copyID)
        registry.endSession(c.scope.directory.caller.sessionID); XCTAssertEqual(try stageNames(c), [])
        XCTAssertEqual(try registry.status(id: active.copyID, caller: c.scope.directory.caller, validate: { _ in }).state, "notVisible")
        var first = ""
        for index in 0..<33 {
            let p = try copyPreview(registry, c, name: "cancel-\(index)"); if index == 0 { first = p.copyID }
            _ = try registry.cancel(id: p.copyID, caller: c.scope.directory.caller); time += 1
        }
        XCTAssertEqual(try registry.status(id: first, caller: c.scope.directory.caller, validate: { _ in }).state, "notVisible")
    }
    func testRevocationCleansPrivateStageAndForeignOwnerCannotObserveOrCancel() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c)
        let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
        let foreign = JobPageScope(sessionID: UUID(), instanceID: c.scope.directory.caller.instanceID, databaseName: "fixture", userID: Data("owner".utf8), role: "administrator", mode: "synthetic_development")
        XCTAssertEqual(try registry.status(id: p.copyID, caller: foreign, validate: { _ in }).state, "notVisible")
        denied(.denied) { _ = try registry.cancel(id: p.copyID, caller: foreign) }
        denied(.denied) { _ = try registry.chunk(id: p.copyID, offset: 0, caller: c.scope.directory.caller, validate: { _ in throw NASError.denied }) }
        XCTAssertEqual(try stageNames(c), []); XCTAssertEqual(try registry.cancel(id: p.copyID, caller: c.scope.directory.caller).state, "failed")
    }
    func testPublicationCrossingIdleOrAbsoluteDeadlineIsUncertainAndRetainsTarget() throws {
        for absolute in [false, true] {
            let c = try context(); var time: TimeInterval = 0
            let data = Data(repeating: 7, count: absolute ? 1048576 : 4), registry = FileCopyRegistry(now: { time })
            try putSource(c, data); let p = try copyPreview(registry, c); try copyBegin(registry, c, p.copyID)
            var offset: Int64 = 0
            if absolute {
                for index in 0..<31 {
                    time = Double(index + 1) * 57
                    offset = try XCTUnwrap(copyChunk(registry, c, p.copyID, offset).copiedBytes)
                }
                time = 1799
            }
            let result = try copyChunk(registry, c, p.copyID, offset, after: { time = absolute ? 1800 : 61 })
            XCTAssertEqual(result.state, "uncertain"); XCTAssertEqual(result.error, "expired")
            XCTAssertEqual(result.sha256, TransferEncoding.digest(data))
            XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/copied.bin")), data)
            XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/source.bin")), data)
        }
    }
    func testDifferentLibraryNamesAliasingSameRealFileRemainConflictWithoutCapability() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c)
        let intent = try FixtureFileCopyIntent(sourceLibraryID: "source-alias", sourcePath: "source.bin", targetLibraryID: "target-alias", name: "source.bin")
        let preview = try registry.preview(intent: intent, scope: scope(c), source: c.reader.transferDownload(relative: "source.bin"), target: c.reader, validate: {}, render: { $0 })
        XCTAssertEqual(preview.state, "conflict"); XCTAssertEqual(preview.expiresInSeconds, 0)
        denied(.replay) { _ = try self.copyBegin(registry, c, preview.copyID) }
        XCTAssertEqual(try Data(contentsOf: c.root.appendingPathComponent("library/source.bin")), Data("data".utf8))
    }
    func testOversizeAndUnsafeSourcesAndCrossDeviceStagingAreRejected() throws {
        let c = try context(), registry = FileCopyRegistry(); try putSource(c)
        let large = c.root.appendingPathComponent("library/large"), fd = open(large.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        try require(fd >= 0, .unsafeFile); defer { close(fd) }; XCTAssertEqual(ftruncate(fd, off_t(FixtureTransferLimits.fileBytes + 1)), 0)
        denied(.budgetExceeded) { _ = try self.copyPreview(registry, c, source: "large") }
        let p = try copyPreview(registry, c)
        let result = try registry.begin(id: p.copyID, caller: c.scope.directory.caller, confirmed: true, validate: { _ in }, staging: { try c.host.transferStaging(id: p.copyID, targetDevice: $0.parent.device &+ 1, prefix: "copy") })
        XCTAssertEqual(result.state, "failed"); XCTAssertEqual(result.error, "unsupported")
        try FileManager.default.createSymbolicLink(at: c.root.appendingPathComponent("library/link"), withDestinationURL: c.root.appendingPathComponent("library/source.bin"))
        XCTAssertThrowsError(try copyPreview(registry, c, source: "link")); XCTAssertThrowsError(try copyPreview(registry, c, source: "../source.bin"))
    }
}

final class FixtureFileCopyAPITests: FileOperationLab {
    func copyIntent(_ c: Context, _ name: String = "copy.txt") throws -> FixtureFileCopyIntent {
        try .init(sourceLibraryID: c.reference.libraryID, sourcePath: "a.txt", targetLibraryID: c.reference.libraryID, name: name)
    }
    func testIndependentCopyApprovalAndReadersCannotBorrowUploadOrMutationGrant() throws {
        let c = try context(); try c.api.authorizeFixtureLibraryUploads(libraryID: c.reference.libraryID, session: c.owner)
        denied(.denied) { _ = try c.api.previewFixtureFileCopy(self.copyIntent(c), session: c.owner) }
        denied(.denied) { try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.family) }
        try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.owner)
        let p = try c.api.previewFixtureFileCopy(copyIntent(c), session: c.owner)
        XCTAssertEqual(try c.api.fixtureFileCopyStatus(copyID: p.copyID, session: c.family).state, "notVisible")
        denied(.denied) { _ = try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: true, session: c.family) }
        denied(.denied) { _ = try c.api.cancelFixtureFileCopy(copyID: p.copyID, session: c.family) }
        denied(.denied) { _ = try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: false, session: c.owner) }
        XCTAssertEqual(try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: true, session: c.owner).state, "copying")
        XCTAssertEqual(try c.api.fixtureFileCopyChunk(copyID: p.copyID, offset: 0, session: c.owner).state, "completed")
        XCTAssertEqual(try Data(contentsOf: c.library.appendingPathComponent("a.txt")), Data("data".utf8))
    }
    func testReadOnlyBindingReapprovalRevocationAndGenerationChangeFailClosed() throws {
        let readOnly = try context(writeBinding: false, writeApproval: false)
        denied(.denied) { try readOnly.api.authorizeFixtureLibraryCopies(libraryID: readOnly.reference.libraryID, session: readOnly.owner) }
        for change in ["reapprove", "revoke", "generation"] {
            let c = try context(rootName: "instance-" + change); try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.owner)
            let p = try c.api.previewFixtureFileCopy(copyIntent(c), session: c.owner)
            _ = try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: true, session: c.owner)
            if change == "reapprove" { try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.owner) }
            else if change == "revoke" { try c.api.fixtureVolumes.revoke(libraryID: c.reference.libraryID) }
            else {
                var identity = try SafeFS.read(InstanceIdentity.self, SafeFS.resolve(c.api.root, "instance.json")); identity.generation += 1
                try SafeFS.write(identity, to: SafeFS.resolve(c.api.root, "instance.json"))
            }
            XCTAssertThrowsError(try c.api.fixtureFileCopyChunk(copyID: p.copyID, offset: 0, session: c.owner))
            XCTAssertEqual(try c.api.cancelFixtureFileCopy(copyID: p.copyID, session: c.owner).state, "failed")
            XCTAssertFalse(FileManager.default.fileExists(atPath: c.library.appendingPathComponent("copy.txt").path))
            XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.api.root.appendingPathComponent("host-binding/transfer-staging").path), [])
        }
    }
    func testHostRestartAndLogoutNeverResumeOrDeleteSource() throws {
        let c = try context(); try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.owner)
        let p = try c.api.previewFixtureFileCopy(copyIntent(c), session: c.owner)
        _ = try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: true, session: c.owner)
        let next = try PrototypePlatformAPI(root: c.api.root), owner = try next.beginFixtureSession(userID: "fixture-owner")
        XCTAssertEqual(try next.fixtureFileCopyStatus(copyID: p.copyID, session: owner).state, "notVisible")
        c.api.endSession(c.owner)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: c.api.root.appendingPathComponent("host-binding/transfer-staging").path), [])
        XCTAssertEqual(try Data(contentsOf: c.library.appendingPathComponent("a.txt")), Data("data".utf8))
    }
    func testStrictWireAndEncodingFailurePreserveOriginalCopyReceipt() throws {
        let c = try context(); try c.api.authorizeFixtureLibraryCopies(libraryID: c.reference.libraryID, session: c.owner)
        let bridge = try DesktopBridge(api: c.api, session: c.owner), small = try DesktopBridge(api: c.api, session: c.owner, limits: BridgeLimits(responseBytes: 128))
        func call(_ method: String, _ params: [String: Any], _ selected: DesktopBridge? = nil) throws -> [String: Any] {
            let host = selected ?? bridge
            let data = try JSONSerialization.data(withJSONObject: ["apiVersion": 1, "requestId": UUID().uuidString, "method": method, "params": params])
            return try XCTUnwrap(JSONSerialization.jsonObject(with: host.handle(data)) as? [String: Any])
        }
        let params: [String: Any] = ["sourceLibraryID": c.reference.libraryID, "sourcePath": "a.txt", "targetLibraryID": c.reference.libraryID, "name": "copy.txt"]
        for extra in [["root": "/tmp"], ["parentPath": NSNull()], ["overwrite": true]] as [[String: Any]] {
            var bad = params; bad.merge(extra) { _, v in v }; XCTAssertNotNil(try call("previewFileCopy", bad)["error"])
        }
        XCTAssertNotNil(try call("authorizeFixtureLibraryCopies", ["libraryID": c.reference.libraryID])["error"])
        XCTAssertNotNil(try call("previewFileCopy", params, small)["error"])
        let p = try c.api.previewFixtureFileCopy(copyIntent(c), session: c.owner)
        for confirmed in [false, 1, "true", NSNull()] as [Any] { XCTAssertNotNil(try call("beginFileCopy", ["copyID": p.copyID, "confirmed": confirmed])["error"]) }
        _ = try c.api.beginFixtureFileCopy(copyID: p.copyID, confirmed: true, session: c.owner)
        XCTAssertNotNil(try call("copyFileChunk", ["copyID": p.copyID, "offset": 0], small)["error"])
        XCTAssertEqual(try c.api.fixtureFileCopyStatus(copyID: p.copyID, session: c.owner).state, "completed")
        XCTAssertEqual(try c.api.fixtureFileCopyChunk(copyID: p.copyID, offset: 0, session: c.owner).state, "completed")
        let unknown = try XCTUnwrap(try call("fileCopyStatus", ["copyID": UUID().uuidString.lowercased()])["data"] as? [String: Any])
        XCTAssertEqual(unknown.count, 9)
        for field in ["intent", "totalBytes", "copiedBytes", "sha256", "error"] { XCTAssertTrue(unknown[field] is NSNull) }
        XCTAssertEqual(try Data(contentsOf: c.library.appendingPathComponent("copy.txt")), Data("data".utf8))
    }
}
