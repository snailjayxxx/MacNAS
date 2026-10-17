import Foundation
import Darwin
import XCTest
@testable import MacNASCore

final class CapacityLedgerReadAPITests: PhysicalCapacityLab {
    func context(_ api: PrototypePlatformAPI, _ session: PrototypeSession) throws -> CapacityLedgerReadContext {
        try api.fixtureCapacityLedgerContext(session: session)
    }
    func list(_ api: PrototypePlatformAPI, _ session: PrototypeSession, _ context: CapacityLedgerReadContext) throws -> CapacityLedgerListView {
        try api.listFixtureCapacityLedger(scopeID: context.scopeID, sourceID: context.sourceID, session: session)
    }
    func testRequiresSeparateApprovalAndCannotCreateOrAdoptAScope() throws {
        for schema in [4,5,6] {
            let root = child("schema-\(schema)"); try PortableInstance.createSynthetic(at: root, databaseVersion: schema)
            let api = try PrototypePlatformAPI(root: root), session = try api.beginFixtureSession(userID: "fixture-owner")
            XCTAssertThrowsError(try api.authorizeFixtureCapacityLedgerRead(session: session, confirmed: true))
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(FixturePhysicalCapacityNamespace.markerPath).path))
            api.endSession(session)
        }
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root: root)
        let session = try api.beginFixtureSession(userID: "fixture-owner"), before = try host.store.contentDigest()
        denied(.denied) { _ = try self.context(api,session) }
        denied(.denied) { try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:false) }
        let inspect = try host.approveInspect(confirmed:true)
        denied(.denied) { _ = try host.withLedgerRead(inspect) { _ in true } }
        XCTAssertThrowsError(try api.authorizeFixtureRecycleObservation(session:session,confirmed:true))
        denied(.denied) { _ = try self.context(api,session) }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testApprovedSourceIsFixedToAPIAndSessionAndRenewsOnEveryApproval() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root)
        let session = try api.beginFixtureSession(userID:"fixture-owner"), other = try api.beginFixtureSession(userID:"fixture-owner")
        let before = try host.store.contentDigest()
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
        let first = try context(api,session); XCTAssertEqual(try context(api,session),first)
        XCTAssertEqual(try list(api,session,first).items.count,0)
        denied(.denied) { _ = try self.list(api,other,first) }
        try api.authorizeFixtureCapacityLedgerRead(session:other,confirmed:true)
        let second = try context(api,other); XCTAssertNotEqual(first.sourceID,second.sourceID)
        denied(.denied) { _ = try self.list(api,other,first) }
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
        let renewed = try context(api,session); XCTAssertEqual(renewed.scopeID,first.scopeID); XCTAssertNotEqual(renewed.sourceID,first.sourceID)
        denied(.denied) { _ = try self.list(api,session,first) }
        let restarted = try PrototypePlatformAPI(root:root), newSession = try restarted.beginFixtureSession(userID:"fixture-owner")
        try restarted.authorizeFixtureCapacityLedgerRead(session:newSession,confirmed:true)
        XCTAssertNotEqual(try context(restarted,newSession).sourceID,renewed.sourceID)
        api.revokeFixtureCapacityLedgerRead(session:session); denied(.denied) { _ = try self.context(api,session) }
        api.endSession(other); denied(.denied) { _ = try self.context(api,other) }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testRecoveryAllowsFreshReadApprovalButInvalidatesPreviousMode() throws {
        let (root,host) = try physicalLab(); _ = try receive(host)
        let api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner")
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true); let old = try context(api,session)
        let path = root.appendingPathComponent("host-binding/binding.json")
        var binding = try PortableInstance.strictRead(HostBinding.self,path)
        for mode in ["read_only_recovery","rolled_back_recovery"] {
            binding.mode = mode; try SafeFS.write(binding,to:path)
            denied(.denied) { _ = try self.list(api,session,old) }
            try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
            let ctx = try context(api,session), before = try host.store.contentDigest()
            XCTAssertEqual(ctx.mode,mode); XCTAssertEqual(try list(api,session,ctx).totals.ownedBytes,4)
            XCTAssertEqual(try host.store.contentDigest(),before)
            XCTAssertThrowsError(try host.approveReceive(key:Data("write".utf8),bytes:0,sha256:TransferEncoding.digest(Data()),confirmed:true))
        }
    }
    func testRawUnicodeOwnerIsNotNormalizedAndReaderCannotApprove() throws {
        let root = child("unicode"); try PortableInstance.createSynthetic(at:root,databaseVersion:6)
        let path = root.appendingPathComponent("config/platform.json")
        var config = try PortableInstance.strictRead(PortableConfig.self,path)
        let raw = "e\u{301}"; config.users[0].id = raw; try SafeFS.write(config,to:path)
        let data = Data(raw.utf8); _ = try FixturePhysicalCapacityNamespace.createFresh(root:root,userID:data,confirmed:true)
        let api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:raw)
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true)
        let ctx = try context(api,session); XCTAssertEqual(Data(ctx.userID.utf8),data)
        XCTAssertEqual(try list(api,session,ctx).ownerUserHex,FileEffectMetadata.hex(data))
        config.users[0].id = "é"; try SafeFS.write(config,to:path)
        denied(.denied) { _ = try self.context(api,session) }
        config.users[0].id = raw; try SafeFS.write(config,to:path)
        let reader = try api.beginFixtureSession(userID:"fixture-family")
        denied(.denied) { try api.authorizeFixtureCapacityLedgerRead(session:reader,confirmed:true) }
    }
    func testAnchorRoleAndRegistrationChangesRefuseBeforeReturningData() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root)
        let session = try api.beginFixtureSession(userID:"fixture-owner")
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true); let ctx = try context(api,session)
        let mutations: [(String,String,Any)] = [("instance.json","generation",999),("instance.json","instanceID",UUID().uuidString),
            ("host-binding/binding.json","databaseName","different_database"),("host-binding/binding.json","hostID","another-host"),
            (FixturePhysicalCapacityNamespace.markerPath,"stagingInode","999"),(RecycleVault.registrationPath,"libraryID","other")]
        for (relative,key,value) in mutations {
            let file = root.appendingPathComponent(relative), original = try Data(contentsOf:file)
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with:original) as? [String:Any]); object[key] = value
            try JSONSerialization.data(withJSONObject:object).write(to:file)
            XCTAssertThrowsError(try list(api,session,ctx),relative)
            try original.write(to:file)
        }
        let configPath = root.appendingPathComponent("config/platform.json"), original = try Data(contentsOf:configPath)
        var config = try PortableInstance.strictRead(PortableConfig.self,configPath); config.users[0].role = "reader"; try SafeFS.write(config,to:configPath)
        denied(.denied) { _ = try self.list(api,session,ctx) }; try original.write(to:configPath)
        let before = try host.store.contentDigest()
        denied(.denied) { _ = try api.listFixtureCapacityLedger(scopeID:UUID().uuidString.lowercased(),sourceID:ctx.sourceID,session:session) }
        denied(.denied) { _ = try api.listFixtureCapacityLedger(scopeID:ctx.scopeID,sourceID:String(repeating:"0",count:64),session:session) }
        denied(.invalidSchema) { _ = try api.listFixtureCapacityLedger(scopeID:"AAAAAAAA-0000-4000-8000-000000000001",sourceID:ctx.sourceID,session:session) }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testFinalRenderingRechecksRevocationSessionModeAndDatabaseBinding() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root)
        let session = try api.beginFixtureSession(userID:"fixture-owner"), bindingPath = root.appendingPathComponent("host-binding/binding.json")
        let original = try Data(contentsOf:bindingPath)
        for mutation in ["revoke","mode","database"] {
            try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true); let ctx = try context(api,session)
            XCTAssertThrowsError(try api.withFixtureCapacityLedgerList(scopeID:ctx.scopeID,sourceID:ctx.sourceID,session:session) { view in
                if mutation == "revoke" { api.revokeFixtureCapacityLedgerRead(session:session) }
                if mutation == "mode" { var b = try PortableInstance.strictRead(HostBinding.self,bindingPath); b.mode = "read_only_recovery"; try SafeFS.write(b,to:bindingPath) }
                if mutation == "database" { try host.store.execute("UPDATE macnas.physical_capacity_scopes SET owner_uid=owner_uid+1;") }
                return try JSONEncoder().encode(view)
            },mutation)
            try original.write(to:bindingPath)
            if mutation == "database" { try host.store.execute("UPDATE macnas.physical_capacity_scopes SET owner_uid=\(getuid());") }
        }
        try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true); let ctx = try context(api,session)
        denied(.denied) { _ = try api.withFixtureCapacityLedgerList(scopeID:ctx.scopeID,sourceID:ctx.sourceID,session:session) { _ in api.endSession(session) } }
    }
    func testActualPrivateBindingAndHeldLockReplacementInvalidateReadSeal() throws {
        let (root,_) = try physicalLab(), api = try PrototypePlatformAPI(root:root), session = try api.beginFixtureSession(userID:"fixture-owner")
        for name in ["execution.lock","binding.json"] {
            try api.authorizeFixtureCapacityLedgerRead(session:session,confirmed:true); let ctx = try context(api,session)
            let path = root.appendingPathComponent(RecycleVault.fixturePath+"/vault/"+name), saved = child("saved-"+name)
            denied(.staleState) {
                _ = try api.withFixtureCapacityLedgerList(scopeID:ctx.scopeID,sourceID:ctx.sourceID,session:session) { _ in
                    try FileManager.default.moveItem(at:path,to:saved); try Data().write(to:path); XCTAssertEqual(chmod(path.path,0o600),0)
                }
            }
            try FileManager.default.removeItem(at:path); try FileManager.default.moveItem(at:saved,to:path)
        }
    }
    func testReadGrantExpiryAndEightSessionBudgetNeverMutateDatabase() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root); var now: TimeInterval = 10
        let session = try api.beginFixtureSession(userID:"fixture-owner"), before = try host.store.contentDigest()
        try api.authorizeCapacityLedgerRead(session:session,confirmed:true,now:{ now }); let ctx = try context(api,session)
        now = 1811; denied(.expired) { _ = try self.list(api,session,ctx) }
        api.revokeFixtureCapacityLedgerRead(session:session)
        var sessions: [PrototypeSession] = []
        for _ in 0..<8 { let s = try api.beginFixtureSession(userID:"fixture-owner"); try api.authorizeFixtureCapacityLedgerRead(session:s,confirmed:true); sessions.append(s) }
        let ninth = try api.beginFixtureSession(userID:"fixture-owner")
        denied(.budgetExceeded) { try api.authorizeFixtureCapacityLedgerRead(session:ninth,confirmed:true) }
        api.endSession(sessions[0]); try api.authorizeFixtureCapacityLedgerRead(session:ninth,confirmed:true)
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
    func testReadSealCannotInspectExecuteOrTransitionAndIgnoresPayloadChanges() throws {
        let (root,host) = try physicalLab(), received = try receive(host), read = try host.approveLedgerRead(confirmed:true)
        let name = received.allocationID.uuidString.lowercased(), payload = library(root).appendingPathComponent(name)
        try Data("evil".utf8).write(to:payload)
        // Unknown inventory remains visible to execution audit, but ledgerOnly is not a payload audit.
        try FileManager.default.createSymbolicLink(at:library(root).appendingPathComponent("unknown"),withDestinationURL:child("absent"))
        let before = try host.store.contentDigest()
        try host.withLedgerRead(read) { permit in
            let view = try permit.ledger().completeReadOnlyList(sourceID:String(repeating:"a",count:64))
            XCTAssertEqual(view.totals.ownedBytes,4); XCTAssertEqual(view.items[0].sha256,received.record?.sha256)
            denied(.denied) { _ = try PhysicalCapacityFiles.audit(permit,requireClean:false) }
            denied(.denied) { _ = try PhysicalCapacityFiles.visibleFile(permit,record:try XCTUnwrap(received.record)) }
            denied(.denied) { try permit.check(write:true) }
            denied(.denied) { _ = try host.withPermit(read) { _ in true } }
            denied(.denied) { _ = try host.legacyAccess(read) }
            denied(.denied) { _ = try host.receive(Data(),grant:read) }
            denied(.denied) { _ = try host.inspect(read) }
            denied(.denied) { _ = try host.cancelUnarmed(grant:read) }
            let declaration = try PhysicalCapacityDeclaration.make(scopeID:host.registration.scopeID,origin:.upload,key:Data("no".utf8),bytes:0,sha256:TransferEncoding.digest(Data()))
            denied(.denied) { _ = try permit.ledger().reservePhysical(declaration) }
            denied(.denied) { _ = try permit.ledger().armPhysical(try XCTUnwrap(received.record)) }
            denied(.unsupported) { _ = try permit.ledger().reserve(origin:.upload,key:Data("no".utf8),intentSHA256:declaration.intentSHA256,bytes:0) }
        }
        XCTAssertEqual(try host.store.contentDigest(),before); XCTAssertEqual(try Data(contentsOf:payload),Data("evil".utf8))
        XCTAssertFalse(try inventory(host).clean)
    }
    func testBoundedSnapshotRejectsSixtyFiveRowsInsteadOfReturningAPartialHistory() throws {
        let (_,host) = try physicalLab()
        // Explicit invalid metadata fixture, never physical publication or inventory adoption.
        try host.store.execute("""
        INSERT INTO macnas.capacity_allocations SELECT md5(n::text)::uuid,'\(host.registration.scopeID)'::uuid,1,'upload',
          convert_to('fixture-'||n,'UTF8'),repeat('a',64),0,'cancelled',2,NULL,now(),NULL,NULL,now()
        FROM generate_series(1,65) n;
        """)
        let read = try host.approveLedgerRead(confirmed:true), before = try host.store.contentDigest()
        XCTAssertThrowsError(try host.withLedgerRead(read) { try $0.ledger().completeReadOnlyList(sourceID:String(repeating:"a",count:64)) })
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
}

