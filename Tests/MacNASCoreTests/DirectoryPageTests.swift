import Foundation
import XCTest
import Darwin
@testable import MacNASCore

final class DirectoryScanTests: LabTest {
    func reader(_ names: [String]) throws -> (URL,DescriptorLibrary) {
        let root=child("directory");try SafeFS.freshDirectory(root)
        for name in names { try Data(name.utf8).write(to:root.appendingPathComponent(name)) }
        return (root,try DescriptorLibrary(mountRoot:root))
    }
    func testByteSortedPagesTraverseOverLegacyThousandWithoutRetainingAllDTOs() throws {
        let names=(0..<1001).map { String(format:"item-%04d.txt",$0) }
        let (_,r)=try reader(names);denied(.budgetExceeded) { _ = try r.list() }
        var result:[String]=[],after:String?,stamp:DirectoryStamp?
        repeat {
            let page=try r.page(after:after,expected:stamp,size:100)
            XCTAssertLessThanOrEqual(page.entries.count,100);result += page.entries.map(\.name)
            after=page.entries.last?.name;stamp=page.stamp
            if !page.hasMore { break }
        } while true
        XCTAssertEqual(result,names)
    }
    func testEmptyExactBoundaryUnicodeAndNestedPathsUseActualUTF8Names() throws {
        let (root,r)=try reader([]);XCTAssertFalse(try r.page(size:1).hasMore)
        let folder=root.appendingPathComponent("子目录");try FileManager.default.createDirectory(at:folder,withIntermediateDirectories:false)
        for name in ["z.txt","🐚.txt","é.txt","中.txt","jobHash.txt"] { try Data().write(to:folder.appendingPathComponent(name)) }
        let actual=try FileManager.default.contentsOfDirectory(atPath:folder.path).sorted { $0.utf8.lexicographicallyPrecedes($1.utf8) }
        let page=try r.page(relative:"子目录",size:5);XCTAssertFalse(page.hasMore);XCTAssertEqual(page.entries.map(\.name),actual)
        XCTAssertTrue(page.entries.allSatisfy { $0.relativePath=="子目录/"+$0.name })
        for invalid in ["../x","/etc","a//b","a\\b"] { denied(.unsafePath) { _ = try r.page(relative:invalid) } }
        for size in [0,101] { denied(.invalidSchema) { _ = try r.page(size:size) } }
    }
    func testHardScanEntryAndNameBudgetsRejectTheWholePage() throws {
        let (_,r)=try reader(["a.txt","b.txt","c.txt"])
        denied(.budgetExceeded) { _ = try r.page(size:1,budget:DirectoryScanBudget(entries:2)) }
        denied(.budgetExceeded) { _ = try r.page(size:1,budget:DirectoryScanBudget(nameBytes:14)) }
        let root=child("too-many");try SafeFS.freshDirectory(root)
        for i in 0..<8193 { try Data().write(to:root.appendingPathComponent("f-"+String(i))) }
        let over=try DescriptorLibrary(mountRoot:root)
        denied(.budgetExceeded) { _ = try over.page(size:1) }
    }
    func testScanClockBudgetFailsWithoutAPartialPage() throws {
        let (_,r)=try reader(["a.txt","b.txt"]);var time:TimeInterval=0
        denied(.timedOut) { _ = try r.page(size:1,budget:DirectoryScanBudget(seconds:1),now:{time+=0.5;return time}) }
    }
    func testCollisionDigestsRejectCaseAndCanonicalNamesWithoutFullNameCaching() throws {
        for pair in [["A.txt","a.txt"],["caf\u{e9}.txt","cafe\u{301}.txt"]] {
            var names=DirectoryNameBudget();try names.add(pair[0],budget:DirectoryScanBudget())
            denied(.collision) { try names.add(pair[1],budget:DirectoryScanBudget()) }
        }
    }
    func testUnsafeEntriesOutsideTheSelectedPageStillRejectTheWholeScan() throws {
        let (root,r)=try reader(["a.txt"])
        let outside=child("outside");try Data("must-not-read".utf8).write(to:outside)
        let bad=root.appendingPathComponent("z.txt")
        try FileManager.default.createSymbolicLink(at:bad,withDestinationURL:outside)
        denied(.unsafeFile) { _ = try r.page(size:1) };try FileManager.default.removeItem(at:bad)
        try FileManager.default.linkItem(at:outside,to:bad)
        denied(.unsafeFile) { _ = try r.page(size:1) };try FileManager.default.removeItem(at:bad)
        XCTAssertEqual(mkfifo(bad.path,0o600),0);denied(.unsafeFile) { _ = try r.page(size:1) }
    }
    func testMembershipChangesAcrossPagesAndDuringScanRequireRestart() throws {
        let (root,r)=try reader(["a.txt","b.txt"]),first=try r.page(size:1)
        try Data().write(to:root.appendingPathComponent("c.txt"))
        denied(.staleState) { _ = try r.page(after:first.entries[0].name,expected:first.stamp,size:1) }
        denied(.staleState) { _ = try r.page(size:1,afterScan:{try FileManager.default.removeItem(at:root.appendingPathComponent("c.txt"))}) }
        XCTAssertEqual(try r.page(size:100).entries.count,2)
    }
    func testDirectoryReplacementAndSelectedMetadataChangeAreDetected() throws {
        let (root,r)=try reader(["a.txt","b.txt"])
        denied(.staleState) { _ = try r.page(size:1,afterScan:{try Data("longer".utf8).write(to:root.appendingPathComponent("a.txt"))}) }
        let first=try r.page(size:1)
        try FileManager.default.moveItem(at:root,to:child("retained"));try SafeFS.freshDirectory(root)
        denied(.staleState) { _ = try r.page(after:first.entries[0].name,expected:first.stamp,size:1) }
    }
    func testFileMetadataIsLiveAcrossPagesWithoutClaimingAContentSnapshot() throws {
        let (root,r)=try reader(["a.txt","b.txt"]),first=try r.page(size:1)
        // In-place writes need not alter the containing directory stamp.
        let file=try FileHandle(forWritingTo:root.appendingPathComponent("b.txt"));try file.truncate(atOffset:0);try file.write(contentsOf:Data("changed".utf8));try file.close()
        let next=try r.page(after:first.entries[0].name,expected:first.stamp,size:1)
        XCTAssertEqual(next.entries.first?.bytes,7);XCTAssertFalse(next.hasMore)
    }
}

