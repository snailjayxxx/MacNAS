import Foundation
import XCTest
import Darwin
@testable import MacNASCore

final class DescriptorFileOperationTests:LabTest {
    func context() throws ->(URL,DescriptorLibrary) {
        let root=child("files");try SafeFS.freshDirectory(root);try Data("original".utf8).write(to:root.appendingPathComponent("source.txt"))
        return (root,try DescriptorLibrary(mountRoot:root))
    }
    func intent(_ name:String,source:String?=nil,parent:String="") throws ->FixtureFileOperationIntent {
        try .init(libraryID:"library",parentPath:parent,kind:source == nil ? .createDirectory:.rename,sourceName:source,name:name)
    }
    func testPreviewIsReadOnlyAndCreateUsesPrivateMode() throws {
        let (root,reader)=try context(),plan=try reader.prepareMutation(intent("新目录"))
        XCTAssertEqual(plan.state,"ready");XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("新目录").path))
        try reader.applyMutation(plan);XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("新目录").path))
        var info=stat();XCTAssertEqual(lstat(root.appendingPathComponent("新目录").path,&info),0);XCTAssertEqual(info.st_mode & 0o777,0o700)
    }
    func testRenamePreservesFileIdentityAndNestedDirectoryContent() throws {
        let (root,reader)=try context();try reader.applyMutation(reader.prepareMutation(intent("メモ.txt",source:"source.txt")))
        XCTAssertEqual(try reader.read(relative:"メモ.txt"),Data("original".utf8))
        try reader.applyMutation(reader.prepareMutation(intent("folder")))
        try Data("nested".utf8).write(to:root.appendingPathComponent("folder/note.txt"))
        try reader.applyMutation(reader.prepareMutation(intent("renamed",source:"folder")))
        XCTAssertEqual(try reader.read(relative:"renamed/note.txt"),Data("nested".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath:root.appendingPathComponent("source.txt").path))
    }
    func testConflictsUnchangedAndUnsafeNamesCannotOverwrite() throws {
        let (root,reader)=try context()
        XCTAssertEqual(try reader.prepareMutation(intent("SOURCE.TXT")).state,"conflict")
        XCTAssertEqual(try reader.prepareMutation(intent("source.txt",source:"source.txt")).state,"unchanged")
        for name in ["../bad","a/b","a\\b","C:x","\0bad",".","..",""] {XCTAssertThrowsError(try intent(name))}
        XCTAssertThrowsError(try intent(String(repeating:"x",count:256)))
        let plan=try reader.prepareMutation(intent("destination.txt",source:"source.txt"))
        try Data("retained".utf8).write(to:root.appendingPathComponent("destination.txt"))
        XCTAssertThrowsError(try reader.applyMutation(plan))
        XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("destination.txt")),Data("retained".utf8));XCTAssertEqual(try reader.read(relative:"source.txt"),Data("original".utf8))
    }
    func testSourceContentChangeAndParentReplacementFailBeforeMutation() throws {
        let (root,reader)=try context(),plan=try reader.prepareMutation(intent("new.txt",source:"source.txt"))
        try Data("modified".utf8).write(to:root.appendingPathComponent("source.txt"))
        XCTAssertThrowsError(try reader.applyMutation(plan)){XCTAssertEqual(($0 as? FileMutationFailure)?.applied,false)}
        let next=try reader.prepareMutation(intent("created"));try FileManager.default.moveItem(at:root,to:child("old"));try SafeFS.freshDirectory(root)
        XCTAssertThrowsError(try reader.applyMutation(next)){XCTAssertEqual(($0 as? FileMutationFailure)?.applied,false)}
        XCTAssertFalse(FileManager.default.fileExists(atPath:child("old/created").path))
    }
    func testUnsafeSiblingSymlinkHardlinkAndFIFORejectThePreview() throws {
        for type in ["symlink","hardlink","fifo"] {
            let root=child(type);try SafeFS.freshDirectory(root);let outside=child(type+"-outside");try Data("outside".utf8).write(to:outside)
            let bad=root.appendingPathComponent("bad")
            if type=="symlink" {try FileManager.default.createSymbolicLink(at:bad,withDestinationURL:outside)}
            else if type=="hardlink" {try FileManager.default.linkItem(at:outside,to:bad)} else {XCTAssertEqual(mkfifo(bad.path,0o600),0)}
            let reader=try DescriptorLibrary(mountRoot:root);denied(.unsafeFile){_ = try reader.prepareMutation(self.intent("new"))}
            XCTAssertEqual(try Data(contentsOf:outside),Data("outside".utf8))
        }
    }
    func testHooksProvePrecheckAndUncertainPostcheckWithoutRollback() throws {
        let (root,reader)=try context(),before=try reader.prepareMutation(intent("before"))
        XCTAssertThrowsError(try reader.applyMutation(before,beforeMutation:{try Data().write(to:root.appendingPathComponent("changed"))})){XCTAssertEqual(($0 as? FileMutationFailure)?.applied,false)}
        let after=try reader.prepareMutation(intent("after"))
        XCTAssertThrowsError(try reader.applyMutation(after,afterMutation:{throw NASError.denied})){XCTAssertEqual(($0 as? FileMutationFailure)?.applied,true)}
        XCTAssertTrue(FileManager.default.fileExists(atPath:root.appendingPathComponent("after").path))
    }
}

