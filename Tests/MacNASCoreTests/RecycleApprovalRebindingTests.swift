import Foundation
import XCTest
@testable import MacNASCore

final class RecycleApprovalRebindingTests: RecycleVaultLab {
    func testApprovalCannotFollowAChangedButOtherwiseValidRegistration() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.observe, confirmed: true)
        let path = root.appendingPathComponent(RecycleVault.registrationPath)
        var object = try JSONSerialization.jsonObject(with: Data(contentsOf: path)) as! [String: Any]
        object["vaultID"] = UUID().uuidString
        let changed = try FileEffectMetadata.decode(RecycleVaultRegistration.self, from: JSONSerialization.data(withJSONObject: object))
        let bytes = try FileEffectMetadata.encoded(changed)
        try bytes.write(to: path)
        try bytes.write(to: vault(root).appendingPathComponent("binding.json"))
        denied(.staleState) { try host.validate(grant, action: .observe) }
        let fresh = try host.approve(.observe, confirmed: true)
        XCTAssertNoThrow(try host.withLockedVault(fresh, action: .observe) { _ in })
    }
    func testAmbiguousRawSubjectAndUnknownConfigCannotMintApproval() throws {
        let (root, host, _) = try recycleLab(), path = root.appendingPathComponent("config/platform.json")
        var config = try SafeFS.read(PortableConfig.self, path)
        config.users.append(.init(id: "fixture-owner", role: "reader")); try SafeFS.write(config, to: path)
        denied(.denied) { _ = try host.approve(.observe, confirmed: true) }
        config.users.removeLast(); config.schemaVersion = 2; try SafeFS.write(config, to: path)
        denied(.denied) { _ = try host.approve(.observe, confirmed: true) }
        config.schemaVersion = 1; try SafeFS.write(config, to: path)
        _ = try host.approve(.observe, confirmed: true)
    }
}
