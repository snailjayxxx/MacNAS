import Foundation
import XCTest
import Darwin
@testable import MacNASCore

final class DescriptorLibraryTests: LabTest {
    func directory() throws -> URL {
        let root = child("library"); try SafeFS.freshDirectory(root); return root
    }
    func write(_ name: String, in root: URL, text: String = "synthetic") throws {
        try Data(text.utf8).write(to: root.appendingPathComponent(name))
    }
    func testRepeatedListingUsesIndependentOffsetsAndKeepsUnicodeRelativeNames() throws {
        let root = try directory()
        try write("写真.txt", in: root)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("子目录"), withIntermediateDirectories: false)
        try write("メモ.md", in: root.appendingPathComponent("子目录"))
        let reader = try DescriptorLibrary(mountRoot: root)
        let first = try reader.list()
        XCTAssertEqual(first, try reader.list())
        XCTAssertEqual(Set(first.map(\.name)), ["写真.txt", "子目录"])
        XCTAssertEqual(try reader.list(relative: "子目录").map(\.relativePath), ["子目录/メモ.md"])
        XCTAssertEqual(try reader.read(relative: "子目录/メモ.md"), Data("synthetic".utf8))
        XCTAssertFalse(String(decoding: try JSONEncoder().encode(first), as: UTF8.self).contains(root.path))
    }
    func testMissingRootAndMissingLibraryNeverCreateAPlaceholder() throws {
        denied(.unsafeFile) { _ = try DescriptorLibrary(mountRoot: child("absent")) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: child("absent").path))
        let root = try directory()
        denied(.unsafeFile) { _ = try DescriptorLibrary(mountRoot: root, relativeRoot: "absent") }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent("absent").path))
    }
    func testSymlinkInRootOrParentIsRejected() throws {
        let root = try directory()
        try FileManager.default.createSymbolicLink(at: child("alias"), withDestinationURL: root)
        denied(.unsafeFile) { _ = try DescriptorLibrary(mountRoot: child("alias")) }
        try FileManager.default.createDirectory(at: root.appendingPathComponent("nested"), withIntermediateDirectories: false)
        denied(.unsafeFile) { _ = try DescriptorLibrary(mountRoot: child("alias/nested")) }
    }
    func testTraversalAbsoluteEmptyAndBackslashInputsAreRejected() throws {
        let reader = try DescriptorLibrary(mountRoot: directory())
        for path in ["../x", "/etc/passwd", "a/../../x", "a//b", "a/./b", "a\\b", "a\0b", "C:x"] {
            denied(.unsafePath) { _ = try reader.read(relative: path) }
            denied(.unsafePath) { _ = try reader.list(relative: path) }
        }
        denied(.unsafePath) { _ = try reader.read(relative: "") }
    }
    func testSymlinkFilesAndDirectoriesDoNotExposeOutsideData() throws {
        let root = try directory(), outside = child("outside.txt")
        try Data("must-not-return".utf8).write(to: outside)
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape.txt"), withDestinationURL: outside)
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.unsafeFile) { _ = try reader.read(relative: "escape.txt") }
        denied(.unsafeFile) { _ = try reader.list() }
        try FileManager.default.removeItem(at: root.appendingPathComponent("escape.txt"))
        try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("escape"), withDestinationURL: lab)
        denied(.unsafeFile) { _ = try reader.read(relative: "escape/outside.txt") }
    }
    func testHardLinksAndFIFOsAreRejectedWithoutBlocking() throws {
        let root = try directory(), original = child("outside.txt")
        try Data("synthetic".utf8).write(to: original)
        try FileManager.default.linkItem(at: original, to: root.appendingPathComponent("linked.txt"))
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.unsafeFile) { _ = try reader.read(relative: "linked.txt") }
        denied(.unsafeFile) { _ = try reader.list() }
        let fifo = root.appendingPathComponent("pipe.txt")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let start = ProcessInfo.processInfo.systemUptime
        denied(.unsafeFile) { _ = try reader.read(relative: "pipe.txt") }
        XCTAssertLessThan(ProcessInfo.processInfo.systemUptime - start, 1)
    }
    func testDirectoryAndContentBudgetsFailInsteadOfSilentlyTruncating() throws {
        let root = try directory(); try write("a.txt", in: root, text: "12345"); try write("b.txt", in: root)
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.budgetExceeded) { _ = try reader.list(maximumEntries: 1) }
        denied(.budgetExceeded) { _ = try reader.read(relative: "a.txt", maximumBytes: 4) }
        XCTAssertEqual(try reader.read(relative: "a.txt", maximumBytes: 5), Data("12345".utf8))
        for maximum in [0, -1, 1001] { denied(.budgetExceeded) { _ = try reader.list(maximumEntries: maximum) } }
        for maximum in [0, -1, 1_048_577] { denied(.budgetExceeded) { _ = try reader.read(relative: "a.txt", maximumBytes: maximum) } }
    }
    func testRootDirectoryReplacementInvalidatesPinnedReader() throws {
        let root = try directory(); try write("a.txt", in: root)
        let reader = try DescriptorLibrary(mountRoot: root)
        try FileManager.default.moveItem(at: root, to: child("retained-original"))
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
        try write("a.txt", in: root, text: "replacement")
        denied(.staleState) { _ = try reader.read(relative: "a.txt") }
        denied(.staleState) { _ = try reader.list() }
    }
    func testReplacementAfterOpenDoesNotFollowNewSymlink() throws {
        let root = try directory(); try write("a.txt", in: root)
        let outside = child("outside.txt"); try Data("outside-data".utf8).write(to: outside)
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.staleState) {
            _ = try reader.read(relative: "a.txt", afterOpen: {
                try FileManager.default.moveItem(at: root.appendingPathComponent("a.txt"), to: root.appendingPathComponent("retained.txt"))
                try FileManager.default.createSymbolicLink(at: root.appendingPathComponent("a.txt"), withDestinationURL: outside)
            })
        }
    }
    func testDirectoryReplacementAfterOpenDoesNotRedirectReader() throws {
        let root = try directory(), folder = root.appendingPathComponent("folder")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false); try write("a.txt", in: folder)
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.unsafeFile) {
            _ = try reader.read(relative: "folder/a.txt", afterOpen: {
                try FileManager.default.moveItem(at: folder, to: root.appendingPathComponent("old-folder"))
                try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: self.lab)
            })
        }
    }
    func testConcurrentContentChangeIsRejected() throws {
        let root = try directory(); try write("a.txt", in: root, text: "original")
        let reader = try DescriptorLibrary(mountRoot: root)
        denied(.staleState) {
            _ = try reader.read(relative: "a.txt", afterOpen: { try self.write("a.txt", in: root, text: "changed-length") })
        }
    }
    func testCaseAndCanonicalUnicodeCollisionsAreRejectedOnAnyFilesystem() throws {
        denied(.collision) { try DescriptorLibrary.checkNames(["Name.txt", "name.txt"]) }
        denied(.collision) { try DescriptorLibrary.checkNames(["caf\u{00e9}.txt", "cafe\u{0301}.txt"]) }
        try DescriptorLibrary.checkNames(["中文.txt", "日本語.txt"])
    }
}

