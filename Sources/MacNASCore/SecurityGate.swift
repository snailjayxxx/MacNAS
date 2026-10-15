import Foundation
import CryptoKit

public enum MockOperation: String, Codable { case simulateShareChange, installHelper, rebuildPool }
public struct OperationRequest: Codable, Equatable {
    public var operation: MockOperation
    public var scope: String
    public var preview: String
    public var expectedState: String
    public var requestID: UUID
    public init(operation: MockOperation = .simulateShareChange, scope: String = "fixture:share", preview: String = "synthetic share change", expectedState: String = "state-v1", requestID: UUID = UUID()) {
        self.operation = operation; self.scope = scope; self.preview = preview; self.expectedState = expectedState; self.requestID = requestID
    }
}
public struct MockSecurityContext {
    public var user: String = "fixture-owner"
    public var role: String = "administrator"
    public var session: String = "fixture-session"
    public var csrf: String = "fixture-csrf"
    public var origin: String = "https://macnas.test"
    public var verifiedMockCaller: Bool = true
    public init() {}
}

/// Simulation boundary only. No XPC listener or system operation executor exists.
public final class MockOperationGate {
    struct Grant { var request: OperationRequest; var user: String; var session: String; var deadline: Date }
    private var grants: [UUID: Grant] = [:]
    private var used: Set<UUID> = []
    public init() {}
    private func authorize(_ request: OperationRequest, _ context: MockSecurityContext) throws {
        try require(request.operation == .simulateShareChange, .unsupported)
        try require(request.scope.hasPrefix("fixture:") && !request.scope.contains("/") && !request.scope.contains(".."), .unsafePath)
        try require(context.verifiedMockCaller && context.user == "fixture-owner" && context.role == "administrator", .denied)
        try require(context.session == "fixture-session" && context.csrf == "fixture-csrf" && context.origin == "https://macnas.test", .denied)
    }
    public func preview(_ request: OperationRequest, context: MockSecurityContext, now: Date = Date()) throws -> UUID {
        try authorize(request, context)
        let token = UUID()
        grants[token] = Grant(request: request, user: context.user, session: context.session, deadline: now.addingTimeInterval(30))
        return token
    }
    public func commit(_ request: OperationRequest, token: UUID, context: MockSecurityContext, actualState: String, now: Date = Date()) throws {
        try authorize(request, context)
        try require(!used.contains(token), .replay)
        guard let grant = grants.removeValue(forKey: token) else { throw NASError.denied }
        used.insert(token) // Failed attempts consume the token too.
        try require(now < grant.deadline, .expired)
        try require(grant.request == request && grant.user == context.user && grant.session == context.session, .denied)
        try require(request.expectedState == actualState, .staleState)
        // Success returns authorization for an in-memory simulation, never a root command.
    }
}