final class DirectoryPageRegistryTests: XCTestCase {
    let stamp=DirectoryStamp(stat())
    func scope() -> DirectoryPageScope {
        DirectoryPageScope(caller:JobPageScope(sessionID:UUID(),instanceID:UUID(),databaseName:"fixture",userID:Data("owner".utf8),role:"administrator",mode:"synthetic_development"),libraryID:Data("library".utf8),relativePath:Data(),volumeID:UUID(),mediaID:UUID(),mountID:UUID(),approvalID:UUID(),inventoryRevision:1,readerID:UUID())
    }
    func slice(more:Bool=true) -> DirectorySlice { DirectorySlice(entries:[FixtureFileEntry(name:"a",relativePath:"a",kind:.file,bytes:1,modifiedAt:Date())],stamp:stamp,hasMore:more) }
    func page(_ r:DirectoryPageRegistry,_ scope:DirectoryPageScope,_ token:String?=nil,size:Int=1,more:Bool=true) throws -> FixtureDirectoryPage {
        try r.page(scope:scope,size:size,cursor:token,query:{_,_ in self.slice(more:more)},validate:{_ in},render:{$0})
    }
    func denied(_ code:NASError,_ operation:() throws -> Void) { XCTAssertThrowsError(try operation()) { XCTAssertEqual($0 as? NASError,code) } }
    func testSingleUseScopeSizeAndMalformedTokensDoNotConsumeOwnersPosition() throws {
        let r=DirectoryPageRegistry(),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor)
        denied(.denied) { _ = try self.page(r,self.scope(),token) };denied(.denied) { _ = try self.page(r,s,token,size:2) }
        for bad in ["","sql","AAAAAAAA-0000-0000-0000-000000000000"] { denied(.invalidSchema) { _ = try self.page(r,s,bad) } }
        XCTAssertNil(try page(r,s,token,more:false).nextCursor);denied(.replay) { _ = try self.page(r,s,token) }
    }
    func testEncodingAndFinalAuthorizationFailurePreserveOldCapability() throws {
        let r=DirectoryPageRegistry(),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor);var checks=0
        denied(.budgetExceeded) { _ = try r.page(scope:s,size:1,cursor:token,query:{_,_ in self.slice()},validate:{_ in},render:{_ -> Int in throw NASError.budgetExceeded}) }
        denied(.denied) { _ = try r.page(scope:s,size:1,cursor:token,query:{_,_ in self.slice()},validate:{_ in checks+=1;if checks==2 {throw NASError.denied}},render:{$0}) }
        XCTAssertNil(try page(r,s,token,more:false).nextCursor)
    }
    func testCapacityExpiryAndLogoutAreBoundedAndNonSliding() throws {
        var time:TimeInterval=0;let r=DirectoryPageRegistry(capacity:2,now:{time}),s=scope()
        let token=try XCTUnwrap(page(r,s).nextCursor);_ = try page(r,s)
        denied(.budgetExceeded) { _ = try self.page(r,s) }
        time=59;let next=try XCTUnwrap(page(r,s,token).nextCursor);time=60
        denied(.expired) { _ = try self.page(r,s,next) }
        let fresh=try XCTUnwrap(page(r,s).nextCursor);r.endSession(s.caller.sessionID)
        denied(.denied) { _ = try self.page(r,s,fresh) }
    }
    func testStaleDirectoryInvalidatesOldPositionAndSlowEncodingExpires() throws {
        var time:TimeInterval=0;let r=DirectoryPageRegistry(now:{time}),s=scope(),token=try XCTUnwrap(page(r,s).nextCursor)
        denied(.staleState) { _ = try r.page(scope:s,size:1,cursor:token,query:{_,_ in throw NASError.staleState},validate:{_ in},render:{$0}) }
        denied(.denied) { _ = try self.page(r,s,token) }
        denied(.expired) { _ = try r.page(scope:s,size:1,cursor:nil,query:{_,_ in self.slice()},validate:{_ in},render:{p in time=60;return p}) }
    }
}

