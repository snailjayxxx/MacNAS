import Foundation
import Darwin

public enum FixtureFileOperationKind: String, Codable { case createDirectory, rename }
public struct FixtureFileOperationIntent: Encodable, Equatable {
    public let libraryID: String
    public let parentPath: String
    public let kind: FixtureFileOperationKind
    public let sourceName: String?
    public let name: String
    public init(libraryID: String, parentPath: String = "", kind: FixtureFileOperationKind, sourceName: String? = nil, name: String) throws {
        try require(!libraryID.isEmpty && libraryID.utf8.count <= 128 && !libraryID.contains("\0"), .invalidSchema)
        if !parentPath.isEmpty { try SafeFS.relative(parentPath) }
        try require(parentPath.utf8.count <= 4096 && parentPath.split(separator: "/").count < 128, .budgetExceeded)
        try Self.component(name)
        if kind == .rename { guard let sourceName else { throw NASError.invalidSchema }; try Self.component(sourceName) }
        else { try require(sourceName == nil, .invalidSchema) }
        let target = parentPath.isEmpty ? name : parentPath + "/" + name
        try require(target.utf8.count <= 4096, .budgetExceeded)
        self.libraryID=libraryID; self.parentPath=parentPath; self.kind=kind; self.sourceName=sourceName; self.name=name
    }
    static func component(_ value: String) throws {
        try SafeFS.relative(value)
        try require(!value.contains("/") && value.utf8.count <= 255 && !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, .invalidSchema)
    }
    enum CodingKeys: String, CodingKey { case libraryID,parentPath,kind,sourceName,name }
    public func encode(to encoder: Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(libraryID,forKey:.libraryID);try c.encode(parentPath,forKey:.parentPath);try c.encode(kind,forKey:.kind)
        try c.encodeIfPresent(sourceName,forKey:.sourceName)
        if sourceName == nil { try c.encodeNil(forKey:.sourceName) }
        try c.encode(name,forKey:.name)
    }
}
public struct FixtureFileOperationPreview: Encodable {
    public let previewVersion=1
    public let operationID:String
    public let intent:FixtureFileOperationIntent
    public let state:String
    public let expiresInSeconds:Int
}
public struct FixtureFileOperationResult: Encodable {
    public let resultVersion=1
    public let operationID:String
    public let state:String
    public let intent:FixtureFileOperationIntent?
    public let error:String?
    enum CodingKeys:String,CodingKey { case resultVersion,operationID,state,intent,error }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(resultVersion,forKey:.resultVersion);try c.encode(operationID,forKey:.operationID);try c.encode(state,forKey:.state)
        if let intent { try c.encode(intent,forKey:.intent) } else { try c.encodeNil(forKey:.intent) }
        if let error { try c.encode(error,forKey:.error) } else { try c.encodeNil(forKey:.error) }
    }
}
struct FileOperationScope:Equatable { let directory:DirectoryPageScope;let generation:Int;let writeApproval:UUID }
final class DescriptorMutation {
    let readerID:UUID
    let descriptor:Int32
    let parent:DirectoryStamp
    let source:DirectoryStamp?
    let intent:FixtureFileOperationIntent
    let state:String
    init(readerID:UUID,descriptor:Int32,parent:DirectoryStamp,source:DirectoryStamp?,intent:FixtureFileOperationIntent,state:String) {
        self.readerID=readerID;self.descriptor=descriptor;self.parent=parent;self.source=source;self.intent=intent;self.state=state
    }
    deinit { close(descriptor) }
}
struct FileMutationFailure:Error { let code:NASError;let applied:Bool }

