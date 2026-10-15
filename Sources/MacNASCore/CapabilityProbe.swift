import Foundation

public enum ProbeState: String, Codable { case available, unavailable, requiresApproval, notVerified }
public struct Capability: Codable, Equatable { public var id: String; public var state: ProbeState; public var evidence: String }
public protocol CapabilityProbe { func inspect() -> [Capability] }
public struct MockCapabilityProbe: CapabilityProbe {
    public var osMajor: Int
    public var localModelAvailable: Bool
    public init(osMajor: Int, localModelAvailable: Bool = false) { self.osMajor = osMajor; self.localModelAvailable = localModelAvailable }
    public func inspect() -> [Capability] {
        [Capability(id: "foundation", state: osMajor >= 15 ? .available : .unavailable, evidence: "MOCK version gate"),
         Capability(id: "vision-feature-print", state: osMajor >= 15 ? .available : .unavailable, evidence: "MOCK; accuracy not evaluated"),
         Capability(id: "vision-ocr", state: osMajor >= 15 ? .available : .unavailable, evidence: "MOCK; languages must be queried"),
         Capability(id: "face-identity-grouping", state: .notVerified, evidence: "Face detection does not establish identity clustering"),
         Capability(id: "natural-language-photo-search", state: .notVerified, evidence: "No validated Apple-only image/text retrieval pipeline"),
         Capability(id: "foundation-models", state: osMajor >= 26 && localModelAvailable ? .available : .unavailable, evidence: "MOCK; no cloud fallback"),
         Capability(id: "SMB-enumeration", state: .requiresApproval, evidence: "Not queried"),
         Capability(id: "service-registration", state: .requiresApproval, evidence: "No registration attempted"),
         Capability(id: "volume-inventory", state: .requiresApproval, evidence: "Only development volume separately verified")]
    }
}
public struct BasicHostProbe: CapabilityProbe {
    public init() {}
    public func inspect() -> [Capability] {
        [Capability(id: "host-os", state: .available, evidence: ProcessInfo.processInfo.operatingSystemVersionString),
         Capability(id: "postgresql", state: .notVerified, evidence: "PostgreSQL 18 selected; connection must be explicitly bound"),
         Capability(id: "runtime", state: .available, evidence: "non-root CLI; no sockets/listeners/services"),
         Capability(id: "macOS15-runtime", state: .notVerified, evidence: "Deployment target 15; runtime on 15 not tested")]
    }
}