final class FileOperationRegistryTests:LabTest {
    func context() throws ->(DescriptorLibrary,FileOperationScope,FixtureFileOperationIntent) {
        let root=child("registry");try SafeFS.freshDirectory(root);let reader=try DescriptorLibrary(mountRoot:root)
        let caller=JobPageScope(sessionID:UUID(),instanceID:UUID(),databaseName:"fixture",userID:Data("owner".utf8),role:"administrator",mode:"synthetic_development")
        let directory=DirectoryPageScope(caller:caller,libraryID:Data("library".utf8),relativePath:Data(),volumeID:UUID(),mediaID:UUID(),mountID:UUID(),approvalID:UUID(),inventoryRevision:0,readerID:reader.identity)
        return(reader,FileOperationScope(directory:directory,generation:0,writeApproval:UUID()),try .init(libraryID:"library",kind:.createDirectory,name:"created"))
    }
    func testPreviewCapacityEncodingFailureExpiryAndBoundedResultVisibility() throws {
        let (reader,scope,intent)=try context();var time:TimeInterval=0;let registry=FileOperationRegistry(capacity:1,now:{time})
        denied(.budgetExceeded){_ = try registry.preview(scope:scope,reader:reader,intent:intent,validate:{},render:{_ ->Int in throw NASError.budgetExceeded})}
        let preview=try registry.preview(scope:scope,reader:reader,intent:intent,validate:{},render:{$0})
        denied(.budgetExceeded){_ = try registry.preview(scope:scope,reader:reader,intent:intent,validate:{},render:{$0})}
        time=30;let result=try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:true,validate:{_ in})
        XCTAssertEqual(result.state,"failed");XCTAssertEqual(result.error,"expired");XCTAssertTrue(try reader.list().isEmpty)
        time=331;XCTAssertEqual(try registry.status(id:preview.operationID,caller:scope.directory.caller,validate:{_ in}).state,"notVisible")
        denied(.replay){_ = try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:true,validate:{_ in})}
    }
    func testConfirmationIdempotencyAndLogoutNeverRepeatTheFilesystemAction() throws {
        let (reader,scope,intent)=try context(),registry=FileOperationRegistry()
        let preview=try registry.preview(scope:scope,reader:reader,intent:intent,validate:{},render:{$0})
        denied(.denied){_ = try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:false,validate:{_ in})}
        let first=try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:true,validate:{_ in})
        XCTAssertEqual(first.state,"completed")
        denied(.denied){_ = try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:true,validate:{_ in throw NASError.denied})}
        XCTAssertEqual(try registry.commit(id:preview.operationID,caller:scope.directory.caller,confirmed:true,validate:{_ in}).state,"completed")
        XCTAssertEqual(try reader.list().count,1);registry.endSession(scope.directory.caller.sessionID)
        XCTAssertEqual(try registry.status(id:preview.operationID,caller:scope.directory.caller,validate:{_ in}).state,"notVisible")
    }
}