/// Ephemeral per-host receipts, deliberately not a durable job queue or restart guarantee.
final class FileOperationRegistry:@unchecked Sendable {
    private struct Pending { let scope:FileOperationScope;let reader:DescriptorLibrary;let plan:DescriptorMutation;let deadline:TimeInterval }
    private struct Receipt { let scope:FileOperationScope;let result:FixtureFileOperationResult;let deadline:TimeInterval }
    private let lock=NSLock()
    private var pending:[String:Pending]=[:],receipts:[String:Receipt]=[:]
    private let now:()->TimeInterval
    private let capacity:Int
    init(capacity:Int=32,now:@escaping ()->TimeInterval={ProcessInfo.processInfo.systemUptime}) { self.capacity=capacity;self.now=now }
    private func save(_ result:FixtureFileOperationResult,scope:FileOperationScope) {
        if receipts.count>=capacity,let oldest=receipts.min(by:{$0.value.deadline<$1.value.deadline}) { receipts.removeValue(forKey:oldest.key) }
        receipts[result.operationID]=Receipt(scope:scope,result:result,deadline:now()+300)
    }
    private func reclaim() {
        let time=now();receipts=receipts.filter{$0.value.deadline>time}
        for (id,value) in pending.filter({$0.value.deadline<=time}) {
            pending.removeValue(forKey:id)
            save(.init(operationID:id,state:"failed",intent:value.plan.intent,error:NASError.expired.rawValue),scope:value.scope)
        }
    }
    func endSession(_ session:UUID) {
        lock.lock();defer{lock.unlock()}
        pending=pending.filter{$0.value.scope.directory.caller.sessionID != session}
        receipts=receipts.filter{$0.value.scope.directory.caller.sessionID != session}
    }
    func preview<T>(scope:FileOperationScope,reader:DescriptorLibrary,intent:FixtureFileOperationIntent,
                    validate:()throws->Void,render:(FixtureFileOperationPreview)throws->T) throws ->T {
        lock.lock();defer{lock.unlock()};reclaim()
        let plan=try reader.prepareMutation(intent),id=UUID().uuidString.lowercased(),deadline=now()+30
        if plan.state=="ready" { try require(pending.count<capacity,.budgetExceeded) }
        try validate()
        let result=try render(.init(operationID:id,intent:intent,state:plan.state,expiresInSeconds:plan.state=="ready" ? 30:0))
        try validate();try reader.validateMutation(plan);try require(now()<deadline,.expired)
        if plan.state=="ready" { pending[id]=Pending(scope:scope,reader:reader,plan:plan,deadline:deadline) }
        return result
    }
    func commit(id:String,caller:JobPageScope,confirmed:Bool,validate:(FileOperationScope)throws->Void,
                beforeMutation:(()throws->Void)?=nil,afterMutation:(()throws->Void)?=nil) throws ->FixtureFileOperationResult {
        lock.lock();defer{lock.unlock()};reclaim()
        try require(confirmed,.denied)
        if let cached=receipts[id] {
            try require(cached.scope.directory.caller==caller,.denied);try validate(cached.scope);return cached.result
        }
        guard let value=pending[id] else { throw NASError.replay }
        try require(value.scope.directory.caller==caller,.denied)
        pending.removeValue(forKey:id)
        let result:FixtureFileOperationResult
        do {
            try validate(value.scope)
            try value.reader.applyMutation(value.plan,beforeMutation:{
                try beforeMutation?();try require(self.now()<value.deadline,.expired);try validate(value.scope)
            },afterMutation:{ try afterMutation?();try validate(value.scope) })
            result = .init(operationID:id,state:"completed",intent:value.plan.intent,error:nil)
        } catch let failure as FileMutationFailure {
            result = .init(operationID:id,state:failure.applied ? "uncertain":"failed",intent:value.plan.intent,error:failure.code.rawValue)
        } catch {
            result = .init(operationID:id,state:"failed",intent:value.plan.intent,error:(error as? NASError ?? .unsafeFile).rawValue)
        }
        save(result,scope:value.scope);return result
    }
    func status(id:String,caller:JobPageScope,validate:(FileOperationScope)throws->Void) throws ->FixtureFileOperationResult {
        lock.lock();defer{lock.unlock()};reclaim()
        if let value=receipts[id],value.scope.directory.caller==caller { try validate(value.scope);return value.result }
        if let value=pending[id],value.scope.directory.caller==caller { try validate(value.scope);return .init(operationID:id,state:"ready",intent:value.plan.intent,error:nil) }
        return .init(operationID:id,state:"notVisible",intent:nil,error:nil)
    }
}
