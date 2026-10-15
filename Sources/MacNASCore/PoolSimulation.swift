import Foundation

public struct SimulatedMember: Equatable {
    public var id: String; public var enclosure: String; public var bytes: Int64
    public init(_ id: String, _ enclosure: String, _ bytes: Int64) { self.id = id; self.enclosure = enclosure; self.bytes = bytes }
}
/// Mathematical model: mirror of two concatenated sets. Not an AppleRAID driver.
public struct MirrorOfSpans {
    public var left: [SimulatedMember]; public var right: [SimulatedMember]
    public init(left: [SimulatedMember], right: [SimulatedMember]) throws {
        let members = left + right
        try require(!left.isEmpty && !right.isEmpty && members.allSatisfy { $0.bytes > 0 }, .invalidSchema)
        try require(Set(members.map(\.id)).count == members.count, .invalidSchema)
        self.left = left; self.right = right
    }
    public var capacity: Int64 { min(left.reduce(0) { $0 + $1.bytes }, right.reduce(0) { $0 + $1.bytes }) }
    public func readable(failed: Set<String>) -> Bool {
        left.allSatisfy { !failed.contains($0.id) } || right.allSatisfy { !failed.contains($0.id) }
    }
    public func writable(failed: Set<String>) -> Bool { failed.isEmpty } // Conservative prototype policy.
    public func failureOfEnclosure(_ id: String) -> Set<String> { Set((left + right).filter { $0.enclosure == id }.map(\.id)) }
    public func replacementAllowed(memberID: String, replacementBytes: Int64) -> Bool {
        guard let old = (left + right).first(where: { $0.id == memberID }) else { return false }
        return replacementBytes >= old.bytes
    }
}
