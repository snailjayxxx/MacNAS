import Foundation

extension PrototypePlatformAPI {
    /// Independent target-copy approval, granted only by the host. Upload and mutation approvals do not grant it.
    public func authorizeFixtureLibraryCopies(libraryID: String, session: PrototypeSession) throws {
        try withManagedWrite {
            let volumes = try checkedFixtureVolumes(), permit = try volumes.permit(libraryID: libraryID, user: user(session, administrator: true), access: .readWrite)
            _ = try fixtureContent.reader(permit)
            try volumes.validate(permit, user: user(session, administrator: true), access: .readWrite)
            try fixtureContent.approveCopies(permit)
        }
    }
    private func copyScope(_ intent: FixtureFileCopyIntent, session: PrototypeSession) throws -> (FileCopyScope, DescriptorLibrary, DescriptorLibrary) {
        let caller = try pageScope(session)
        try require(caller.role == "administrator" && caller.mode == "synthetic_development", .denied)
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        try require(identity.kind == "synthetic-prototype" && identity.schemaVersion == 1 && identity.instanceID == caller.instanceID && identity.generation >= 0, .denied)
        let volumes = try checkedFixtureVolumes(), sourcePermit = try volumes.permit(libraryID: intent.sourceLibraryID, user: user(session)), targetPermit = try volumes.permit(libraryID: intent.targetLibraryID, user: user(session, administrator: true), access: .readWrite)
        let source = try fixtureContent.reader(sourcePermit), (approval, target) = try fixtureContent.copyReader(targetPermit)
        func directory(_ permit: FixtureVolumePermit, _ reader: DescriptorLibrary, _ path: String) -> DirectoryPageScope {
            .init(caller: caller, libraryID: Data(permit.reference.libraryID.utf8), relativePath: Data(path.utf8), volumeID: permit.reference.volumeID,
                  mediaID: permit.observation.mediaID, mountID: permit.observation.mountID, approvalID: permit.approvalID, inventoryRevision: permit.revision, readerID: reader.identity)
        }
        return (.init(source: directory(sourcePermit, source, intent.sourcePath), target: directory(targetPermit, target, intent.parentPath), generation: identity.generation, copyApproval: approval), source, target)
    }
    private func validateCopyScope(_ scope: FileCopyScope, intent: FixtureFileCopyIntent, session: PrototypeSession) throws {
        try require(try copyScope(intent, session: session).0 == scope, .staleState)
    }
    private func validateCopyScope(_ scope: FileCopyScope, session: PrototypeSession) throws {
        // The target name is not part of authorization; reconstruct only the immutable library/path scope.
        let intent = try FixtureFileCopyIntent(sourceLibraryID: String(decoding: scope.source.libraryID, as: UTF8.self), sourcePath: String(decoding: scope.source.relativePath, as: UTF8.self),
            targetLibraryID: String(decoding: scope.target.libraryID, as: UTF8.self), parentPath: String(decoding: scope.target.relativePath, as: UTF8.self), name: "x")
        try validateCopyScope(scope, intent: intent, session: session)
    }
    private func withCopyWrite<T>(_ body: () throws -> T) throws -> T {
        try withManagedWrite {
            let serial = try InstanceLock(file: SafeFS.resolve(root, "host-binding/file-operations.lock"), timeout: 10)
            return try withExtendedLifetime(serial, body)
        }
    }
    public func previewFixtureFileCopy(_ intent: FixtureFileCopyIntent, session: PrototypeSession) throws -> FixtureFileCopyPreview {
        try withFixtureFileCopyPreview(intent, session: session) { $0 }
    }
    func withFixtureFileCopyPreview<T>(_ intent: FixtureFileCopyIntent, session: PrototypeSession, _ render: (FixtureFileCopyPreview) throws -> T) throws -> T {
        try withCopyWrite {
            let (scope, source, target) = try copyScope(intent, session: session)
            return try fileCopies.preview(intent: intent, scope: scope, source: source.transferDownload(relative: intent.sourcePath), target: target,
                validate: { try self.validateCopyScope(scope, intent: intent, session: session) }, render: render)
        }
    }
    public func beginFixtureFileCopy(copyID: String, confirmed: Bool, session: PrototypeSession) throws -> FixtureFileCopyStatus {
        try withCopyWrite {
            try fileCopies.begin(id: copyID, caller: pageScope(session), confirmed: confirmed, validate: { try self.validateCopyScope($0, session: session) }, staging: { plan in
                let host = try DescriptorLibrary(mountRoot: SafeFS.resolve(self.root, "host-binding"))
                return try host.transferStaging(id: copyID, targetDevice: plan.parent.device, prefix: "copy")
            })
        }
    }
    public func fixtureFileCopyChunk(copyID: String, offset: Int64, session: PrototypeSession) throws -> FixtureFileCopyStatus {
        try fixtureFileCopyChunk(copyID: copyID, offset: offset, session: session, afterPublication: {})
    }
    func fixtureFileCopyChunk(copyID: String, offset: Int64, session: PrototypeSession, afterPublication: () throws -> Void) throws -> FixtureFileCopyStatus {
        try require(offset >= 0 && offset <= FixtureTransferLimits.fileBytes, .invalidSchema)
        return try withCopyWrite { try fileCopies.chunk(id: copyID, offset: offset, caller: pageScope(session), validate: { try self.validateCopyScope($0, session: session) }, afterPublication: afterPublication) }
    }
    public func fixtureFileCopyStatus(copyID: String, session: PrototypeSession) throws -> FixtureFileCopyStatus {
        try fileCopies.status(id: copyID, caller: pageScope(session), validate: { try self.validateCopyScope($0, session: session) })
    }
    public func cancelFixtureFileCopy(copyID: String, session: PrototypeSession) throws -> FixtureFileCopyStatus {
        try fileCopies.cancel(id: copyID, caller: pageScope(session))
    }
}
