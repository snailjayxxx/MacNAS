import Foundation
import CryptoKit

public enum JobAudience: Equatable, Sendable {
    case user(String), app(SampleApp)
    func predicate(_ prefix:String="") throws -> String {
        switch self {
        case .user(let id):
            try require(!id.isEmpty && id.utf8.count<=128,.invalidSchema)
            return try "\(prefix)owner_user=\(StateStore.quote(id)) AND \(prefix)app_id IS NULL"
        case .app(let app): return "\(prefix)app_id='\(app.rawValue)' AND \(prefix)owner_user IS NULL"
        }
    }
    var userID:String? { if case .user(let id)=self { return id };return nil }
    var appID:String? { if case .app(let app)=self { return app.rawValue };return nil }
}
public enum DurableJobKind:String,Codable,Sendable { case label,appValue,fixtureHash }
public struct JobPayload:Codable,Equatable,Sendable {
    public var target:String
    public var value:String
    public var relativePath:String?
    public var volumeID:UUID?
    public init(target:String,value:String="",relativePath:String?=nil,volumeID:UUID?=nil) {
        self.target=target;self.value=value;self.relativePath=relativePath;self.volumeID=volumeID
    }
}
public struct DurableJob:Codable,Equatable,Sendable {
    public var id:String
    public var idempotency_key:String
    public var kind:DurableJobKind
    public var owner_user:String?
    public var app_id:String?
    public var payload:JobPayload
    public var state:String
    public var attempts:Int
    public var max_attempts:Int
    public var effects:Int
    public var revision:Int
    public var checkpoint:[String:String]
    public var last_error:String?
}
public struct JobLease:Sendable {
    public let job:DurableJob
    let token:UUID
    let databaseName:String
}
public struct JobEvent:Codable,Equatable,Sendable {
    public var sequence:Int64
    public var job_id:String
    public var revision:Int
    public var type:String
    public var state:String
}
public enum EventConsumerVisibility:String,Codable,Sendable { case visible,notVisible }
public struct EventConsumerStatus:Codable,Equatable,Sendable {
    public let consumerID:String
    public let visibility:EventConsumerVisibility
    public let acknowledgedThrough:Int64?
    public let deliveredThrough:Int64?
}
public struct DurableJobStatistics: Codable, Equatable, Sendable {
    public let active:Int64
    public let completed:Int64
    public let total:Int64
}
public struct DurableJobSlice: Sendable {
    public let items:[DurableJob]
    public let hasMore:Bool
}

