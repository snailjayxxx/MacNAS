import Foundation
import CryptoKit

/// Opaque equality context for the trusted fixture pipe, not a production authentication credential.
public struct EventSourceContext: Codable, Equatable {
    public let contextVersion: Int
    public let source: String
    public let scopeID: String
    public let userID: String
    public let role: String
    public let mode: String
}
public struct EventConsumerObservation {
    public let context: EventSourceContext
    public let status: EventConsumerStatus
}

public struct PrototypeSession: Sendable {
    let id:UUID
    fileprivate init(_ id:UUID) { self.id=id }
}
public struct PrototypeOverview: Codable {
    public var apiVersion=1
    public var userID:String
    public var role:String
    public var languages:[String]
    public var databaseSchema:Int
    public var mode:String
}
public enum SampleExecution: String { case normal, simulateCrash, simulateHang, simulateOutputFlood }
public struct SampleBudget {
    public var seconds:TimeInterval
    public var outputBytes:Int
    public init(seconds:TimeInterval=5,outputBytes:Int=65536) { self.seconds=seconds;self.outputBytes=outputBytes }
}

/// Typed business API without a listener. Fixture sessions simulate authentication and are not production login.
public final class PrototypePlatformAPI: @unchecked Sendable {
    public let root:URL
    public let registry:SamplePluginRegistry
    private let instanceID:UUID
    private let recycleObservationAnchor: RecycleObservationAnchor
    private let recycleObservationSourceNonce = Data((UUID().uuidString + UUID().uuidString).utf8)
    let recycleObservationReads = RecycleObservationRegistry()
    let fixtureVolumes: FixtureVolumeRegistry
    let fixtureContent = FixtureContentRegistry()
    let jobPages = JobPageRegistry()
    let directoryPages = DirectoryPageRegistry()
    let fileOperations = FileOperationRegistry()
    let fileTransfers = FileTransferRegistry()
    let fileCopies = FileCopyRegistry()
    private let sessionLock=NSLock()
    private var sessions:[UUID:String]=[:]
    private var libraries:[UUID:URL]=[:]
    public init(root:URL,registry:SamplePluginRegistry=SamplePluginRegistry()) throws {
        self.root=root;self.registry=registry
        let identity = try PortableInstance.validateLayout(root,exported:false)
        instanceID = identity.instanceID
        recycleObservationAnchor = try RecycleObservationAnchor(root: root, identity: identity)
        fixtureVolumes = try FixtureVolumeRegistry(references: PortableInstance.strictRead([VolumeReference].self, SafeFS.resolve(root, "logical-storage/references.json")))
        for app in SampleApp.allCases {
            try registry.register(PortableInstance.strictRead(PluginManifest.self,SafeFS.resolve(root,"apps/\(app.rawValue)/manifest.json")))
        }
    }
    private func config() throws -> PortableConfig { try PortableInstance.strictRead(PortableConfig.self,SafeFS.resolve(root,"config/platform.json")) }
    public func beginFixtureSession(userID:String) throws -> PrototypeSession {
        try require(try config().users.contains { $0.id == userID },.denied)
        let id=UUID();sessionLock.lock();sessions[id]=userID;sessionLock.unlock();return PrototypeSession(id)
    }
    func user(_ session:PrototypeSession,administrator:Bool=false) throws -> LogicalUser {
        sessionLock.lock();let id=sessions[session.id];sessionLock.unlock()
        guard let id,let user=try config().users.first(where:{$0.id==id}) else { throw NASError.denied }
        try require(!administrator || user.role == "administrator",.denied);return user
    }
    public func endSession(_ session:PrototypeSession) { sessionLock.lock();sessions.removeValue(forKey:session.id);sessionLock.unlock(); fixtureVolumes.endSession(session.id);jobPages.endSession(session.id);directoryPages.endSession(session.id);fileOperations.endSession(session.id);fileTransfers.endSession(session.id);fileCopies.endSession(session.id);recycleObservationReads.endSession(session.id) }
    private func writable() throws {
        let binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
        try require(binding.mode == "synthetic_development",.denied)
    }
    public func overview(session:PrototypeSession) throws -> PrototypeOverview {
        let user=try user(session),binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
        return PrototypeOverview(userID:user.id,role:user.role,languages:try config().languages,databaseSchema:try PortableInstance.store(root).schemaVersion(),mode:binding.mode)
    }
    func withManagedWrite<T>(timeout:TimeInterval=10,_ body:() throws -> T) throws -> T {
        let lock=try InstanceLock(root,mode:.shared,timeout:timeout)
        return try withExtendedLifetime(lock) { try writable();return try body() }
    }
    public func setLanguages(_ languages:[String],session:PrototypeSession) throws {
        _=try user(session,administrator:true)
        try require(!languages.isEmpty && Set(languages).count==languages.count && Set(languages).isSubset(of:["zh-CN","ja-JP"]),.invalidSchema)
        try withManagedWrite {
            let serial=try InstanceLock(file:SafeFS.resolve(root,"host-binding/configuration.lock"),timeout:10)
            try withExtendedLifetime(serial) {
                _=try user(session,administrator:true)
                var next=try config();next.languages=languages
                try SafeFS.write(next,to:SafeFS.resolve(root,"config/platform.json"))
            }
        }
    }
    public func writeLabel(id:String,value:String,session:PrototypeSession) throws {
        _=try user(session,administrator:true)
        try withManagedWrite { try PortableInstance.store(root).label(id,value) }
    }
    public func enqueue(id:String,key:String,session:PrototypeSession) throws {
        _=try user(session,administrator:true)
        try withManagedWrite {
            let db=try PortableInstance.store(root);try require(try db.schemaVersion()<3,.unsupported)
            try db.enqueue(id,key:key)
        }
    }

