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
    public func fixtureLibraryPage(libraryID: String, relativePath: String="", pageSize: Int=50,
                                   cursor: String?=nil, session: PrototypeSession) throws -> FixtureDirectoryPage {
        try withFixtureLibraryPage(libraryID:libraryID,relativePath:relativePath,pageSize:pageSize,cursor:cursor,session:session) { $0 }
    }
    func withFixtureLibraryPage<T>(libraryID: String, relativePath: String, pageSize: Int, cursor: String?,
                                   session: PrototypeSession, _ render: (FixtureDirectoryPage) throws -> T) throws -> T {
        try require(!libraryID.isEmpty && libraryID.utf8.count<=128 && !libraryID.contains("\0"), .invalidSchema)
        if !relativePath.isEmpty { try SafeFS.relative(relativePath) }
        try require(relativePath.utf8.count<=4096 && relativePath.split(separator:"/").count<=128, .budgetExceeded)
        let caller=try pageScope(session), volumes=try checkedFixtureVolumes()
        let permit=try volumes.permit(libraryID:libraryID,user:try user(session)), reader=try fixtureContent.reader(permit)
        let scope=DirectoryPageScope(caller:caller,libraryID:Data(libraryID.utf8),relativePath:Data(relativePath.utf8),volumeID:permit.reference.volumeID,
            mediaID:permit.observation.mediaID,mountID:permit.observation.mountID,approvalID:permit.approvalID,inventoryRevision:permit.revision,readerID:reader.identity)
        return try directoryPages.page(scope:scope,size:pageSize,cursor:cursor,query: { after,stamp in
            try reader.page(relative:relativePath,after:after,expected:stamp,size:pageSize)
        },validate: { stamp in
            try require(try self.pageScope(session)==caller, .denied)
            try self.checkedFixtureVolumes().validate(permit,user:try self.user(session))
            try require(try self.fixtureContent.reader(permit).identity==reader.identity, .staleState)
            try reader.validatePage(stamp,relative:relativePath)
        },render:render)
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
