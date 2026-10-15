import Foundation

extension PrototypePlatformAPI {
    public func fixtureLibraries(session: PrototypeSession) throws -> [FixtureLibrarySummary] {
        let caller = try user(session)
        return try checkedFixtureVolumes().summaries(user: caller)
    }

    /// Explicit approval of content under the instance's own synthetic fixture directory, never a caller path.
    public func authorizeFixtureLibraryContent(libraryID: String, session: PrototypeSession) throws {
        _ = try user(session, administrator: true)
        try withManagedWrite {
            let caller = try user(session, administrator: true), volumes = try checkedFixtureVolumes()
            let permit = try volumes.permit(libraryID: libraryID, user: caller)
            let mount = try SafeFS.resolve(root, "host-binding/fixtures/volumes/" + permit.observation.mountID.uuidString.lowercased())
            let reader = try DescriptorLibrary(mountRoot: mount, relativeRoot: permit.reference.relativePath)
            try volumes.validate(permit, user: try user(session, administrator: true))
            fixtureContent.register(reader, permit: permit)
        }
    }
    private func readFixtureLibrary<T>(libraryID: String, session: PrototypeSession,
                                       _ body: (DescriptorLibrary) throws -> T) throws -> T {
        let caller = try user(session), volumes = try checkedFixtureVolumes()
        let permit = try volumes.permit(libraryID: libraryID, user: caller)
        let reader = try fixtureContent.reader(permit)
        let result = try body(reader)
        try checkedFixtureVolumes().validate(permit, user: try user(session))
        return result
    }
    public func listFixtureLibrary(libraryID: String, relativePath: String = "", maximumEntries: Int = 1000,
                                   session: PrototypeSession) throws -> [FixtureFileEntry] {
        try readFixtureLibrary(libraryID: libraryID, session: session) {
            try $0.list(relative: relativePath, maximumEntries: maximumEntries)
        }
    }
    public func previewFixtureText(libraryID: String, relativePath: String, maximumBytes: Int = 65536,
                                   session: PrototypeSession) throws -> FixtureTextPreview {
        try require((1...65536).contains(maximumBytes), .budgetExceeded)
        let allowed = Set(["txt", "md", "json", "csv", "log"])
        try require(allowed.contains((relativePath as NSString).pathExtension.lowercased()), .unsupported)
        return try readFixtureLibrary(libraryID: libraryID, session: session) { reader in
            let data = try reader.read(relative: relativePath, maximumBytes: maximumBytes)
            guard let text = String(data: data, encoding: .utf8) else { throw NASError.unsupported }
            return FixtureTextPreview(libraryID: libraryID, relativePath: relativePath, text: text, utf8Bytes: data.count)
        }
    }
}
