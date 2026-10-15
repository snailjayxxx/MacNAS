import Foundation

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
    let fixtureVolumes: FixtureVolumeRegistry
    let fixtureContent = FixtureContentRegistry()
    let jobPages = JobPageRegistry()
    private let sessionLock=NSLock()
    private var sessions:[UUID:String]=[:]
    private var libraries:[UUID:URL]=[:]
    public init(root:URL,registry:SamplePluginRegistry=SamplePluginRegistry()) throws {
        self.root=root;self.registry=registry
        instanceID=try PortableInstance.validateLayout(root,exported:false).instanceID
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
    public func endSession(_ session:PrototypeSession) { sessionLock.lock();sessions.removeValue(forKey:session.id);sessionLock.unlock(); fixtureVolumes.endSession(session.id);jobPages.endSession(session.id) }
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
    private func pageScope(_ session:PrototypeSession) throws -> JobPageScope {
        let caller=try user(session),identity=try PortableInstance.validateLayout(root,exported:false).instanceID
        try require(identity==instanceID,.denied)
        let binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
        return JobPageScope(sessionID:session.id,instanceID:identity,databaseName:try PortableInstance.store(root).databaseName,
                            userID:Data(caller.id.utf8),role:caller.role,mode:binding.mode)
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
