import Foundation
import XCTest
import Darwin
@testable import MacNASCore

class TransferLab: LabTest {
    struct Context {let root:URL;let host:DescriptorLibrary;let reader:DescriptorLibrary;let scope:FileTransferScope}
    func context() throws -> Context {
        let root=child("transfer");try SafeFS.freshDirectory(root)
        let library=root.appendingPathComponent("library");try SafeFS.freshDirectory(library)
        let host=try DescriptorLibrary(mountRoot:root),reader=try DescriptorLibrary(mountRoot:library)
        let caller=JobPageScope(sessionID:UUID(),instanceID:UUID(),databaseName:"fixture",userID:Data("owner".utf8),role:"administrator",mode:"synthetic_development")
        let directory=DirectoryPageScope(caller:caller,libraryID:Data("library".utf8),relativePath:Data(),volumeID:UUID(),mediaID:UUID(),mountID:UUID(),approvalID:UUID(),inventoryRevision:0,readerID:reader.identity)
        return .init(root:root,host:host,reader:reader,scope:.init(directory:directory,generation:0,uploadApproval:UUID()))
    }
    func preview(_ registry:FileTransferRegistry,_ c:Context,_ name:String="uploaded.bin",_ bytes:Int64=4) throws -> FixtureUploadPreview {
        try registry.preview(intent:.init(libraryID:"library",name:name,totalBytes:bytes),scope:c.scope,reader:c.reader,validate:{},render:{$0})
    }
    @discardableResult func begin(_ registry:FileTransferRegistry,_ c:Context,_ id:String) throws ->FixtureTransferStatus {
        try registry.beginUpload(id:id,caller:c.scope.directory.caller,confirmed:true,validate:{_ in},staging:{try c.host.transferStaging(id:id,targetDevice:$0.parent.device)})
    }
    @discardableResult func append(_ registry:FileTransferRegistry,_ c:Context,_ id:String,_ data:Data,_ offset:Int64=0) throws ->FixtureTransferStatus {
        try registry.append(id:id,offset:offset,parts:TransferEncoding.parts(data),caller:c.scope.directory.caller,validate:{_ in})
    }
    func stageNames(_ c:Context) throws ->[String] {try FileManager.default.contentsOfDirectory(atPath:c.root.appendingPathComponent("transfer-staging").path)}
}