class FileOperationLab:LabTest {
    struct Context {let api:PrototypePlatformAPI;let owner:PrototypeSession;let family:PrototypeSession;let reference:VolumeReference;let observation:FixtureVolumeObservation;let library:URL}
    func context(writeBinding:Bool=true,writeApproval:Bool=true) throws ->Context {
        let root=child("instance");try PortableInstance.createSynthetic(at:root,databaseVersion:3)
        let api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner"),family=try api.beginFixtureSession(userID:"fixture-family")
        let reference=try XCTUnwrap(api.fixtureVolumes.references.first),observation=FixtureVolumeObservation(volumeID:reference.volumeID,displayName:"synthetic",authorized:true)
        let library=root.appendingPathComponent("host-binding/fixtures/volumes/"+observation.mountID.uuidString.lowercased()).appendingPathComponent(reference.relativePath)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true);try Data("data".utf8).write(to:library.appendingPathComponent("a.txt"))
        try api.updateFixtureVolumeInventory([observation],session:owner)
        try api.commitFixtureVolumeBinding(api.previewFixtureVolumeBinding(libraryID:reference.libraryID,access:writeBinding ? .readWrite:.readOnly,session:owner),confirmed:true,session:owner)
        try api.authorizeFixtureLibraryContent(libraryID:reference.libraryID,session:owner)
        if writeApproval {try api.authorizeFixtureLibraryMutations(libraryID:reference.libraryID,session:owner)}
        return Context(api:api,owner:owner,family:family,reference:reference,observation:observation,library:library)
    }
    func intent(_ c:Context,_ name:String="created",source:String?=nil) throws ->FixtureFileOperationIntent {try .init(libraryID:c.reference.libraryID,kind:source == nil ? .createDirectory:.rename,sourceName:source,name:name)}
}
final class FixtureFileOperationAPITests:FileOperationLab {
    func testReadApprovalAndReadOnlyBindingNeverImplicitlyGrantWrites() throws {
        let c=try context(writeApproval:false)
        denied(.denied){_ = try c.api.previewFixtureFileOperation(self.intent(c),session:c.owner)}
        denied(.denied){try c.api.authorizeFixtureLibraryMutations(libraryID:c.reference.libraryID,session:c.family)}
        try c.api.authorizeFixtureLibraryMutations(libraryID:c.reference.libraryID,session:c.owner)
        let preview=try c.api.previewFixtureFileOperation(intent(c),session:c.owner)
        XCTAssertEqual(try c.api.fixtureFileOperationStatus(operationID:preview.operationID,session:c.family).state,"notVisible")
        denied(.denied){_ = try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.family)}
        XCTAssertEqual(try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.owner).state,"completed")
    }
    func testSameHostResultQueryIsIdempotentButNewHostHasNoReceiptOrApproval() throws {
        let c=try context(),preview=try c.api.previewFixtureFileOperation(intent(c,"renamed.txt",source:"a.txt"),session:c.owner)
        let result=try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.owner)
        XCTAssertEqual(result.state,"completed");XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("renamed.txt")),Data("data".utf8))
        XCTAssertEqual(try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.owner).state,"completed")
        let next=try PrototypePlatformAPI(root:c.api.root),session=try next.beginFixtureSession(userID:"fixture-owner")
        XCTAssertEqual(try next.fixtureFileOperationStatus(operationID:preview.operationID,session:session).state,"notVisible")
        c.api.endSession(c.owner);denied(.denied){_ = try c.api.fixtureFileOperationStatus(operationID:preview.operationID,session:c.owner)}
    }
    func testReadOnlyVolumeBindingRequiresASeparateExplicitReadWriteBinding() throws {
        let c=try context(writeBinding:false,writeApproval:false)
        denied(.denied){try c.api.authorizeFixtureLibraryMutations(libraryID:c.reference.libraryID,session:c.owner)}
        XCTAssertEqual(try c.api.listFixtureLibrary(libraryID:c.reference.libraryID,session:c.owner).count,1)
    }
    func testReapprovalVolumeRevisionAndGenerationInvalidatePreparedPlans() throws {
        let c=try context(),preview=try c.api.previewFixtureFileOperation(intent(c),session:c.owner)
        try c.api.authorizeFixtureLibraryContent(libraryID:c.reference.libraryID,session:c.owner)
        let refused=try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.owner)
        XCTAssertEqual(refused.state,"failed");XCTAssertFalse(FileManager.default.fileExists(atPath:c.library.appendingPathComponent("created").path))
        try c.api.authorizeFixtureLibraryMutations(libraryID:c.reference.libraryID,session:c.owner)
        let second=try c.api.previewFixtureFileOperation(intent(c),session:c.owner)
        var identity=try SafeFS.read(InstanceIdentity.self,SafeFS.resolve(c.api.root,"instance.json"));identity.generation+=1
        try SafeFS.write(identity,to:SafeFS.resolve(c.api.root,"instance.json"))
        XCTAssertEqual(try c.api.commitFixtureFileOperation(operationID:second.operationID,confirmed:true,session:c.owner).state,"failed")
    }
    func testRecoveryAndMissingVolumeRefuseAndPostMutationRevocationIsUncertain() throws {
        let c=try context(),preview=try c.api.previewFixtureFileOperation(intent(c),session:c.owner)
        let uncertain=try c.api.commitFixtureFileOperation(operationID:preview.operationID,confirmed:true,session:c.owner,beforeMutation:nil,afterMutation:{try c.api.fixtureVolumes.revoke(libraryID:c.reference.libraryID)})
        XCTAssertEqual(uncertain.state,"uncertain");XCTAssertTrue(FileManager.default.fileExists(atPath:c.library.appendingPathComponent("created").path))
        var binding=try SafeFS.read(HostBinding.self,SafeFS.resolve(c.api.root,"host-binding/binding.json"));binding.mode="read_only_recovery";try SafeFS.write(binding,to:SafeFS.resolve(c.api.root,"host-binding/binding.json"))
        denied(.denied){_ = try c.api.previewFixtureFileOperation(self.intent(c,"later"),session:c.owner)}
    }
    func testStrictWireAndPreviewEncodingFailureHaveNoFilesystemEffect() throws {
        let c=try context(),host=try DesktopBridge(api:c.api,session:c.owner)
        func request(_ method:String,_ params:[String:Any],_ bridge:DesktopBridge) throws ->[String:Any] {
            let bytes=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":method,"params":params])
            return try XCTUnwrap(JSONSerialization.jsonObject(with:bridge.handle(bytes)) as? [String:Any])
        }
        let params:[String:Any]=["libraryID":c.reference.libraryID,"kind":"createDirectory","name":"new"]
        let reply=try request("previewFileOperation",params,host),preview=try XCTUnwrap(reply["data"] as? [String:Any])
        XCTAssertEqual(Set(preview.keys),["previewVersion","operationID","intent","state","expiresInSeconds"])
        let id=try XCTUnwrap(preview["operationID"] as? String)
        let rejected=try request("commitFileOperation",["operationID":id,"confirmed":1],host);XCTAssertNotNil(rejected["error"])
        XCTAssertEqual((try request("commitFileOperation",["operationID":id,"confirmed":true],host)["data"] as? [String:Any])?["state"] as? String,"completed")
        var extra=params;extra["root"]="/tmp";XCTAssertNotNil(try request("previewFileOperation",extra,host)["error"])
        let small=try DesktopBridge(api:c.api,session:c.owner,limits:BridgeLimits(responseBytes:128));var blocked=params;blocked["name"]="blocked"
        XCTAssertNotNil(try request("previewFileOperation",blocked,small)["error"])
        XCTAssertTrue(FileManager.default.fileExists(atPath:c.library.appendingPathComponent("new").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath:c.library.appendingPathComponent("blocked").path))
    }
}