class DirectoryPageLab: LabTest {
    struct Context {
        let api:PrototypePlatformAPI;let owner:PrototypeSession;let family:PrototypeSession
        let reference:VolumeReference;let observation:FixtureVolumeObservation;let library:URL
    }
    func context() throws -> Context {
        let root=child("directory-source");try PortableInstance.createSynthetic(at:root,databaseVersion:3)
        let api=try PrototypePlatformAPI(root:root),owner=try api.beginFixtureSession(userID:"fixture-owner"),family=try api.beginFixtureSession(userID:"fixture-family")
        let reference=try XCTUnwrap(api.fixtureVolumes.references.first),observation=FixtureVolumeObservation(volumeID:reference.volumeID,displayName:"synthetic-only",authorized:true)
        let mount=root.appendingPathComponent("host-binding/fixtures/volumes/"+observation.mountID.uuidString.lowercased()),library=mount.appendingPathComponent(reference.relativePath)
        try FileManager.default.createDirectory(at:library,withIntermediateDirectories:true)
        for name in ["a.txt","b.txt","c.txt"] { try Data(name.utf8).write(to:library.appendingPathComponent(name)) }
        try api.updateFixtureVolumeInventory([observation],session:owner)
        let preview=try api.previewFixtureVolumeBinding(libraryID:reference.libraryID,access:.readOnly,session:owner)
        try api.commitFixtureVolumeBinding(preview,confirmed:true,session:owner)
        return Context(api:api,owner:owner,family:family,reference:reference,observation:observation,library:library)
    }
    func request(_ host:DesktopBridge,_ params:[String:Any]) throws -> [String:Any] {
        let raw=try JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":UUID().uuidString,"method":"listFilesPage","params":params])
        return try XCTUnwrap(JSONSerialization.jsonObject(with:host.handle(raw)) as? [String:Any])
    }
    func code(_ response:[String:Any]) -> String? { (response["error"] as? [String:Any])?["code"] as? String }
}
final class DirectoryPageAPITests: DirectoryPageLab {
    func testExplicitContentApprovalAudienceAndSessionScopesRemainRequired() throws {
        let c=try context(),id=c.reference.libraryID
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,session:c.owner) }
        try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,session:c.family) }
        try c.api.setFixtureLibraryReaders(["fixture-family"],libraryID:id,session:c.owner)
        let token=try XCTUnwrap(c.api.fixtureLibraryPage(libraryID:id,pageSize:1,session:c.owner).nextCursor)
        for session in [c.family,try c.api.beginFixtureSession(userID:"fixture-owner")] {
            denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:session) }
        }
        XCTAssertEqual(try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner).entries.first?.name,"b.txt")
        XCTAssertEqual(try c.api.fixtureLibraryPage(libraryID:id,pageSize:100,session:c.family).entries.count,3)
        c.api.endSession(c.owner);denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
    }
    func testInventoryContentReapprovalAndModeChangesInvalidateContinuationScope() throws {
        let c=try context(),id=c.reference.libraryID;try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        var token=try XCTUnwrap(c.api.fixtureLibraryPage(libraryID:id,pageSize:1,session:c.owner).nextCursor)
        try c.api.updateFixtureVolumeInventory([c.observation],session:c.owner)
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
        token=try XCTUnwrap(c.api.fixtureLibraryPage(libraryID:id,pageSize:1,session:c.owner).nextCursor)
        try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
        token=try XCTUnwrap(c.api.fixtureLibraryPage(libraryID:id,pageSize:1,session:c.owner).nextCursor)
        let path=try SafeFS.resolve(c.api.root,"host-binding/binding.json");var binding=try SafeFS.read(HostBinding.self,path)
        binding.mode="read_only_recovery";try SafeFS.write(binding,to:path)
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
        XCTAssertEqual(try c.api.fixtureLibraryPage(libraryID:id,session:c.owner).entries.count,3)
        denied(.denied) { try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner) }
    }
    func testRevocationRemountAndRestartNeverAutomaticallyRestorePageAuthority() throws {
        let c=try context(),id=c.reference.libraryID;try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        let token=try XCTUnwrap(c.api.fixtureLibraryPage(libraryID:id,pageSize:1,session:c.owner).nextCursor)
        try c.api.updateFixtureVolumeInventory([],session:c.owner)
        denied(.missingVolume) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
        try c.api.updateFixtureVolumeInventory([c.observation],session:c.owner)
        denied(.denied) { _ = try c.api.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:c.owner) }
        let restarted=try PrototypePlatformAPI(root:c.api.root),session=try restarted.beginFixtureSession(userID:"fixture-owner")
        denied(.missingVolume) { _ = try restarted.fixtureLibraryPage(libraryID:id,pageSize:1,cursor:token,session:session) }
    }
    func testBridgeDTOParametersOrderingTerminalNullAndEncodingFailureAreTransactional() throws {
        let c=try context(),id=c.reference.libraryID;try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        let host=try DesktopBridge(api:c.api,session:c.owner)
        for params:[String:Any] in [["libraryID":id,"pageSize":0],["libraryID":id,"pageSize":101],["libraryID":id,"pageSize":true],["libraryID":id,"cursor":NSNull()],["libraryID":id,"root":"/"],["libraryID":id,"relativePath":NSNull()]] { XCTAssertEqual(code(try request(host,params)),"invalidInput") }
        let first=try XCTUnwrap(request(host,["libraryID":id,"pageSize":2])["data"] as? [String:Any]),token=try XCTUnwrap(first["nextCursor"] as? String)
        XCTAssertEqual(first["order"] as? String,"name-utf8");XCTAssertEqual(first["consistency"] as? String,"directory-stamped-live-metadata")
        XCTAssertFalse(String(decoding:try JSONSerialization.data(withJSONObject:first),as:UTF8.self).contains(c.api.root.path))
        let small=try DesktopBridge(api:c.api,session:c.owner,limits:BridgeLimits(responseBytes:128))
        XCTAssertEqual(code(try request(small,["libraryID":id,"pageSize":2,"cursor":token])),"budgetExceeded")
        let last=try XCTUnwrap(request(host,["libraryID":id,"pageSize":2,"cursor":token])["data"] as? [String:Any]);XCTAssertTrue(last["nextCursor"] is NSNull)
        XCTAssertEqual(code(try request(host,["libraryID":id,"pageSize":2,"cursor":token])),"replay")
    }
    func testPostEncodingDirectoryMutationAndReaderRevocationAreRechecked() throws {
        let c=try context(),id=c.reference.libraryID;try c.api.authorizeFixtureLibraryContent(libraryID:id,session:c.owner)
        denied(.staleState) {
            _ = try c.api.withFixtureLibraryPage(libraryID:id,relativePath:"",pageSize:1,cursor:nil,session:c.owner) { page in
                try Data().write(to:c.library.appendingPathComponent("d.txt"));return page
            }
        }
        try c.api.setFixtureLibraryReaders(["fixture-family"],libraryID:id,session:c.owner)
        denied(.denied) {
            _ = try c.api.withFixtureLibraryPage(libraryID:id,relativePath:"",pageSize:1,cursor:nil,session:c.family) { page in
                try c.api.setFixtureLibraryReaders([],libraryID:id,session:c.owner);return page
            }
        }
    }
}

