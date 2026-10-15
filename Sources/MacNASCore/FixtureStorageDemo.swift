import Foundation

public struct FixtureStorageDemoReport: Codable {
    public let source: String
    public let boundState: FixtureVolumeState
    public let relativeFiles: [String]
    public let textBytes: Int
    public let readerDeniedBeforeGrant: Bool
    public let missingAfterDisconnect: Bool
    public let rebindRequiredAfterReturn: Bool
}

/// Creates new sample files only inside a synthetic instance's excluded host-binding directory.
public enum FixtureStorageDemo {
    public static func run(root: URL) throws -> FixtureStorageDemoReport {
        let api = try PrototypePlatformAPI(root: root)
        let owner = try api.beginFixtureSession(userID: "fixture-owner")
        let reader = try api.beginFixtureSession(userID: "fixture-family")
        guard let reference = api.fixtureVolumes.references.first else { throw NASError.invalidSchema }
        let observation = FixtureVolumeObservation(volumeID: reference.volumeID, displayName: "synthetic-only", authorized: true)
        try api.withManagedWrite {
            for relative in ["host-binding/fixtures", "host-binding/fixtures/volumes"] {
                let directory = try SafeFS.resolve(root, relative)
                if !FileManager.default.fileExists(atPath: directory.path) { try SafeFS.freshDirectory(directory) }
            }
            let mount = try SafeFS.resolve(root, "host-binding/fixtures/volumes/" + observation.mountID.uuidString.lowercased())
            try SafeFS.freshDirectory(mount)
            let library = try SafeFS.resolve(mount, reference.relativePath)
            try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
            try Data("MacNAS synthetic read-only text. No NAS data is connected.\n".utf8)
                .write(to: library.appendingPathComponent("README.txt"), options: .withoutOverwriting)
        }
        try api.updateFixtureVolumeInventory([observation], session: owner)
        let preview = try api.previewFixtureVolumeBinding(libraryID: reference.libraryID, access: .readOnly, session: owner)
        try api.commitFixtureVolumeBinding(preview, confirmed: true, session: owner)
        try api.authorizeFixtureLibraryContent(libraryID: reference.libraryID, session: owner)
        let state = try api.fixtureVolumeStatuses(session: owner)[0].state
        var deniedReader = false
        do { _ = try api.listFixtureLibrary(libraryID: reference.libraryID, session: reader) }
        catch NASError.denied { deniedReader = true }
        try require(deniedReader, .integrity)
        try api.setFixtureLibraryReaders(["fixture-family"], libraryID: reference.libraryID, session: owner)
        let files = try api.listFixtureLibrary(libraryID: reference.libraryID, session: reader)
        let text = try api.previewFixtureText(libraryID: reference.libraryID, relativePath: "README.txt", session: reader)
        try api.updateFixtureVolumeInventory([], session: owner)
        let missing = try api.fixtureVolumeStatuses(session: owner)[0].state == .missing
        try api.updateFixtureVolumeInventory([observation], session: owner)
        let rebind = try api.fixtureVolumeStatuses(session: owner)[0].state == .needsBinding
        try require(missing && rebind, .integrity)
        api.endSession(reader); api.endSession(owner)
        return FixtureStorageDemoReport(source: "synthetic", boundState: state,
            relativeFiles: files.map(\.relativePath), textBytes: text.utf8Bytes,
            readerDeniedBeforeGrant: deniedReader, missingAfterDisconnect: missing, rebindRequiredAfterReturn: rebind)
    }
}