final class FileTransferRegistryTests:TransferLab {
    func testMultiblockUploadReplayAndDownloadHashesMatchBinaryBytes() throws {
        let c=try context(),registry=FileTransferRegistry(),data=Data((0..<70001).map{UInt8($0%251)})
        let p=try preview(registry,c,"中日-データ.bin",Int64(data.count));XCTAssertEqual(p.state,"ready")
        XCTAssertFalse(FileManager.default.fileExists(atPath:c.root.appendingPathComponent("library/中日-データ.bin").path))
        XCTAssertEqual(try begin(registry,c,p.transferID).state,"uploading")
        for start in stride(from:0,to:data.count,by:32768) {
            let block=data.subdata(in:start..<min(start+32768,data.count))
            XCTAssertEqual(try append(registry,c,p.transferID,block,Int64(start)).transferredBytes,Int64(start+block.count))
            XCTAssertEqual(try append(registry,c,p.transferID,block,Int64(start)).transferredBytes,Int64(start+block.count))
        }
        let digest=TransferEncoding.digest(data)
        XCTAssertEqual(try registry.finishUpload(id:p.transferID,expected:digest,caller:c.scope.directory.caller,validate:{_ in}).state,"completed")
        XCTAssertEqual(try registry.finishUpload(id:p.transferID,expected:digest,caller:c.scope.directory.caller,validate:{_ in}).state,"completed")
        XCTAssertEqual(try Data(contentsOf:c.root.appendingPathComponent("library/中日-データ.bin")),data);XCTAssertEqual(try stageNames(c),[])
        let d=try registry.beginDownload(library:"library",path:"中日-データ.bin",scope:c.scope,file:c.reader.transferDownload(relative:"中日-データ.bin"),validate:{},render:{$0})
        var loaded=Data(),offset:Int64=0
        repeat {
            let chunk=try registry.download(id:d.transferID,offset:offset,caller:c.scope.directory.caller,validate:{_ in},render:{$0})
            let block=try TransferEncoding.data(chunk.parts);XCTAssertEqual(chunk.chunkSHA256,TransferEncoding.digest(block));loaded.append(block)
            XCTAssertEqual(try registry.download(id:d.transferID,offset:offset,caller:c.scope.directory.caller,validate:{_ in},render:{$0}).nextOffset,chunk.nextOffset)
            offset=chunk.nextOffset;if chunk.eof {XCTAssertEqual(chunk.sha256,digest);break}
        } while true
        XCTAssertEqual(loaded,data)
    }
    func testEmptyFileAndStrictChunkEncodingWrongOffsetsDoNotAdvance() throws {
        let c=try context(),registry=FileTransferRegistry(),p=try preview(registry,c,"empty",0)
        try begin(registry,c,p.transferID)
        XCTAssertEqual(try registry.finishUpload(id:p.transferID,expected:TransferEncoding.digest(Data()),caller:c.scope.directory.caller,validate:{_ in}).state,"completed")
        let d=try registry.beginDownload(library:"library",path:"empty",scope:c.scope,file:c.reader.transferDownload(relative:"empty"),validate:{},render:{$0})
        let empty=try registry.download(id:d.transferID,offset:0,caller:c.scope.directory.caller,validate:{_ in},render:{$0})
        XCTAssertTrue(empty.eof);XCTAssertEqual(empty.parts,[]);XCTAssertEqual(empty.sha256,TransferEncoding.digest(Data()))
        for parts in [[],[""],["AA"],["YQ==","Yg=="],Array(repeating:"AA==",count:17)] {XCTAssertThrowsError(try TransferEncoding.data(parts))}
        let next=try preview(registry,c);try begin(registry,c,next.transferID)
        denied(.replay){_ = try self.append(registry,c,next.transferID,Data("data".utf8),1)}
        denied(.invalidSchema){_ = try self.append(registry,c,next.transferID,Data("x".utf8))}
        try append(registry,c,next.transferID,Data("data".utf8))
        denied(.collision){_ = try self.append(registry,c,next.transferID,Data("diff".utf8))}
        XCTAssertEqual(try registry.status(id:next.transferID,caller:c.scope.directory.caller,validate:{_ in}).transferredBytes,4)
    }
    func testPreviewEncodingFailureQuotasExpiryCancellationAndSessionCleanup() throws {
        let c=try context();var time:TimeInterval=0;let registry=FileTransferRegistry(capacity:2,quota:5,now:{time})
        denied(.budgetExceeded){_ = try registry.preview(intent:.init(libraryID:"library",name:"bad",totalBytes:1),scope:c.scope,reader:c.reader,validate:{},render:{_ ->Int in throw NASError.budgetExceeded})}
        let one=try preview(registry,c,"one"),two=try preview(registry,c,"two")
        denied(.budgetExceeded){_ = try self.preview(registry,c,"three")}
        try begin(registry,c,one.transferID);XCTAssertEqual(try begin(registry,c,two.transferID).error,NASError.budgetExceeded.rawValue)
        XCTAssertEqual(try registry.cancel(id:one.transferID,caller:c.scope.directory.caller).state,"cancelled");XCTAssertEqual(try stageNames(c),[])
        let next=try preview(registry,c,"next");time=31
        XCTAssertEqual(try registry.status(id:next.transferID,caller:c.scope.directory.caller,validate:{_ in}).error,"expired")
        let live=try preview(registry,c,"live");try begin(registry,c,live.transferID)
        registry.endSession(c.scope.directory.caller.sessionID);XCTAssertEqual(try stageNames(c),[])
        XCTAssertEqual(try registry.status(id:live.transferID,caller:c.scope.directory.caller,validate:{_ in}).state,"notVisible")
    }
    func testIntegrityFailureConflictAndUncertainPublicationNeverDeleteTarget() throws {
        let c=try context(),registry=FileTransferRegistry(),data=Data("data".utf8),p=try preview(registry,c)
        try begin(registry,c,p.transferID);try append(registry,c,p.transferID,data)
        let failed=try registry.finishUpload(id:p.transferID,expected:TransferEncoding.digest(Data("wrong".utf8)),caller:c.scope.directory.caller,validate:{_ in})
        XCTAssertEqual(failed.state,"failed");XCTAssertEqual(failed.error,"integrity");XCTAssertEqual(try stageNames(c),[])
        let conflict=try preview(registry,c,"conflict");try begin(registry,c,conflict.transferID);try append(registry,c,conflict.transferID,data)
        try Data("keep".utf8).write(to:c.root.appendingPathComponent("library/conflict"))
        XCTAssertEqual(try registry.finishUpload(id:conflict.transferID,expected:TransferEncoding.digest(data),caller:c.scope.directory.caller,validate:{_ in}).state,"failed")
        XCTAssertEqual(try Data(contentsOf:c.root.appendingPathComponent("library/conflict")),Data("keep".utf8))
        let uncertain=try preview(registry,c,"uncertain");try begin(registry,c,uncertain.transferID);try append(registry,c,uncertain.transferID,data)
        XCTAssertEqual(try registry.finishUpload(id:uncertain.transferID,expected:TransferEncoding.digest(data),caller:c.scope.directory.caller,validate:{_ in},afterPublication:{
            try Data("evil".utf8).write(to:c.root.appendingPathComponent("library/uncertain"))
        }).state,"uncertain")
        XCTAssertEqual(try registry.cancel(id:uncertain.transferID,caller:c.scope.directory.caller).state,"uncertain")
        XCTAssertEqual(try Data(contentsOf:c.root.appendingPathComponent("library/uncertain")),Data("evil".utf8))
    }
    func testDownloadEncodingFailureDoesNotAdvanceAndSourceReplacementFailsClosed() throws {
        let c=try context(),registry=FileTransferRegistry(),file=c.root.appendingPathComponent("library/source")
        try Data(repeating:7,count:40000).write(to:file)
        let p=try registry.beginDownload(library:"library",path:"source",scope:c.scope,file:c.reader.transferDownload(relative:"source"),validate:{},render:{$0})
        denied(.budgetExceeded){_ = try registry.download(id:p.transferID,offset:0,caller:c.scope.directory.caller,validate:{_ in},render:{_ ->Int in throw NASError.budgetExceeded})}
        XCTAssertEqual(try registry.status(id:p.transferID,caller:c.scope.directory.caller,validate:{_ in}).transferredBytes,0)
        XCTAssertEqual(try registry.download(id:p.transferID,offset:0,caller:c.scope.directory.caller,validate:{_ in},render:{$0}).nextOffset,32768)
        try FileManager.default.moveItem(at:file,to:c.root.appendingPathComponent("library/old"));try Data(repeating:8,count:40000).write(to:file)
        XCTAssertThrowsError(try registry.download(id:p.transferID,offset:32768,caller:c.scope.directory.caller,validate:{_ in},render:{$0}))
        XCTAssertEqual(try registry.status(id:p.transferID,caller:c.scope.directory.caller,validate:{_ in}).state,"failed")
    }
    func testPartialWritesDiskFullAndStagingReplacementCleanupAreBounded() throws {
        let c=try context(),plan=try c.reader.prepareMutation(.init(libraryID:"library",kind:.createDirectory,name:"target")),id=UUID().uuidString.lowercased()
        var stage:TransferStaging?=try c.host.transferStaging(id:id,targetDevice:plan.parent.device);let name=try XCTUnwrap(stage?.name)
        var calls=0
        try stage!.append(Data("data".utf8),offset:0,writer:{fd,buffer,count,offset in
            calls+=1;if calls==1 {errno=EINTR;return -1};return pwrite(fd,buffer,min(1,count),offset)
        });XCTAssertEqual(calls,5)
        XCTAssertEqual(try stage!.digest(bytes:4,checkDeadline:{}),TransferEncoding.digest(Data("data".utf8)))
        denied(.unsafeFile){try stage!.append(Data("more".utf8),offset:4,writer:{_,_,_,_ in errno=ENOSPC;return -1})}
        let staged=c.root.appendingPathComponent("transfer-staging/"+name)
        try FileManager.default.moveItem(at:staged,to:c.root.appendingPathComponent("retained-stage"));try Data("unknown".utf8).write(to:staged)
        stage=nil;XCTAssertEqual(try Data(contentsOf:staged),Data("unknown".utf8))
        XCTAssertEqual(try Data(contentsOf:c.root.appendingPathComponent("retained-stage")),Data("data".utf8))
        denied(.unsupported){_ = try c.host.transferStaging(id:UUID().uuidString.lowercased(),targetDevice:plan.parent.device &+ 1)}
        let partialID=UUID().uuidString.lowercased();var partial:TransferStaging?=try c.host.transferStaging(id:partialID,targetDevice:plan.parent.device);var writes=0
        denied(.unsafeFile){try partial!.append(Data("partial".utf8),offset:0,writer:{fd,bytes,count,offset in
            writes+=1;if writes==1{return pwrite(fd,bytes,1,offset)};errno=ENOSPC;return -1
        })}
        partial=nil;XCTAssertFalse(FileManager.default.fileExists(atPath:c.root.appendingPathComponent("transfer-staging/upload-"+partialID).path))
    }
    func testUnsafeDownloadNodesFileLimitAndExclusivePublishCannotOverwrite() throws {
        let c=try context(),root=c.root.appendingPathComponent("library"),outside=c.root.appendingPathComponent("outside")
        try Data("outside".utf8).write(to:outside)
        try FileManager.default.createSymbolicLink(at:root.appendingPathComponent("link"),withDestinationURL:outside)
        try FileManager.default.linkItem(at:outside,to:root.appendingPathComponent("hard"));XCTAssertEqual(mkfifo(root.appendingPathComponent("fifo").path,0o600),0)
        for name in ["link","hard","fifo","../outside"] {XCTAssertThrowsError(try c.reader.transferDownload(relative:name))}
        for name in ["link","hard","fifo"] {try FileManager.default.removeItem(at:root.appendingPathComponent(name))}
        let fd=open(root.appendingPathComponent("large").path,O_CREAT|O_EXCL|O_WRONLY,0o600);XCTAssertGreaterThanOrEqual(fd,0);defer{close(fd)}
        XCTAssertEqual(ftruncate(fd,off_t(FixtureTransferLimits.fileBytes+1)),0)
        let registry=FileTransferRegistry()
        denied(.budgetExceeded){_ = try registry.beginDownload(library:"library",path:"large",scope:c.scope,file:c.reader.transferDownload(relative:"large"),validate:{},render:{$0})}
        let plan=try c.reader.prepareMutation(.init(libraryID:"library",kind:.createDirectory,name:"target"))
        let staged=try c.host.transferStaging(id:UUID().uuidString.lowercased(),targetDevice:plan.parent.device);try staged.append(Data("new".utf8),offset:0)
        try Data("keep".utf8).write(to:root.appendingPathComponent("target"))
        denied(.collision){try staged.publish(to:plan,validate:{})}
        XCTAssertFalse(staged.published);XCTAssertEqual(try Data(contentsOf:root.appendingPathComponent("target")),Data("keep".utf8))
    }
    func testForeignVisibilityRenderRevocationAndAbsoluteLifetimeDoNotDeliverBytes() throws {
        let c=try context();var time:TimeInterval=0;let registry=FileTransferRegistry(now:{time})
        let file=c.root.appendingPathComponent("library/source");try Data(repeating:1,count:40000).write(to:file)
        let d=try registry.beginDownload(library:"library",path:"source",scope:c.scope,file:c.reader.transferDownload(relative:"source"),validate:{},render:{$0})
        let foreign=JobPageScope(sessionID:UUID(),instanceID:c.scope.directory.caller.instanceID,databaseName:"fixture",userID:Data("owner".utf8),role:"administrator",mode:"synthetic_development")
        XCTAssertEqual(try registry.status(id:d.transferID,caller:foreign,validate:{_ in}).state,"notVisible")
        denied(.denied){_ = try registry.cancel(id:d.transferID,caller:foreign)}
        XCTAssertThrowsError(try registry.download(id:d.transferID,offset:0,caller:c.scope.directory.caller,validate:{_ in},render:{chunk in
            try Data(repeating:2,count:40000).write(to:file);return chunk
        }))
        XCTAssertEqual(try registry.status(id:d.transferID,caller:c.scope.directory.caller,validate:{_ in}).state,"failed")
        let p=try preview(registry,c,"long",1048576);try begin(registry,c,p.transferID)
        for index in 0..<30 {time=Double(index+1)*59;try append(registry,c,p.transferID,Data(repeating:3,count:32768),Int64(index*32768))}
        time=1800;XCTAssertEqual(try registry.status(id:p.transferID,caller:c.scope.directory.caller,validate:{_ in}).error,"expired")
        XCTAssertEqual(try stageNames(c),[])
        var first:String=""
        for index in 0..<33 {let receipt=try preview(registry,c,"cancel-\(index)");if index==0{first=receipt.transferID};_ = try registry.cancel(id:receipt.transferID,caller:c.scope.directory.caller);time+=1}
        XCTAssertEqual(try registry.status(id:first,caller:c.scope.directory.caller,validate:{_ in}).state,"notVisible")
    }
}