    public func submitLabelJob(id:String,key:String,label:String,value:String,session:PrototypeSession) throws -> DurableJob {
        let caller=try user(session,administrator:true)
        return try withManagedWrite {
            _=try user(session,administrator:true)
            return try DurableJobQueue(store:PortableInstance.store(root)).submit(id:id,key:key,kind:.label,payload:JobPayload(target:label,value:value),audience:.user(caller.id))
        }
    }
    public func durableJobs(session:PrototypeSession) throws -> [DurableJob] {
        let caller=try user(session)
        return try DurableJobQueue(store:PortableInstance.store(root)).jobs(audience:.user(caller.id))
    }
    public func jobStatistics(session:PrototypeSession) throws -> DurableJobStatistics {
        let caller=try user(session)
        return try DurableJobQueue(store:PortableInstance.store(root)).statistics(audience:.user(caller.id))
    }
    func pageScope(_ session:PrototypeSession) throws -> JobPageScope {
        let caller=try user(session),identity=try PortableInstance.validateLayout(root,exported:false).instanceID
        try require(identity==instanceID,.denied)
        let binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
        return JobPageScope(sessionID:session.id,instanceID:identity,databaseName:try PortableInstance.store(root).databaseName,
                            userID:Data(caller.id.utf8),role:caller.role,mode:binding.mode)
    }
    /// Metadata-only live checks: never open an old library/vault or launch SQL from a chunk check.
    func recycleObservationScope(_ session: PrototypeSession) throws -> RecycleObservationReadScope {
        sessionLock.lock(); let raw = sessions[session.id]; sessionLock.unlock()
        guard let raw else { throw NASError.denied }
        let userID = Data(raw.utf8); try FileEffectMetadata.subject(userID)
        let config = try self.config(), matches = config.users.filter { Data($0.id.utf8) == userID }
        try require(config.schemaVersion == 1 && matches.count == 1 && matches[0].role == "administrator", .denied)
        let identity = try PortableInstance.strictRead(InstanceIdentity.self, SafeFS.resolve(root, "instance.json"))
        try require(identity.schemaVersion == 1 && identity.kind == "synthetic-prototype" && identity.generation >= 0 && identity.instanceID == instanceID, .denied)
        let anchor = try RecycleObservationAnchor(root: root, identity: identity)
        try require(anchor == recycleObservationAnchor, .denied); try require([4,5,6].contains(anchor.databaseSchema), .unsupported)
        let binding = try PortableInstance.strictRead(HostBinding.self, SafeFS.resolve(root, "host-binding/binding.json"))
        try require(["synthetic_development","read_only_recovery","rolled_back_recovery"].contains(binding.mode), .denied)
        return .init(sessionID: session.id, anchor: anchor, userID: userID, role: matches[0].role, mode: binding.mode)
    }
    func makeRecycleObservationContext(scope: RecycleObservationReadScope, registration: RecycleVaultRegistration) throws -> RecycleObservationContext {
        let parts = [Data("macnas-recycle-observation-source-v1".utf8),
            Data(scope.sessionID.uuidString.lowercased().utf8), Data(scope.anchor.instanceID.uuidString.lowercased().utf8),
            Data(String(scope.anchor.generation).utf8), scope.anchor.databaseName, scope.anchor.hostID, scope.userID,
            Data(scope.role.utf8), Data(scope.mode.utf8), try FileEffectMetadata.encoded(registration)]
        var framed = Data()
        for part in parts { framed.append(Data("\(part.count):".utf8)); framed.append(part) }
        let marker = HMAC<SHA256>.authenticationCode(for: framed, using: SymmetricKey(data: recycleObservationSourceNonce))
            .map { String(format: "%02x", $0) }.joined()
        return .init(scopeID: marker, userID: String(decoding: scope.userID, as: UTF8.self), role: scope.role, mode: scope.mode)
    }
    public func jobPage(pageSize:Int=50,cursor:String?=nil,session:PrototypeSession) throws -> DurableJobPage {
        try withJobPage(pageSize:pageSize,cursor:cursor,session:session) { $0 }
    }
    func withJobPage<T>(pageSize:Int,cursor:String?,session:PrototypeSession,_ render:(DurableJobPage) throws -> T) throws -> T {
        let scope=try pageScope(session),queue=try DurableJobQueue(store:PortableInstance.store(root))
        try require(queue.store.databaseName==scope.databaseName,.denied)
        return try jobPages.page(scope:scope,size:pageSize,cursor:cursor,query: {
            try queue.page(audience:.user(String(decoding:scope.userID,as:UTF8.self)),afterID:$0,pageSize:pageSize)
        },validate: { try require(try self.pageScope(session)==scope,.denied) },render:render)
    }
    public func cancelJob(id:String,session:PrototypeSession) throws -> DurableJob {
        let caller=try user(session)
        return try withManagedWrite { _=try user(session);return try DurableJobQueue(store:PortableInstance.store(root)).cancel(id:id,audience:.user(caller.id)) }
    }
    public func jobEvents(consumerID:String,limit:Int=50,session:PrototypeSession) throws -> [JobEvent] {
        let caller=try user(session)
        return try withManagedWrite { _=try user(session);return try DurableJobQueue(store:PortableInstance.store(root)).poll(consumerID:consumerID,audience:.user(caller.id),limit:limit) }
    }
    public func acknowledgeJobEvents(consumerID:String,through sequence:Int64,session:PrototypeSession) throws {
        let caller=try user(session)
        try withManagedWrite { _=try user(session);try DurableJobQueue(store:PortableInstance.store(root)).acknowledge(consumerID:consumerID,through:sequence,audience:.user(caller.id)) }
    }
    public func jobEventConsumerStatus(consumerID:String,session:PrototypeSession) throws -> EventConsumerStatus {
        try withJobEventConsumerStatus(consumerID:consumerID,session:session) { $0 }
    }
    private struct EventConsumerReadScope:Equatable {
        let identity:InstanceIdentity
        let caller:JobPageScope
    }
    private func eventConsumerReadScope(_ session:PrototypeSession) throws -> EventConsumerReadScope {
        // Construction validates the whole instance; rechecks need only this read's identity and authorization context.
        let caller=try user(session),identity=try PortableInstance.strictRead(InstanceIdentity.self,SafeFS.resolve(root,"instance.json"))
        try require(identity.schemaVersion==1 && identity.kind=="synthetic-prototype" && identity.generation>=0,.invalidSchema)
        try require(identity.instanceID==instanceID && ["administrator","reader"].contains(caller.role),.denied)
        let binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
        try require(["synthetic_development","read_only_recovery","rolled_back_recovery"].contains(binding.mode),.denied)
        try PostgreSQLTools.fixtureName(binding.databaseName)
        return EventConsumerReadScope(identity:identity,caller:JobPageScope(sessionID:session.id,instanceID:identity.instanceID,
            databaseName:binding.databaseName,userID:Data(caller.id.utf8),role:caller.role,mode:binding.mode))
    }
    func withJobEventConsumerStatus<T>(consumerID:String,session:PrototypeSession,_ render:(EventConsumerStatus) throws -> T) throws -> T {
        // Include instance/database/user bytes/role/mode and recheck after the read and final projection.
        let scope=try eventConsumerReadScope(session),queue=try DurableJobQueue(store:PortableInstance.store(root))
        try require(queue.store.databaseName==scope.caller.databaseName,.denied)
        let status=try queue.consumerStatus(consumerID:consumerID,audience:.user(String(decoding:scope.caller.userID,as:UTF8.self)))
        try require(try eventConsumerReadScope(session)==scope,.denied)
        let result=try render(status)
        try require(try eventConsumerReadScope(session)==scope,.denied)
        return result
    }
    private func eventSourceContext(_ scope:EventConsumerReadScope,store:StateStore) throws -> EventSourceContext {
        try require(store.databaseName==scope.caller.databaseName,.denied)
        // Database and relation OIDs distinguish a recreated fixture database/log without writing new metadata.
        let rows=try store.rows("BEGIN READ ONLY; SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms'; SELECT d.oid::text,c.oid::text FROM pg_database d,pg_class c JOIN pg_namespace n ON n.oid=c.relnamespace WHERE d.datname=current_database() AND n.nspname='macnas' AND c.relname='event_consumers' AND c.relkind='r'; COMMIT;")
        try require(rows.count==1 && rows[0].count==2 && rows[0].allSatisfy { UInt64($0) != nil },.invalidSchema)
        let components=["macnas-fixture-event-source-v1",store.tools.socket.path,store.databaseName]+rows[0]+[
            scope.identity.instanceID.uuidString.lowercased(),String(scope.identity.generation),
            String(decoding:scope.caller.userID,as:UTF8.self),scope.caller.role,scope.caller.mode]
        var framed=Data()
        for component in components { let bytes=Data(component.utf8);framed.append(Data("\(bytes.count):".utf8));framed.append(bytes) }
        // Domain-separated HMAC uses the explicitly provisioned synthetic fixture key. Key changes fail closed.
        let key=HKDF<SHA256>.deriveKey(inputKeyMaterial:SymmetricKey(data:try PortableInstance.signingKey().rawRepresentation),
            salt:Data("macnas-fixture-context-key-v1".utf8),info:Data("event-source-equality".utf8),outputByteCount:32)
        let token=HMAC<SHA256>.authenticationCode(for:framed,using:key).map { String(format:"%02x",$0) }.joined()
        return EventSourceContext(contextVersion:1,source:"fixture-host",scopeID:token,
            userID:String(decoding:scope.caller.userID,as:UTF8.self),role:scope.caller.role,mode:scope.caller.mode)
    }
    func withJobEventSourceContext<T>(session:PrototypeSession,_ render:(EventSourceContext) throws -> T) throws -> T {
        let scope=try eventConsumerReadScope(session),context=try eventSourceContext(scope,store:PortableInstance.store(root))
        try require(try eventConsumerReadScope(session)==scope,.denied)
        let result=try render(context)
        try require(try eventConsumerReadScope(session)==scope,.denied)
        try require(try eventSourceContext(scope,store:PortableInstance.store(root))==context,.denied)
        try require(try eventConsumerReadScope(session)==scope,.denied)
        return result
    }
    func withBoundJobEventQueue<T>(context:EventSourceContext,session:PrototypeSession,_ operation:(DurableJobQueue,JobAudience) throws -> T) throws -> T {
        let scope=try eventConsumerReadScope(session),store=try PortableInstance.store(root)
        try require(try eventSourceContext(scope,store:store)==context,.denied)
        let queue=try DurableJobQueue(store:store)
        return try withManagedWrite {
            try require(try self.eventConsumerReadScope(session)==scope,.denied)
            // Use this captured store, never resolve the mutable binding again when executing an event write.
            let result=try operation(queue,.user(String(decoding:scope.caller.userID,as:UTF8.self)))
            try require(try self.eventConsumerReadScope(session)==scope,.denied)
            return result
        }
    }
    public func jobEventConsumerObservation(consumerID:String,session:PrototypeSession) throws -> EventConsumerObservation {
        try withJobEventConsumerObservation(consumerID:consumerID,session:session) { $0 }
    }
    func withJobEventConsumerObservation<T>(consumerID:String,session:PrototypeSession,_ render:(EventConsumerObservation) throws -> T) throws -> T {
        try withJobEventSourceContext(session:session) { context in
            try self.withJobEventConsumerStatus(consumerID:consumerID,session:session) {
                try render(EventConsumerObservation(context:context,status:$0))
            }
        }
    }
    public func submitAppValueJob(id:String,key:String,valueID:String,value:String,grant:PluginGrant) throws -> DurableJob {
        try validate(grant)
        return try withManagedWrite {
            try registry.withGrant(grant,permission:Self.permission(grant.app)) {
                try DurableJobQueue(store:PortableInstance.store(root)).submit(id:id,key:key,kind:.appValue,payload:JobPayload(target:valueID,value:value),audience:.app(grant.app))
            }
        }
    }
    public func appJobs(grant:PluginGrant) throws -> [DurableJob] {
        try validate(grant)
        return try registry.withGrant(grant,permission:Self.permission(grant.app)) { try DurableJobQueue(store:PortableInstance.store(root)).jobs(audience:.app(grant.app)) }
    }
    public func cancelAppJob(id:String,grant:PluginGrant) throws -> DurableJob {
        try validate(grant)
        return try withManagedWrite {
            try registry.withGrant(grant,permission:Self.permission(grant.app)) { try DurableJobQueue(store:PortableInstance.store(root)).cancel(id:id,audience:.app(grant.app)) }
        }
    }
    public func appJobEvents(consumerID:String,limit:Int=50,grant:PluginGrant) throws -> [JobEvent] {
        try validate(grant)
        return try withManagedWrite {
            try registry.withGrant(grant,permission:Self.permission(grant.app)) { try DurableJobQueue(store:PortableInstance.store(root)).poll(consumerID:consumerID,audience:.app(grant.app),limit:limit) }
        }
    }
    public func acknowledgeAppJobEvents(consumerID:String,through sequence:Int64,grant:PluginGrant) throws {
        try validate(grant)
        try withManagedWrite {
            try registry.withGrant(grant,permission:Self.permission(grant.app)) { try DurableJobQueue(store:PortableInstance.store(root)).acknowledge(consumerID:consumerID,through:sequence,audience:.app(grant.app)) }
        }
    }
    static func permission(_ app:SampleApp) -> String { app == .diagnostics ? "diagnostics-read" : "fixture-directory-read" }
    public func issueAppGrant(app:SampleApp,session:PrototypeSession,fixtureLibrary:URL?=nil,lifetime:TimeInterval=300) throws -> PluginGrant {
        _=try user(session,administrator:true)
        if let fixtureLibrary {
            try require(app == .fileIndex,.denied)
            let allowed=try SafeFS.resolve(root,"host-binding/fixtures")
            try require(fixtureLibrary.standardizedFileURL.path==allowed.path || fixtureLibrary.standardizedFileURL.path.hasPrefix(allowed.path+"/"),.unsafePath)
            try SafeFS.inspect(fixtureLibrary)
        }
        let grant=try registry.issue(app:app,instanceID:instanceID,permissions:[Self.permission(app)],lifetime:lifetime)
        if let fixtureLibrary { sessionLock.lock();libraries[grant.id]=fixtureLibrary;sessionLock.unlock() }
        return grant
    }
    private func validate(_ grant:PluginGrant) throws { try require(grant.instanceID==instanceID,.denied) }
    public func appState(grant:PluginGrant) throws -> [[String]] {
        try validate(grant)
        return try registry.withGrant(grant,permission:Self.permission(grant.app)) {
            let db=try PortableInstance.store(root)
            let output=try db.tools.sql("SELECT id,value FROM \(grant.app.schema).state ORDER BY id;",database:db.databaseName,principal:.app(grant.app))
            return output.isEmpty ? [] : output.split(separator:"\n").map { $0.split(separator:"\t",omittingEmptySubsequences:false).map(String.init) }
        }
    }
    public func putAppState(id:String,value:String,grant:PluginGrant) throws {
        try validate(grant)
        try withManagedWrite {
            try registry.withGrant(grant,permission:Self.permission(grant.app)) {
                let db=try PortableInstance.store(root)
                let revision=try db.schemaVersion()>=2 ? ",revision=\(grant.app.schema).state.revision+1" : ""
                _=try db.tools.sql("INSERT INTO \(grant.app.schema).state(id,value) VALUES(\(StateStore.quote(id)),\(StateStore.quote(value))) ON CONFLICT(id) DO UPDATE SET value=excluded.value\(revision);",database:db.databaseName,principal:.app(grant.app))
            }
        }
    }
    public func runSample(grant:PluginGrant,execution:SampleExecution = .normal,budget:SampleBudget=SampleBudget(),cancellation:CancellationToken?=nil) throws -> Data {
        try validate(grant);try writable()
        sessionLock.lock();let library=libraries[grant.id];sessionLock.unlock()
        let output=try TrustedSampleSupervisor.run(grant:grant,registry:registry,library:library,execution:execution,budget:budget,cancellation:cancellation)
        _=try JSONSerialization.jsonObject(with:output)
        try require(output.count<=4096,.budgetExceeded)
        try putAppState(id:"last-result",value:String(decoding:output,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines),grant:grant)
        return output
    }
}