final class FixtureFileAPITests: LabTest {
    struct Context {
        let api: PrototypePlatformAPI
        let owner: PrototypeSession
        let reader: PrototypeSession
        let reference: VolumeReference
        let observation: FixtureVolumeObservation
        let mount: URL
        let library: URL
    }
    func context() throws -> Context {
        let api = try PrototypePlatformAPI(root: source())
        let owner = try api.beginFixtureSession(userID: "fixture-owner"), reader = try api.beginFixtureSession(userID: "fixture-family")
        let reference = try XCTUnwrap(api.fixtureVolumes.references.first)
        let observation = FixtureVolumeObservation(volumeID: reference.volumeID, displayName: "synthetic-mount", authorized: true)
        let mount = api.root.appendingPathComponent("host-binding/fixtures/volumes/" + observation.mountID.uuidString.lowercased())
        let library = mount.appendingPathComponent(reference.relativePath)
        try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
        try Data("合成文本 <script>example</script>".utf8).write(to: library.appendingPathComponent("メモ.txt"))
        try api.updateFixtureVolumeInventory([observation], session: owner)
        let preview = try api.previewFixtureVolumeBinding(libraryID: reference.libraryID, access: .readOnly, session: owner)
        try api.commitFixtureVolumeBinding(preview, confirmed: true, session: owner)
        return Context(api: api, owner: owner, reader: reader, reference: reference, observation: observation, mount: mount, library: library)
    }
    func testContentNeedsExplicitRootApprovalAndEveryReaderNeedsItsOwnScope() throws {
        let c = try context(), id = c.reference.libraryID
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.reader) }
        denied(.denied) { try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.reader) }
        try c.api.setFixtureLibraryReaders(["fixture-family"], libraryID: id, session: c.owner)
        XCTAssertEqual(try c.api.listFixtureLibrary(libraryID: id, session: c.reader).map(\.relativePath), ["メモ.txt"])
        let preview = try c.api.previewFixtureText(libraryID: id, relativePath: "メモ.txt", session: c.reader)
        XCTAssertEqual(preview.text, "合成文本 <script>example</script>")
        XCTAssertEqual(preview.utf8Bytes, preview.text.utf8.count)
        try c.api.setFixtureLibraryReaders([], libraryID: id, session: c.owner)
        denied(.denied) { _ = try c.api.previewFixtureText(libraryID: id, relativePath: "メモ.txt", session: c.reader) }
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: "unknown", session: c.owner) }
    }
    func testEndedCrossInstanceAndRemovedUsersCannotReadPinnedContents() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        let otherRoot = child("second"); try PortableInstance.createSynthetic(at: otherRoot)
        let other = try PrototypePlatformAPI(root: otherRoot)
        denied(.denied) { _ = try other.listFixtureLibrary(libraryID: id, session: c.owner) }
        var config = try SafeFS.read(PortableConfig.self, SafeFS.resolve(c.api.root, "config/platform.json"))
        config.users.removeAll { $0.id == "fixture-owner" }
        try SafeFS.write(config, to: SafeFS.resolve(c.api.root, "config/platform.json"))
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        c.api.endSession(c.reader)
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.reader) }
    }
    func testUnplugRemountRebindAndRevocationInvalidateContentApproval() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        try c.api.updateFixtureVolumeInventory([], session: c.owner)
        denied(.missingVolume) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        try c.api.updateFixtureVolumeInventory([c.observation], session: c.owner)
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        let p = try c.api.previewFixtureVolumeBinding(libraryID: id, access: .readOnly, session: c.owner)
        try c.api.commitFixtureVolumeBinding(p, confirmed: true, session: c.owner)
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        try c.api.revokeFixtureVolumeBinding(libraryID: id, session: c.owner)
        denied(.denied) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
    }
    func testMissingMountAndReplacedDirectoryDoNotUsePlaceholders() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        try FileManager.default.moveItem(at: c.mount, to: c.mount.appendingPathExtension("retained"))
        denied(.unsafeFile) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: c.mount.path))
        try FileManager.default.createDirectory(at: c.library, withIntermediateDirectories: true)
        denied(.staleState) { _ = try c.api.listFixtureLibrary(libraryID: id, session: c.owner) }
    }
    func testPreviewAllowsOnlyBoundedUTF8TextAndNeverInterpretsMarkup() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        try Data([0xff, 0xfe]).write(to: c.library.appendingPathComponent("invalid.txt"))
        try Data("<html>example</html>".utf8).write(to: c.library.appendingPathComponent("page.html"))
        denied(.unsupported) { _ = try c.api.previewFixtureText(libraryID: id, relativePath: "invalid.txt", session: c.owner) }
        denied(.unsupported) { _ = try c.api.previewFixtureText(libraryID: id, relativePath: "page.html", session: c.owner) }
        denied(.budgetExceeded) { _ = try c.api.previewFixtureText(libraryID: id, relativePath: "メモ.txt", maximumBytes: 1, session: c.owner) }
        denied(.budgetExceeded) { _ = try c.api.previewFixtureText(libraryID: id, relativePath: "メモ.txt", maximumBytes: 65537, session: c.owner) }
    }
    func testReadOnlyModeCanReadExistingApprovalButCannotBroadenIt() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        var binding = try SafeFS.read(HostBinding.self, SafeFS.resolve(c.api.root, "host-binding/binding.json"))
        binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: SafeFS.resolve(c.api.root, "host-binding/binding.json"))
        XCTAssertEqual(try c.api.listFixtureLibrary(libraryID: id, session: c.owner).count, 1)
        denied(.denied) { try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner) }
        denied(.denied) { try c.api.setFixtureLibraryReaders(["fixture-family"], libraryID: id, session: c.owner) }
    }
    func testExportRestoreExcludesAllHostContentAndApprovalState() throws {
        let c = try context(), id = c.reference.libraryID
        try c.api.authorizeFixtureLibraryContent(libraryID: id, session: c.owner)
        try c.api.setFixtureLibraryReaders(["fixture-family"], libraryID: id, session: c.owner)
        let exported = child("portable"), restored = child("restored")
        try PortableInstance.export(from: c.api.root, to: exported)
        XCTAssertFalse(FileManager.default.fileExists(atPath: exported.appendingPathComponent("host-binding").path))
        try PortableInstance.restore(from: exported, to: restored, hostID: "new-fixture-host", confirmCreate: true)
        let next = try PrototypePlatformAPI(root: restored), owner = try next.beginFixtureSession(userID: "fixture-owner")
        XCTAssertEqual(next.fixtureVolumes.references, c.api.fixtureVolumes.references)
        denied(.missingVolume) { _ = try next.listFixtureLibrary(libraryID: id, session: owner) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: restored.appendingPathComponent("host-binding/fixtures").path))
        let restarted = try PrototypePlatformAPI(root: c.api.root), session = try restarted.beginFixtureSession(userID: "fixture-owner")
        denied(.missingVolume) { _ = try restarted.listFixtureLibrary(libraryID: id, session: session) }
    }
}