extension CapacityLedgerReadAPITests {
    func testStrictDesktopParamsAndCLINeedExplicitHostReadApproval() throws {
        let (root,host) = try physicalLab(), api = try PrototypePlatformAPI(root:root)
        let session = try api.beginFixtureSession(userID:"fixture-owner"), bridge = try DesktopBridge(api:api,session:session)
        defer{bridge.close()}
        let before = try host.store.contentDigest()
        func request(_ method: String, _ params: [String:Any]) throws -> [String:Any] {
            try XCTUnwrap(JSONSerialization.jsonObject(with:bridge.handle(JSONSerialization.data(withJSONObject:
                ["apiVersion":1,"requestId":UUID().uuidString,"method":method,"params":params]))) as? [String:Any])
        }
        for (method,params) in [("capacityLedgerContext",["confirmed":true]),("listCapacityLedger",["scopeID":host.registration.scopeID.uuidString.lowercased()]),
            ("authorizeFixtureCapacityLedgerRead",[:]),("cancelCapacityAllocation",[:])] {
            XCTAssertNotNil(try request(method,params)["error"])
        }
        let binary = URL(fileURLWithPath:try XCTUnwrap(ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"])).appendingPathComponent("macnas")
        for (user,approved,status) in [("fixture-owner",false,Int32(0)),("fixture-owner",true,Int32(0)),("fixture-family",true,Int32(1))] {
            let process = Process(), input = Pipe(), output = Pipe(), errors = Pipe()
            process.executableURL = binary; process.arguments = ["bridge","fixture","--source",root.path,"--user",user]+(approved ? ["--approve-synthetic-capacity-ledger-read"]:[])
            process.environment = ProcessInfo.processInfo.environment;process.standardInput=input;process.standardOutput=output;process.standardError=errors
            let timer = DispatchSource.makeTimerSource(queue:DispatchQueue.global());timer.schedule(deadline:.now()+120)
            timer.setEventHandler{if process.isRunning{process.terminate()}};timer.resume()
            defer{timer.cancel();if process.isRunning{process.terminate()}}
            try process.run()
            if user == "fixture-owner" {
                try input.fileHandleForWriting.write(contentsOf:JSONSerialization.data(withJSONObject:["apiVersion":1,"requestId":"cli-read","method":"capacityLedgerContext","params":[:]])+Data([10]))
            }
            try input.fileHandleForWriting.close();let bytes = try output.fileHandleForReading.readToEnd() ?? Data();process.waitUntilExit()
            let diagnostics = try errors.fileHandleForReading.readToEnd() ?? Data()
            XCTAssertEqual(process.terminationStatus,status,String(decoding:diagnostics,as:UTF8.self))
            if user == "fixture-owner" {
                let reply = try XCTUnwrap(JSONSerialization.jsonObject(with:bytes) as? [String:Any])
                if approved {XCTAssertEqual((reply["data"] as? [String:Any])?["scopeID"] as? String,host.registration.scopeID.uuidString.lowercased())}
                else{XCTAssertEqual((reply["error"] as? [String:Any])?["code"] as? String,"denied")}
            }else{XCTAssertTrue(bytes.isEmpty)}
        }
        XCTAssertEqual(try host.store.contentDigest(),before)
    }
}