/// Trusted core coordinator, never handed to native samples. PostgreSQL clock governs task leases.
public final class DurableJobQueue {
    let store:StateStore
    public init(store:StateStore) throws {
        let version=try store.schemaVersion();try require([3,4].contains(version),.unsupported)
        try store.validate(expectedVersion:version);self.store=store
    }
    private static let viewColumns="id,idempotency_key,kind,owner_user,app_id,payload,state,attempts,max_attempts,effects,revision,checkpoint,last_error"
    private static let eventColumns="sequence,job_id,revision,type,state"
    private func decode<T:Decodable>(_ type:T.Type,_ output:String) throws -> T {
        try JSONDecoder().decode(type,from:Data(output.utf8))
    }
    private func writable() throws {
        if let root=store.instanceRoot {
            let binding=try PortableInstance.strictRead(HostBinding.self,SafeFS.resolve(root,"host-binding/binding.json"))
            try require(binding.mode=="synthetic_development",.denied)
        }
    }
    // A transaction-held row serializes event allocation through commit, avoiding sequence/commit cursor gaps.
    // This deliberately trades throughput for a small, auditable prototype; it is not pool fencing.
    private func mutation<T:Decodable>(_ type:T.Type,body:String,clock:Bool=true,faultBeforeCommit:Bool=false) throws -> T? {
        try store.withMutation {
            try writable()
            let delimiter="$macnas_"+UUID().uuidString.replacingOccurrences(of:"-",with:"")+"$"
            try require(!body.contains(delimiter),.invalidSchema)
            let sql="""
            BEGIN;
            SET LOCAL lock_timeout='5000ms';
            SET LOCAL statement_timeout='10000ms';
            CREATE TEMP TABLE macnas_result(value jsonb) ON COMMIT DROP;
            DO \(delimiter)
            DECLARE j macnas.jobs%ROWTYPE; seq bigint; c macnas.event_consumers%ROWTYPE;
            BEGIN
            \(clock ? "PERFORM next_sequence FROM macnas.event_clock WHERE singleton FOR UPDATE;" : "")
            \(body)
            END \(delimiter);
            SELECT value::text FROM macnas_result;
            \(faultBeforeCommit ? "SELECT 1/0;" : "")
            COMMIT;
            """
            let output=try store.tools.sql(sql,database:store.databaseName)
            return output.isEmpty ? nil : try decode(type,output)
        }
    }
    private static func emit(_ type:String) -> String {
        """
        UPDATE macnas.event_clock SET next_sequence=next_sequence+1 WHERE singleton RETURNING next_sequence-1 INTO seq;
        INSERT INTO macnas.job_events(sequence,job_id,revision,owner_user,app_id,type,state)
        VALUES(seq,j.id,j.revision,j.owner_user,j.app_id,'\(type)',j.state);
        """
    }
    private static let result="INSERT INTO macnas_result SELECT to_jsonb(t) FROM (SELECT \(viewColumns) FROM macnas.jobs WHERE id=j.id) t;"
    private func leaseGuard(_ lease:JobLease) throws -> String {
        try require(lease.databaseName==store.databaseName,.denied)
        return try "id=\(StateStore.quote(lease.job.id)) AND state='running' AND lease_token='\(lease.token.uuidString)'::uuid AND lease_until>clock_timestamp()"
    }
    @discardableResult
    public func submit(id:String,key:String,kind:DurableJobKind,payload:JobPayload,audience:JobAudience,maxAttempts:Int=3) throws -> DurableJob {
        try require(!id.isEmpty && id.utf8.count<=128 && !key.isEmpty && key.utf8.count<=128 && (1...8).contains(maxAttempts),.invalidSchema)
        _=try audience.predicate();try require(!payload.target.isEmpty && payload.target.utf8.count<=128 && payload.value.utf8.count<=1024,.invalidSchema)
        switch (kind,audience) {
        case (.label,.user),(.fixtureHash,.user): break
        case (.appValue,.app): break
        default: throw NASError.denied
        }
        if kind == .fixtureHash { guard let path=payload.relativePath, payload.volumeID != nil else { throw NASError.invalidSchema };try SafeFS.relative(path) }
        else { try require(payload.relativePath==nil && payload.volumeID==nil,.invalidSchema) }
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
        let json=String(decoding:try encoder.encode(payload),as:UTF8.self)
        func nullable(_ s:String?) throws -> String { try s.map(StateStore.quote) ?? "NULL" }
        let body=try """
        INSERT INTO macnas.jobs(id,idempotency_key,state,kind,owner_user,app_id,payload,max_attempts,revision)
        VALUES(\(StateStore.quote(id)),\(StateStore.quote(key)),'queued','\(kind.rawValue)',\(nullable(audience.userID)),\(nullable(audience.appID)),\(StateStore.quote(json))::jsonb,\(maxAttempts),1)
        ON CONFLICT DO NOTHING RETURNING * INTO j;
        IF FOUND THEN
        \(Self.emit("queued"))
        ELSE
          SELECT * INTO j FROM macnas.jobs WHERE idempotency_key=\(StateStore.quote(key)) AND \(audience.predicate())
            AND kind='\(kind.rawValue)' AND payload=\(StateStore.quote(json))::jsonb AND max_attempts=\(maxAttempts);
          IF NOT FOUND THEN RETURN; END IF;
        END IF;
        \(Self.result)
        """
        guard let job=try mutation(DurableJob.self,body:body) else { throw NASError.collision };return job
    }
    public func jobs(audience:JobAudience) throws -> [DurableJob] {
        // The legacy array remains complete or fails explicitly; never silently truncate it.
        let output=try readQuery("""
        WITH selected AS MATERIALIZED (
          SELECT \(Self.viewColumns) FROM macnas.jobs WHERE kind<>'legacy' AND \(audience.predicate())
          ORDER BY id COLLATE "C" LIMIT 4097
        ) SELECT CASE WHEN count(*)>4096 THEN 'null'::jsonb
          ELSE coalesce(jsonb_agg(to_jsonb(selected) ORDER BY id COLLATE "C"),'[]') END FROM selected;
        """)
        try require(output != "null",.budgetExceeded)
        return try decode([DurableJob].self,output)
    }
    private func readQuery(_ sql:String) throws -> String {
        try store.tools.sql("BEGIN READ ONLY; SET LOCAL lock_timeout='5000ms'; SET LOCAL statement_timeout='10000ms'; \(sql) COMMIT;",database:store.databaseName)
    }
    public func statistics(audience:JobAudience) throws -> DurableJobStatistics {
        try decode(DurableJobStatistics.self,readQuery("""
        SELECT jsonb_build_object('active',count(*) FILTER (WHERE state IN ('queued','running','waiting_for_volume')),
          'completed',count(*) FILTER (WHERE state='completed'),'total',count(*))
        FROM macnas.jobs WHERE kind<>'legacy' AND \(audience.predicate());
        """))
    }
    public func page(audience:JobAudience,afterID:String?=nil,pageSize:Int=50) throws -> DurableJobSlice {
        try require((1...100).contains(pageSize),.invalidSchema)
        if let afterID { try require(!afterID.isEmpty && afterID.utf8.count<=128,.invalidSchema) }
        let after=try afterID.map { try " AND id COLLATE \"C\">\(StateStore.quote($0)) COLLATE \"C\"" } ?? ""
        let output=try readQuery("""
        SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY id COLLATE "C"),'[]') FROM (
          SELECT \(Self.viewColumns) FROM macnas.jobs WHERE kind<>'legacy' AND \(audience.predicate())\(after)
          ORDER BY id COLLATE "C" LIMIT \(pageSize+1)
        ) t;
        """)
        let jobs=try decode([DurableJob].self,output)
        return DurableJobSlice(items:Array(jobs.prefix(pageSize)),hasMore:jobs.count>pageSize)
    }
    public func claim(leaseSeconds:TimeInterval=5) throws -> JobLease? {
        try require(leaseSeconds>=0.1 && leaseSeconds<=30,.invalidSchema)
        let token=UUID()
        let body="""
        SELECT * INTO j FROM macnas.jobs
        WHERE kind<>'legacy' AND (
          (state IN ('queued','waiting_for_volume') AND next_run_at<=clock_timestamp()) OR
          (state='running' AND lease_until<=clock_timestamp()))
        ORDER BY next_run_at,id LIMIT 1 FOR UPDATE SKIP LOCKED;
        IF NOT FOUND THEN RETURN; END IF;
        IF j.attempts>=j.max_attempts THEN
          UPDATE macnas.jobs SET state='failed',last_error='attemptsExhausted',lease_token=NULL,lease_until=NULL,revision=revision+1 WHERE id=j.id RETURNING * INTO j;
          \(Self.emit("failed"))
          RETURN;
        END IF;
        UPDATE macnas.jobs SET state='running',attempts=attempts+1,lease_token='\(token.uuidString)'::uuid,
          lease_until=clock_timestamp()+\(leaseSeconds)*interval '1 second',last_error=NULL,revision=revision+1
          WHERE id=j.id RETURNING * INTO j;
        \(Self.emit("claimed"))
        \(Self.result)
        """
        guard let job=try mutation(DurableJob.self,body:body) else { return nil }
        return JobLease(job:job,token:token,databaseName:store.databaseName)
    }
    public func renew(_ lease:JobLease,seconds:TimeInterval=5) throws {
        try require(seconds>=0.1 && seconds<=30,.invalidSchema)
        let body=try """
        UPDATE macnas.jobs SET lease_until=clock_timestamp()+\(seconds)*interval '1 second' WHERE \(leaseGuard(lease)) RETURNING * INTO j;
        IF NOT FOUND THEN RETURN; END IF;
        \(Self.result)
        """
        try require(try mutation(DurableJob.self,body:body,clock:false) != nil,.staleState)
    }
    @discardableResult
    public func cancel(id:String,audience:JobAudience) throws -> DurableJob {
        let body=try """
        SELECT * INTO j FROM macnas.jobs WHERE id=\(StateStore.quote(id)) AND kind<>'legacy' AND \(audience.predicate()) FOR UPDATE;
        IF NOT FOUND THEN RETURN; END IF;
        IF j.state NOT IN ('completed','failed','cancelled') THEN
          UPDATE macnas.jobs SET state='cancelled',lease_token=NULL,lease_until=NULL,revision=revision+1 WHERE id=j.id RETURNING * INTO j;
          \(Self.emit("cancelled"))
        END IF;
        \(Self.result)
        """
        guard let job=try mutation(DurableJob.self,body:body) else { throw NASError.denied };return job
    }
    // Failed attempts keep completed steps. Waiting for a missing logical volume does not consume a work attempt.
    public func deferWork(_ lease:JobLease,error:NASError,waitingForVolume:Bool=false,retryable:Bool=true,backoff:TimeInterval=0.2) throws {
        try require(backoff>=0.1 && backoff<=30,.invalidSchema)
        let body=try """
        SELECT * INTO j FROM macnas.jobs WHERE \(leaseGuard(lease)) FOR UPDATE;
        IF NOT FOUND THEN RETURN; END IF;
        UPDATE macnas.jobs SET
          state=CASE WHEN \(waitingForVolume ? "true" : "false") THEN 'waiting_for_volume'
            WHEN \(retryable ? "true" : "false") AND attempts<max_attempts THEN 'queued' ELSE 'failed' END,
          attempts=CASE WHEN \(waitingForVolume ? "true" : "false") THEN greatest(attempts-1,0) ELSE attempts END,
          next_run_at=clock_timestamp()+least(30,\(backoff)*power(2,greatest(attempts-1,0)))*interval '1 second',
          last_error='\(error.rawValue)',lease_token=NULL,lease_until=NULL,revision=revision+1
          WHERE id=j.id RETURNING * INTO j;
        \(Self.emit("deferred"))
        \(Self.result)
        """
        try require(try mutation(DurableJob.self,body:body) != nil,.staleState)
    }
    // Read-only fixture work occurs outside SQL; the prepared result is then guarded and checkpointed transactionally.
    public func prepare(_ lease:JobLease,inventory:[MountedVolume]=[],injectFailure:Bool=false) throws {
        try store.withMutation {
            try writable()
            let payload=lease.job.payload
            var result=payload.value
            let prepared=try store.rows("SELECT count(*) FROM macnas.job_steps WHERE job_id=\(StateStore.quote(lease.job.id)) AND step=0;")==[["1"]]
            if lease.job.kind == .fixtureHash && !prepared {
                guard let root=store.instanceRoot,let path=payload.relativePath,let volumeID=payload.volumeID else { throw NASError.denied }
                try VolumeGuard.canWrite(VolumeReference(libraryID:"fixture",volumeID:volumeID,relativePath:path,estimatedBytes:0),inventory:inventory)
                let file=try SafeFS.resolve(SafeFS.resolve(root,"host-binding/fixtures"),path)
                // Bounded fixture reads only. No real pool or external path is bound by this worker.
                let data=try SafeFS.readData(file,maximumBytes:1_000_000)
                result=SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined()
            }
            let json=String(decoding:try JSONEncoder().encode(["value":result]),as:UTF8.self)
            let body=try """
            SELECT * INTO j FROM macnas.jobs WHERE \(leaseGuard(lease)) FOR UPDATE;
            IF NOT FOUND THEN RETURN; END IF;
            IF NOT EXISTS(SELECT 1 FROM macnas.job_steps WHERE job_id=j.id AND step=0) THEN
              INSERT INTO macnas.job_steps VALUES(j.id,0,\(StateStore.quote(json))::jsonb);
              UPDATE macnas.jobs SET checkpoint='{"step":"prepared"}'::jsonb,revision=revision+1 WHERE id=j.id RETURNING * INTO j;
              \(Self.emit("checkpoint"))
            END IF;
            \(Self.result)
            """
            try require(try mutation(DurableJob.self,body:body,faultBeforeCommit:injectFailure) != nil,.staleState)
        }
    }
    public func finish(_ lease:JobLease,injectFailure:Bool=false) throws {
        let body=try """
        SELECT * INTO j FROM macnas.jobs WHERE \(leaseGuard(lease)) FOR UPDATE;
        IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM macnas.job_steps WHERE job_id=j.id AND step=0) THEN RETURN; END IF;
        IF j.kind IN ('label','fixtureHash') THEN
          INSERT INTO macnas.labels(id,value) SELECT j.payload->>'target',result->>'value' FROM macnas.job_steps WHERE job_id=j.id AND step=0
          ON CONFLICT(id) DO UPDATE SET value=excluded.value;
        ELSIF j.kind='appValue' AND j.app_id='hello-diagnostics' THEN
          INSERT INTO app_hello_diagnostics.state(id,value) SELECT j.payload->>'target',result->>'value' FROM macnas.job_steps WHERE job_id=j.id AND step=0
          ON CONFLICT(id) DO UPDATE SET value=excluded.value,revision=app_hello_diagnostics.state.revision+1;
        ELSIF j.kind='appValue' AND j.app_id='sample-file-index' THEN
          INSERT INTO app_sample_file_index.state(id,value) SELECT j.payload->>'target',result->>'value' FROM macnas.job_steps WHERE job_id=j.id AND step=0
          ON CONFLICT(id) DO UPDATE SET value=excluded.value,revision=app_sample_file_index.state.revision+1;
        ELSE RAISE EXCEPTION 'unsupported job'; END IF;
        INSERT INTO macnas.job_steps VALUES(j.id,1,'{"effect":"committed"}'::jsonb);
        UPDATE macnas.jobs SET state='completed',effects=effects+1,checkpoint='{"step":"completed"}'::jsonb,
          lease_token=NULL,lease_until=NULL,revision=revision+1 WHERE id=j.id RETURNING * INTO j;
        \(Self.emit("completed"))
        \(Self.result)
        """
        try require(try mutation(DurableJob.self,body:body,faultBeforeCommit:injectFailure) != nil,.staleState)
    }
    public func workOne(inventory:[MountedVolume]=[],leaseSeconds:TimeInterval=5,cancellation:CancellationToken?=nil) throws -> String? {
        try cancellation?.check()
        guard let lease=try claim(leaseSeconds:leaseSeconds) else { return nil }
        do {
            try cancellation?.check();try prepare(lease,inventory:inventory);try cancellation?.check();try finish(lease)
        } catch {
            let reason=(error as? NASError) ?? .invalidSchema
            if reason == .cancelled { _=try cancel(id:lease.job.id,audience:lease.job.app_id.flatMap(SampleApp.init(rawValue:)).map(JobAudience.app) ?? .user(lease.job.owner_user ?? "")) }
            else if reason != .staleState {
                try deferWork(lease,error:reason,waitingForVolume:reason == .missingVolume,retryable:reason == .database || reason == .timedOut)
            }
            throw error
        }
        return lease.job.id
    }
    public func poll(consumerID:String,audience:JobAudience,limit:Int=50) throws -> [JobEvent] {
        try require(!consumerID.isEmpty && consumerID.utf8.count<=128 && (1...100).contains(limit),.invalidSchema)
        func nullable(_ s:String?) throws -> String { try s.map(StateStore.quote) ?? "NULL" }
        let body=try """
        INSERT INTO macnas.event_consumers(id,owner_user,app_id) VALUES(\(StateStore.quote(consumerID)),\(nullable(audience.userID)),\(nullable(audience.appID))) ON CONFLICT DO NOTHING;
        SELECT * INTO c FROM macnas.event_consumers WHERE id=\(StateStore.quote(consumerID)) AND \(audience.predicate()) FOR UPDATE;
        IF NOT FOUND THEN RETURN; END IF;
        INSERT INTO macnas_result
        SELECT coalesce(jsonb_agg(to_jsonb(t) ORDER BY sequence),'[]') FROM
          (SELECT \(Self.eventColumns) FROM macnas.job_events WHERE sequence>c.ack_sequence AND \(audience.predicate()) ORDER BY sequence LIMIT \(limit)) t;
        UPDATE macnas.event_consumers SET delivered_sequence=greatest(delivered_sequence,
          coalesce((SELECT max((item->>'sequence')::bigint) FROM macnas_result,jsonb_array_elements(value) item),ack_sequence)) WHERE id=c.id;
        """
        guard let events=try mutation([JobEvent].self,body:body,clock:false) else { throw NASError.denied };return events
    }
    /// A single read-only statement observes only this audience's row. Missing and foreign rows are indistinguishable.
    public func consumerStatus(consumerID:String,audience:JobAudience) throws -> EventConsumerStatus {
        try require(!consumerID.isEmpty && consumerID.utf8.count<=128,.invalidSchema)
        let output=try readQuery("""
        SELECT coalesce((SELECT jsonb_build_object('consumerID',id,'visibility','visible',
          'acknowledgedThrough',ack_sequence,'deliveredThrough',delivered_sequence)
          FROM macnas.event_consumers WHERE id=\(StateStore.quote(consumerID)) AND \(audience.predicate())),
          jsonb_build_object('consumerID',\(StateStore.quote(consumerID)),'visibility','notVisible',
          'acknowledgedThrough',NULL,'deliveredThrough',NULL));
        """)
        let result=try decode(EventConsumerStatus.self,output)
        try require(Data(result.consumerID.utf8)==Data(consumerID.utf8),.integrity)
        if result.visibility == .visible {
            guard let ack=result.acknowledgedThrough,let delivered=result.deliveredThrough else { throw NASError.integrity }
            try require(ack>=0 && delivered>=ack,.integrity)
        } else { try require(result.acknowledgedThrough==nil && result.deliveredThrough==nil,.integrity) }
        return result
    }
    public func acknowledge(consumerID:String,through sequence:Int64,audience:JobAudience,injectFailure:Bool=false) throws {
        try require(sequence>=0,.invalidSchema)
        let body=try """
        SELECT * INTO c FROM macnas.event_consumers WHERE id=\(StateStore.quote(consumerID)) AND \(audience.predicate()) FOR UPDATE;
        IF NOT FOUND OR \(sequence)<c.ack_sequence OR \(sequence)>c.delivered_sequence THEN RETURN; END IF;
        IF \(sequence)<>c.ack_sequence AND NOT EXISTS(SELECT 1 FROM macnas.job_events WHERE sequence=\(sequence) AND \(audience.predicate())) THEN RETURN; END IF;
        INSERT INTO macnas.event_receipts SELECT c.id,sequence FROM macnas.job_events
          WHERE sequence>c.ack_sequence AND sequence<=\(sequence) AND \(audience.predicate()) ON CONFLICT DO NOTHING;
        UPDATE macnas.event_consumers SET ack_sequence=\(sequence) WHERE id=c.id;
        INSERT INTO macnas_result VALUES('true'::jsonb);
        """
        try require(try mutation(Bool.self,body:body,clock:false,faultBeforeCommit:injectFailure) == true,.denied)
    }
}
