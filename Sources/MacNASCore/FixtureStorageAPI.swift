import Foundation

extension PrototypePlatformAPI {
    func checkedFixtureVolumes() throws -> FixtureVolumeRegistry {
        let references = try PortableInstance.strictRead([VolumeReference].self, SafeFS.resolve(root, "logical-storage/references.json"))
        try require(references == fixtureVolumes.references, .staleState)
        return fixtureVolumes
    }
    public func fixtureVolumeStatuses(session: PrototypeSession) throws -> [FixtureVolumeStatus] {
        _ = try user(session, administrator: true)
        return try checkedFixtureVolumes().statuses()
    }
    public func updateFixtureVolumeInventory(_ observations: [FixtureVolumeObservation], session: PrototypeSession) throws {
        _ = try user(session, administrator: true)
        try withManagedWrite {
            _ = try user(session, administrator: true)
            try checkedFixtureVolumes().update(observations)
        }
    }
    public func previewFixtureVolumeBinding(libraryID: String, access: FixtureVolumeAccess,
                                           session: PrototypeSession) throws -> FixtureVolumePreview {
        _ = try user(session, administrator: true)
        return try checkedFixtureVolumes().preview(libraryID: libraryID, access: access, caller: session.id)
    }
    public func commitFixtureVolumeBinding(_ preview: FixtureVolumePreview, confirmed: Bool, session: PrototypeSession) throws {
        _ = try user(session, administrator: true)
        try withManagedWrite {
            _ = try user(session, administrator: true)
            try checkedFixtureVolumes().commit(preview, caller: session.id, confirmed: confirmed)
        }
    }
    public func revokeFixtureVolumeBinding(libraryID: String, session: PrototypeSession) throws {
        _ = try user(session, administrator: true)
        try withManagedWrite {
            _ = try user(session, administrator: true)
            try checkedFixtureVolumes().revoke(libraryID: libraryID)
            fixtureContent.revoke(libraryID)
        }
    }
    public func setFixtureLibraryReaders(_ users: Set<String>, libraryID: String, session: PrototypeSession) throws {
        _ = try user(session, administrator: true)
        try withManagedWrite {
            _ = try user(session, administrator: true)
            let configured = try PortableInstance.strictRead(PortableConfig.self, SafeFS.resolve(root, "config/platform.json"))
            try require(users.isSubset(of: Set(configured.users.map(\.id))), .denied)
            try checkedFixtureVolumes().setReaders(users, libraryID: libraryID)
        }
    }
}
