import Foundation

public struct DurableJobPage: Sendable {
    public let pageSize:Int
    public let items:[DurableJob]
    public let nextCursor:String?
}

// Memory-only continuation capabilities. Neither tokens nor sorting keys are SQL from the caller.
struct JobPageScope: Equatable {
    let sessionID:UUID
    let instanceID:UUID
    let databaseName:String
    let userID:Data
    let role:String
    let mode:String
}
final class JobPageRegistry: @unchecked Sendable {
    private struct Entry {
        let scope:JobPageScope
        let size:Int
        let afterID:String
        let deadline:TimeInterval
    }
    private let lock=NSLock()
    private var pending:[UUID:Entry]=[:]
    private var consumed:[UUID:TimeInterval]=[:]
    private let capacity:Int
    private let lifetime:TimeInterval
    private let now:() -> TimeInterval
    init(capacity:Int=128,lifetime:TimeInterval=60,now:@escaping () -> TimeInterval={ProcessInfo.processInfo.systemUptime}) {
        self.capacity=capacity;self.lifetime=lifetime;self.now=now
    }
    func endSession(_ id:UUID) {
        lock.lock();defer { lock.unlock() }
        pending=pending.filter { $0.value.scope.sessionID != id }
    }
    func page<T>(scope:JobPageScope,size:Int,cursor:String?,query:(String?) throws -> DurableJobSlice,
                 validate:() throws -> Void,render:(DurableJobPage) throws -> T) throws -> T {
        try require((1...100).contains(size),.invalidSchema)
        let token:UUID?
        if let cursor {
            try require(cursor.utf8.count==36 && UUID(uuidString:cursor)?.uuidString.lowercased()==cursor,.invalidSchema)
            token=UUID(uuidString:cursor)
        } else { token=nil }
        lock.lock();defer { lock.unlock() }
        let time=now()
        consumed=consumed.filter { $0.value>time }
        var previous:Entry?
        if let token {
            if consumed[token] != nil { throw NASError.replay }
            guard let entry=pending[token] else { throw NASError.denied }
            try require(entry.scope==scope && entry.size==size,.denied)
            if entry.deadline<=time { pending.removeValue(forKey:token);throw NASError.expired }
            previous=entry
        }
        pending=pending.filter { $0.value.deadline>time }
        let slice=try query(previous?.afterID)
        try validate()
        let deadline=previous?.deadline ?? (time+lifetime)
        try require(now()<deadline,.expired)
        let next = slice.hasMore ? UUID() : nil
        if next != nil { try require(pending.count-(token == nil ? 0 : 1)<capacity,.budgetExceeded) }
        // Complete DTO encoding/budget checks before consuming the old capability.
        let result=try render(DurableJobPage(pageSize:size,items:slice.items,nextCursor:next?.uuidString.lowercased()))
        if let token {
            pending.removeValue(forKey:token)
            if consumed.count>=capacity,let oldest=consumed.min(by:{$0.value<$1.value}) { consumed.removeValue(forKey:oldest.key) }
            consumed[token]=deadline
        }
        if let next,let last=slice.items.last { pending[next]=Entry(scope:scope,size:size,afterID:last.id,deadline:deadline) }
        return result
    }
}