final class FileOperationPipeTests:FileOperationLab {
    func testActualClientPreviewCommitAndExplicitResultCheckMutateOnlyApprovedSyntheticFiles() throws {
        let c=try context(),host=try DesktopBridge(api:c.api,session:c.owner);defer{host.close()}
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"]))
        process.arguments=[repo.appendingPathComponent("scripts/test_file_operations_bridge.cjs").path,c.reference.libraryID]
        process.currentDirectoryURL=repo;process.environment=["LANG":"C","LC_ALL":"C","HOME":lab.path]
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global());timer.schedule(deadline:.now()+90)
        timer.setEventHandler{if process.isRunning{process.terminate()}};timer.resume()
        defer{timer.cancel();if process.isRunning{process.terminate()};try? input.fileHandleForWriting.close()}
        try process.run();var frame=Data(),requests=0
        while true {
            let block=output.fileHandleForReading.availableData;if block.isEmpty{break};frame.append(block);try require(frame.count<=65536,.budgetExceeded)
            while let end=frame.firstIndex(of:10) {
                requests+=1;try require(requests<=40,.budgetExceeded)
                let reply=host.handle(Data(frame[..<end]));frame.removeSubrange(...end)
                try input.fileHandleForWriting.write(contentsOf:reply+Data([10]))
            }
        }
        process.waitUntilExit();let diagnostics=try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertTrue(frame.isEmpty);XCTAssertEqual(process.terminationStatus,0,String(decoding:diagnostics,as:UTF8.self))
        XCTAssertGreaterThan(requests,10);XCTAssertTrue(String(decoding:diagnostics,as:UTF8.self).contains("file-operations-pipe: PASS"))
        XCTAssertEqual(Set(try FileManager.default.contentsOfDirectory(atPath:c.library.path)),["folder","renamed.txt","responseLost"])
        XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("renamed.txt")),Data("data".utf8))
    }
}