enum TrustedSampleSupervisor {
    static func run(grant:PluginGrant,registry:SamplePluginRegistry,library:URL?,execution:SampleExecution,budget:SampleBudget,cancellation:CancellationToken?) throws -> Data {
        let permission=PrototypePlatformAPI.permission(grant.app)
        let manifest=try registry.manifest(grant,permission:permission)
        try require(budget.seconds>0 && budget.seconds<=Double(manifest.resources["timeoutSeconds"] ?? 0) && budget.outputBytes>0 && budget.outputBytes<=manifest.resources["maximumOutputBytes"] ?? 0,.invalidSchema)
        guard let bin=ProcessInfo.processInfo.environment["MACNAS_BINARY_DIR"] else { throw NASError.unsupported }
        let tools=try PostgreSQLTools(),out=tools.scratch.appendingPathComponent("sample-out-\(UUID().uuidString)"),err=tools.scratch.appendingPathComponent("sample-error-\(UUID().uuidString)")
        FileManager.default.createFile(atPath:out.path,contents:nil);FileManager.default.createFile(atPath:err.path,contents:nil)
        defer { try? FileManager.default.removeItem(at:out);try? FileManager.default.removeItem(at:err) }
        let home=tools.scratch.appendingPathComponent("sample-home-\(UUID().uuidString)")
        try SafeFS.freshDirectory(home)
        defer { if (try? SafeFS.inspect(home)) != nil { try? FileManager.default.removeItem(at:home) } }
        let stdout=try FileHandle(forWritingTo:out),stderr=try FileHandle(forWritingTo:err)
        defer { try? stdout.close();try? stderr.close() }
        let process=Process();process.executableURL=try SafeFS.resolve(URL(fileURLWithPath:bin),grant.app.rawValue)
        if grant.app == .fileIndex {
            guard let library,execution == .normal else { throw NASError.denied }
            try SafeFS.inspect(library);process.arguments=["--granted-synthetic-root",library.path]
        } else { process.arguments=execution == .normal ? [] : [execution == .simulateCrash ? "--simulate-crash" : execution == .simulateHang ? "--simulate-hang" : "--simulate-output-flood"] }
        // No database endpoint, session token, host export signing key or inherited home configuration reaches samples.
        process.environment=["PATH":"/usr/bin:/bin","HOME":home.path,"LANG":"C","LC_ALL":"C"]
        process.standardInput=FileHandle.nullDevice;process.standardOutput=stdout;process.standardError=stderr
        try cancellation?.check();try registry.check(grant,permission:permission);try process.run()
        do {
            let deadline=ProcessInfo.processInfo.systemUptime+budget.seconds
            func check() throws {
                try cancellation?.check();try registry.check(grant,permission:permission)
                let bytes=try [out,err].reduce(0) { $0+((try FileManager.default.attributesOfItem(atPath:$1.path)[.size] as? NSNumber)?.intValue ?? budget.outputBytes+1) }
                try require(bytes<=budget.outputBytes,.budgetExceeded)
            }
            while process.isRunning { try check();try require(ProcessInfo.processInfo.systemUptime<deadline,.timedOut);Thread.sleep(forTimeInterval:0.01) }
            process.waitUntilExit();try check()
            registry.recordExit(grant.app.rawValue,status:process.terminationStatus)
            try require(process.terminationStatus==0,.pluginFailed)
            return try SafeFS.readData(out,maximumBytes:budget.outputBytes)
        } catch {
            ChildControl.stop(process)
            if (error as? NASError) != .cancelled { registry.recordExit(grant.app.rawValue,status:1) }
            throw error
        }
    }
}
