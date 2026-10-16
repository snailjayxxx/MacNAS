import Foundation

extension PrototypePlatformAPI {
    /// Host-only approval, distinct from content reads and mkdir/rename. No desktop RPC can grant this.
    public func authorizeFixtureLibraryUploads(libraryID: String, session: PrototypeSession) throws {
        try withManagedWrite {
            let volumes=try checkedFixtureVolumes(),permit=try volumes.permit(libraryID:libraryID,user:user(session,administrator:true),access:.readWrite)
            _=try fixtureContent.reader(permit)
            try volumes.validate(permit,user:user(session,administrator:true),access:.readWrite)
            try fixtureContent.approveUploads(permit)
        }
    }
    private func transferScope(libraryID: String, path: String, upload: Bool, session: PrototypeSession) throws -> (FileTransferScope,DescriptorLibrary) {
        try require(!libraryID.isEmpty && libraryID.utf8.count<=128 && !libraryID.contains("\0"),.invalidSchema)
        if !path.isEmpty {try SafeFS.relative(path)}
        try require(path.utf8.count<=4096 && path.split(separator:"/").count<=128,.budgetExceeded)
        let caller=try pageScope(session)
        if upload {try require(caller.role=="administrator" && caller.mode=="synthetic_development",.denied)}
        let identity=try PortableInstance.strictRead(InstanceIdentity.self,SafeFS.resolve(root,"instance.json"))
        try require(identity.kind=="synthetic-prototype" && identity.schemaVersion==1 && identity.instanceID==caller.instanceID && identity.generation>=0,.denied)
        let volumes=try checkedFixtureVolumes(),permit=try volumes.permit(libraryID:libraryID,user:user(session,administrator:upload),access:upload ? .readWrite:.readOnly)
        let reader:DescriptorLibrary,approval:UUID?
        if upload {let granted=try fixtureContent.uploadReader(permit);approval=granted.0;reader=granted.1}
        else {approval=nil;reader=try fixtureContent.reader(permit)}
        let directory=DirectoryPageScope(caller:caller,libraryID:Data(libraryID.utf8),relativePath:Data(path.utf8),volumeID:permit.reference.volumeID,
            mediaID:permit.observation.mediaID,mountID:permit.observation.mountID,approvalID:permit.approvalID,inventoryRevision:permit.revision,readerID:reader.identity)
        return (.init(directory:directory,generation:identity.generation,uploadApproval:approval),reader)
    }
    private func validateTransferScope(_ scope: FileTransferScope, session: PrototypeSession) throws {
        let current=try transferScope(libraryID:String(decoding:scope.directory.libraryID,as:UTF8.self),path:String(decoding:scope.directory.relativePath,as:UTF8.self),upload:scope.uploadApproval != nil,session:session).0
        try require(current==scope,.staleState)
    }
    private func withTransferWrite<T>(_ body: () throws -> T) throws -> T {
        try withManagedWrite {
            let serial=try InstanceLock(file:SafeFS.resolve(root,"host-binding/file-operations.lock"),timeout:10)
            return try withExtendedLifetime(serial,body)
        }
    }
    private func withTransferRead<T>(_ body: () throws -> T) throws -> T {
        let shared=try InstanceLock(root,mode:.shared,timeout:10)
        return try withExtendedLifetime(shared,body)
    }
    public func previewFixtureUpload(_ intent: FixtureUploadIntent, session: PrototypeSession) throws -> FixtureUploadPreview {
        try withFixtureUploadPreview(intent,session:session){$0}
    }
    func withFixtureUploadPreview<T>(_ intent: FixtureUploadIntent, session: PrototypeSession, _ render: (FixtureUploadPreview) throws -> T) throws -> T {
        try withTransferWrite {
            let (scope,reader)=try transferScope(libraryID:intent.libraryID,path:intent.parentPath,upload:true,session:session)
            return try fileTransfers.preview(intent:intent,scope:scope,reader:reader,validate:{try self.validateTransferScope(scope,session:session)},render:render)
        }
    }
    public func beginFixtureUpload(transferID: String, confirmed: Bool, session: PrototypeSession) throws -> FixtureTransferStatus {
        try withTransferWrite {
            try fileTransfers.beginUpload(id:transferID,caller:pageScope(session),confirmed:confirmed,validate:{try self.validateTransferScope($0,session:session)},staging:{plan in
                let host=try DescriptorLibrary(mountRoot:SafeFS.resolve(self.root,"host-binding"))
                return try host.transferStaging(id:transferID,targetDevice:plan.parent.device)
            })
        }
    }
    public func appendFixtureUpload(transferID: String, offset: Int64, parts: [String], session: PrototypeSession) throws -> FixtureTransferStatus {
        try require(offset>=0 && offset<=FixtureTransferLimits.fileBytes,.invalidSchema)
        return try withTransferWrite {try fileTransfers.append(id:transferID,offset:offset,parts:parts,caller:pageScope(session),validate:{try self.validateTransferScope($0,session:session)})}
    }
    public func finishFixtureUpload(transferID: String, sha256: String, session: PrototypeSession) throws -> FixtureTransferStatus {
        try finishFixtureUpload(transferID:transferID,sha256:sha256,session:session,afterPublication:{})
    }
    func finishFixtureUpload(transferID: String, sha256: String, session: PrototypeSession, afterPublication: () throws -> Void) throws -> FixtureTransferStatus {
        try withTransferWrite {try fileTransfers.finishUpload(id:transferID,expected:sha256,caller:pageScope(session),validate:{try self.validateTransferScope($0,session:session)},afterPublication:afterPublication)}
    }
    public func beginFixtureDownload(libraryID: String, relativePath: String, session: PrototypeSession) throws -> FixtureTransferStatus {
        try withFixtureDownload(libraryID:libraryID,relativePath:relativePath,session:session){$0}
    }
    func withFixtureDownload<T>(libraryID: String, relativePath: String, session: PrototypeSession, _ render: (FixtureTransferStatus) throws -> T) throws -> T {
        try withTransferRead {
            let (scope,reader)=try transferScope(libraryID:libraryID,path:relativePath,upload:false,session:session)
            return try fileTransfers.beginDownload(library:libraryID,path:relativePath,scope:scope,file:reader.transferDownload(relative:relativePath),validate:{try self.validateTransferScope(scope,session:session)},render:render)
        }
    }
    public func fixtureDownloadChunk(transferID: String, offset: Int64, session: PrototypeSession) throws -> FixtureDownloadChunk {
        try withFixtureDownloadChunk(transferID:transferID,offset:offset,session:session){$0}
    }
    func withFixtureDownloadChunk<T>(transferID: String, offset: Int64, session: PrototypeSession, _ render: (FixtureDownloadChunk) throws -> T) throws -> T {
        try require(offset>=0 && offset<=FixtureTransferLimits.fileBytes,.invalidSchema)
        return try withTransferRead {try fileTransfers.download(id:transferID,offset:offset,caller:pageScope(session),validate:{try self.validateTransferScope($0,session:session)},render:render)}
    }
    public func fixtureTransferStatus(transferID: String, session: PrototypeSession) throws -> FixtureTransferStatus {
        try withTransferRead {try fileTransfers.status(id:transferID,caller:pageScope(session),validate:{try self.validateTransferScope($0,session:session)})}
    }
    public func cancelFixtureTransfer(transferID: String, session: PrototypeSession) throws -> FixtureTransferStatus {
        try withTransferRead {try fileTransfers.cancel(id:transferID,caller:pageScope(session))}
    }
}
