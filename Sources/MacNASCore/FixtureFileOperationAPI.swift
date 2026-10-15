import Foundation

extension PrototypePlatformAPI {
    /// Separate host-only write grant. Never exposed as a desktop message or inferred from read approval.
    public func authorizeFixtureLibraryMutations(libraryID:String,session:PrototypeSession) throws {
        try withManagedWrite {
            let caller=try user(session,administrator:true),volumes=try checkedFixtureVolumes()
            let permit=try volumes.permit(libraryID:libraryID,user:caller,access:.readWrite)
            _=try fixtureContent.reader(permit)
            try volumes.validate(permit,user:try user(session,administrator:true),access:.readWrite)
            try fixtureContent.approveMutations(permit)
        }
    }
    private func mutationScope(libraryID:String,parentPath:String,session:PrototypeSession) throws ->(FileOperationScope,DescriptorLibrary) {
        let caller=try pageScope(session)
        try require(caller.role=="administrator" && caller.mode=="synthetic_development",.denied)
        let identity=try PortableInstance.strictRead(InstanceIdentity.self,SafeFS.resolve(root,"instance.json"))
        try require(identity.kind=="synthetic-prototype" && identity.schemaVersion==1 && identity.instanceID==caller.instanceID && identity.generation>=0,.denied)
        let volumes=try checkedFixtureVolumes(),permit=try volumes.permit(libraryID:libraryID,user:try user(session,administrator:true),access:.readWrite)
        let (approval,reader)=try fixtureContent.mutationReader(permit)
        let directory=DirectoryPageScope(caller:caller,libraryID:Data(libraryID.utf8),relativePath:Data(parentPath.utf8),volumeID:permit.reference.volumeID,
            mediaID:permit.observation.mediaID,mountID:permit.observation.mountID,approvalID:permit.approvalID,inventoryRevision:permit.revision,readerID:reader.identity)
        return (FileOperationScope(directory:directory,generation:identity.generation,writeApproval:approval),reader)
    }
    private func validateMutationScope(_ scope:FileOperationScope,session:PrototypeSession) throws {
        let (current,_)=try mutationScope(libraryID:String(decoding:scope.directory.libraryID,as:UTF8.self),parentPath:String(decoding:scope.directory.relativePath,as:UTF8.self),session:session)
        try require(current==scope,.staleState)
    }
    public func previewFixtureFileOperation(_ intent:FixtureFileOperationIntent,session:PrototypeSession) throws ->FixtureFileOperationPreview {
        try withFixtureFileOperationPreview(intent,session:session){$0}
    }
    func withFixtureFileOperationPreview<T>(_ intent:FixtureFileOperationIntent,session:PrototypeSession,_ render:(FixtureFileOperationPreview)throws->T) throws ->T {
        try withManagedWrite {
            let serial=try InstanceLock(file:SafeFS.resolve(root,"host-binding/file-operations.lock"),timeout:10)
            return try withExtendedLifetime(serial) {
                let (scope,reader)=try mutationScope(libraryID:intent.libraryID,parentPath:intent.parentPath,session:session)
                return try fileOperations.preview(scope:scope,reader:reader,intent:intent,validate:{try self.validateMutationScope(scope,session:session)},render:render)
            }
        }
    }
    public func commitFixtureFileOperation(operationID:String,confirmed:Bool,session:PrototypeSession) throws ->FixtureFileOperationResult {
        try commitFixtureFileOperation(operationID:operationID,confirmed:confirmed,session:session,beforeMutation:nil,afterMutation:nil)
    }
    func commitFixtureFileOperation(operationID:String,confirmed:Bool,session:PrototypeSession,
                                    beforeMutation:(()throws->Void)?,afterMutation:(()throws->Void)?) throws ->FixtureFileOperationResult {
        try Self.operationID(operationID)
        return try withManagedWrite {
            let serial=try InstanceLock(file:SafeFS.resolve(root,"host-binding/file-operations.lock"),timeout:10)
            return try withExtendedLifetime(serial) {
                let caller=try pageScope(session)
                return try fileOperations.commit(id:operationID,caller:caller,confirmed:confirmed,validate:{try self.validateMutationScope($0,session:session)},beforeMutation:beforeMutation,afterMutation:afterMutation)
            }
        }
    }
    public func fixtureFileOperationStatus(operationID:String,session:PrototypeSession) throws ->FixtureFileOperationResult {
        try Self.operationID(operationID)
        return try fileOperations.status(id:operationID,caller:pageScope(session),validate:{try self.validateMutationScope($0,session:session)})
    }
    private static func operationID(_ value:String) throws {try require(value.utf8.count==36 && UUID(uuidString:value)?.uuidString.lowercased()==value,.invalidSchema)}
}