final class DirectoryPagePipeTests: DirectoryPageLab {
    func testActualNodeClientPipesReachApprovedSwiftDirectoryAndDetectInterpageMutation() throws {
        let c=try context();try c.api.authorizeFixtureLibraryContent(libraryID:c.reference.libraryID,session:c.owner)
        let host=try DesktopBridge(api:c.api,session:c.owner);defer { host.close() }
        let repo=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let node=try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_NODE_BINARY"])
        let process=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        process.executableURL=URL(fileURLWithPath:node);process.arguments=[repo.appendingPathComponent("scripts/test_directory_bridge.cjs").path,c.reference.libraryID]
        process.currentDirectoryURL=repo;process.environment=["LANG":"C","LC_ALL":"C","HOME":lab.path]
        process.standardInput=input;process.standardOutput=output;process.standardError=errors
        let timer=DispatchSource.makeTimerSource(queue:DispatchQueue.global())
        timer.schedule(deadline:.now()+45);timer.setEventHandler { if process.isRunning { process.terminate() } };timer.resume()
        defer { timer.cancel();if process.isRunning { process.terminate() };try? input.fileHandleForWriting.close() }
        try process.run();var frame=Data(),requests=0
        while true {
            let block=output.fileHandleForReading.availableData
            if block.isEmpty { break }
            frame.append(block);try require(frame.count<=65536, .budgetExceeded)
            while let end=frame.firstIndex(of:10) {
                requests+=1;try require(requests<=16, .budgetExceeded)
                let reply=host.handle(Data(frame[..<end]));frame.removeSubrange(...end)
                if requests==4 { try Data("new synthetic entry".utf8).write(to:c.library.appendingPathComponent("d.txt")) }
                try input.fileHandleForWriting.write(contentsOf:reply+Data([10]))
            }
        }
        process.waitUntilExit();let diagnostics=try errors.fileHandleForReading.readToEnd() ?? Data()
        XCTAssertTrue(frame.isEmpty);XCTAssertEqual(process.terminationStatus,0,String(decoding:diagnostics,as:UTF8.self))
        XCTAssertEqual(requests,7);XCTAssertTrue(String(decoding:diagnostics,as:UTF8.self).contains("directory-page-pipe: PASS"))
    }
}