final class FixtureTransferAPITests:FileOperationLab {
    func upload(_ c:Context,_ name:String="upload.bin",_ bytes:Int64=4) throws ->FixtureUploadPreview {
        try c.api.previewFixtureUpload(.init(libraryID:c.reference.libraryID,name:name,totalBytes:bytes),session:c.owner)
    }
    func testUploadApprovalIsIndependentAndForeignSessionCannotReadCancelOrWrite() throws {
        let c=try context()
        denied(.denied){_ = try self.upload(c)}
        denied(.denied){try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.family)}
        try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        let p=try upload(c)
        XCTAssertEqual(try c.api.fixtureTransferStatus(transferID:p.transferID,session:c.family).state,"notVisible")
        denied(.denied){_ = try c.api.cancelFixtureTransfer(transferID:p.transferID,session:c.family)}
        denied(.denied){_ = try c.api.beginFixtureUpload(transferID:p.transferID,confirmed:true,session:c.family)}
        denied(.denied){_ = try c.api.beginFixtureUpload(transferID:p.transferID,confirmed:false,session:c.owner)}
        XCTAssertEqual(try c.api.cancelFixtureTransfer(transferID:p.transferID,session:c.owner).state,"cancelled")
        XCTAssertEqual(try c.api.listFixtureLibrary(libraryID:c.reference.libraryID,session:c.owner).map{$0.name},["a.txt"])
    }
    func testReadOnlyBindingAllowsDownloadButCannotGrantUploadAndRevocationStopsSource() throws {
        let c=try context(writeBinding:false,writeApproval:false)
        denied(.denied){try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)}
        let d=try c.api.beginFixtureDownload(libraryID:c.reference.libraryID,relativePath:"a.txt",session:c.owner)
        try c.api.fixtureVolumes.revoke(libraryID:c.reference.libraryID)
        XCTAssertThrowsError(try c.api.fixtureDownloadChunk(transferID:d.transferID,offset:0,session:c.owner))
        XCTAssertEqual(try c.api.cancelFixtureTransfer(transferID:d.transferID,session:c.owner).state,"cancelled")
    }
    func testHostRestartHasNoReceiptAndEndSessionRemovesOnlyPrivateStaging() throws {
        let c=try context();try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        let p=try upload(c);_ = try c.api.beginFixtureUpload(transferID:p.transferID,confirmed:true,session:c.owner)
        _ = try c.api.appendFixtureUpload(transferID:p.transferID,offset:0,parts:TransferEncoding.parts(Data("data".utf8)),session:c.owner)
        let next=try PrototypePlatformAPI(root:c.api.root),owner=try next.beginFixtureSession(userID:"fixture-owner")
        XCTAssertEqual(try next.fixtureTransferStatus(transferID:p.transferID,session:owner).state,"notVisible")
        c.api.endSession(c.owner)
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath:c.api.root.appendingPathComponent("host-binding/transfer-staging").path),[])
        XCTAssertEqual(try Data(contentsOf:c.library.appendingPathComponent("a.txt")),Data("data".utf8))
    }
    func testReapprovalAndGenerationChangeInvalidateStreamsWithoutPublishing() throws {
        let c=try context();try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        let p=try upload(c);_ = try c.api.beginFixtureUpload(transferID:p.transferID,confirmed:true,session:c.owner)
        try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        XCTAssertThrowsError(try c.api.appendFixtureUpload(transferID:p.transferID,offset:0,parts:TransferEncoding.parts(Data("data".utf8)),session:c.owner))
        _ = try c.api.cancelFixtureTransfer(transferID:p.transferID,session:c.owner)
        let d=try c.api.beginFixtureDownload(libraryID:c.reference.libraryID,relativePath:"a.txt",session:c.owner)
        var identity=try SafeFS.read(InstanceIdentity.self,SafeFS.resolve(c.api.root,"instance.json"));identity.generation+=1
        try SafeFS.write(identity,to:SafeFS.resolve(c.api.root,"instance.json"))
        XCTAssertThrowsError(try c.api.fixtureDownloadChunk(transferID:d.transferID,offset:0,session:c.owner))
        XCTAssertFalse(FileManager.default.fileExists(atPath:c.library.appendingPathComponent("upload.bin").path))
    }
    func testStrictWireLimitsAndNullMetadataAndEncodingFailureDoNotAdvanceDownload() throws {
        let c=try context();try c.api.authorizeFixtureLibraryUploads(libraryID:c.reference.libraryID,session:c.owner)
        let bridge=try DesktopBridge(api:c.api,session:c.owner),small=try DesktopBridge(api:c.api,session:c.owner,limits:BridgeLimits(responseBytes:128))
        func call(_ method:String,_ params:[String:Any],_ host:DesktopBridge) throws ->[String:Any] {
            let data=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":method,"params":params])
            return try XCTUnwrap(JSONSerialization.jsonObject(with:host.handle(data)) as? [String:Any])
        }
        XCTAssertNotNil(try call("previewUpload",["libraryID":c.reference.libraryID,"name":"x","totalBytes":4,"root":"/tmp"],bridge)["error"])
        XCTAssertNotNil(try call("appendUpload",["transferID":UUID().uuidString.lowercased(),"offset":0,"parts":[String(repeating:"x",count:5000)]],bridge)["error"])
        let d=try c.api.beginFixtureDownload(libraryID:c.reference.libraryID,relativePath:"a.txt",session:c.owner)
        XCTAssertNotNil(try call("readDownloadChunk",["transferID":d.transferID,"offset":0],small)["error"])
        XCTAssertEqual(try c.api.fixtureTransferStatus(transferID:d.transferID,session:c.owner).transferredBytes,0)
        let unknown=try XCTUnwrap(try call("transferStatus",["transferID":UUID().uuidString.lowercased()],bridge)["data"] as? [String:Any])
        XCTAssertEqual(unknown.count,12);XCTAssertTrue(unknown["direction"] is NSNull);XCTAssertTrue(unknown["error"] is NSNull)
        XCTAssertEqual(try c.api.fixtureDownloadChunk(transferID:d.transferID,offset:0,session:c.owner).sha256,TransferEncoding.digest(Data("data".utf8)))
    }
}
