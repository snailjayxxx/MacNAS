import Foundation
import Darwin
import XCTest
@testable import MacNASCore

class RecycleVaultLab: LabTest {
    func recycleLab(_ name: String = "recycle", databaseVersion: Int = 4) throws -> (URL, FixtureRecycleAuthority, RecycleVaultRegistration) {
        let root = child(name); try PortableInstance.createSynthetic(at: root, databaseVersion: databaseVersion)
        let host = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        return (root, host, try host.createFreshFixture(confirmed: true))
    }
    func library(_ root: URL) -> URL { root.appendingPathComponent(RecycleVault.fixturePath + "/library") }
    func vault(_ root: URL) -> URL { root.appendingPathComponent(RecycleVault.fixturePath + "/vault") }
}

final class RecycleVaultTests: RecycleVaultLab {
    func testCreationRequiresConfirmationAndPreservesUnknownExistingFixture() throws {
        let root = child("confirmed"); try PortableInstance.createSynthetic(at: root, databaseVersion: 4)
        let host = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        denied(.denied) { _ = try host.createFreshFixture(confirmed: false) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(RecycleVault.fixturePath).path))
        let registration = try host.createFreshFixture(confirmed: true)
        XCTAssertEqual(try host.registration(), registration)
        denied(.collision) { _ = try host.createFreshFixture(confirmed: true) }
        let grant = try host.approve(.observe, confirmed: true)
        try host.withLockedVault(grant, action: .observe) { permit in
            XCTAssertEqual(permit.vault.vault.identity.mode & 0o7777, 0o700)
            XCTAssertEqual(try permit.vault.entries.names(maximum: 64).count, 64)
            XCTAssertEqual(permit.registration.databaseName, host.store.databaseName)
        }
    }
    func testFreshHostAndDifferentActionNeverReuseOldApprovalOrOpenMissingVault() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let restarted = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        try FileManager.default.moveItem(at: vault(root), to: child("preserved-vault"))
        denied(.denied) { try restarted.withLockedVault(grant, action: .recycle) { _ in XCTFail("old grant admitted") } }
        denied(.denied) { try host.withLockedVault(grant, action: .observe) { _ in XCTFail("wrong purpose admitted") } }
        host.revokeAll()
        denied(.denied) { try host.withLockedVault(grant, action: .recycle) { _ in XCTFail("revoked grant admitted") } }
        XCTAssertTrue(FileManager.default.fileExists(atPath: child("preserved-vault").path))
    }
    func testReadOnlyHostCannotAcquireWriteApprovalAndReaderCannotCreateAuthority() throws {
        let (root, _, _) = try recycleLab()
        denied(.denied) { _ = try FixtureRecycleAuthority(root: root, userID: Data("fixture-family".utf8)) }
        let file = root.appendingPathComponent("host-binding/binding.json")
        var binding = try SafeFS.read(HostBinding.self, file); binding.mode = "read_only_recovery"; try SafeFS.write(binding, to: file)
        let host = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8))
        for action in [RecycleHostAction.recycle, .settle, .cancelPrepared] {
            denied(.denied) { _ = try host.approve(action, confirmed: true) }
        }
        let grant = try host.approve(.observe, confirmed: true)
        XCTAssertNoThrow(try host.withLockedVault(grant, action: .observe) { try $0.check(.observe) })
    }
    func testIndependentHostsContendForTheSameVaultFlockAndReplacementIsRejected() throws {
        let (root, first, _) = try recycleLab(), a = try first.approve(.recycle, confirmed: true)
        let second = try FixtureRecycleAuthority(root: root, userID: Data("fixture-owner".utf8)), b = try second.approve(.recycle, confirmed: true)
        denied(.staleState) { try first.withLockedVault(a, action: .recycle) { permit in
            denied(.busy) { try second.withLockedVault(b, action: .recycle) { _ in XCTFail("concurrent lock") } }
            let lock = vault(root).appendingPathComponent("execution.lock")
            try FileManager.default.moveItem(at: lock, to: child("preserved-lock"))
            try Data().write(to: lock); try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: lock.path)
            denied(.staleState) { try permit.check(.recycle) }
        } }
    }
    func testUnknownVaultObjectsAndChangedRegistrationArePreservedAndRefused() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let unknown = vault(root).appendingPathComponent("unknown-marker"); try Data("keep".utf8).write(to: unknown)
        denied(.budgetExceeded) { try host.withLockedVault(grant, action: .recycle) { _ in XCTFail("unknown root") } }
        XCTAssertEqual(try Data(contentsOf: unknown), Data("keep".utf8)); try FileManager.default.removeItem(at: unknown)
        let registration = root.appendingPathComponent(RecycleVault.registrationPath)
        var value = try JSONSerialization.jsonObject(with: Data(contentsOf: registration)) as! [String: Any]
        value["unknown"] = true; try JSONSerialization.data(withJSONObject: value).write(to: registration)
        denied(.invalidSchema) { try host.withLockedVault(grant, action: .recycle) { _ in XCTFail("unknown field") } }
    }
    func testPinnedRegularFileRejectsSymlinksHardlinksDirectoriesFifoAndOverLimit() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let base = library(root); try Data("bytes".utf8).write(to: base.appendingPathComponent("regular"))
        try FileManager.default.createSymbolicLink(at: base.appendingPathComponent("symlink"), withDestinationURL: base.appendingPathComponent("regular"))
        try FileManager.default.linkItem(at: base.appendingPathComponent("regular"), to: base.appendingPathComponent("hardlink"))
        try FileManager.default.createDirectory(at: base.appendingPathComponent("folder"), withIntermediateDirectories: false)
        XCTAssertEqual(mkfifo(base.appendingPathComponent("fifo").path, 0o600), 0)
        let oversized = base.appendingPathComponent("oversized")
        FileManager.default.createFile(atPath: oversized.path, contents: Data())
        let handle = try FileHandle(forWritingTo: oversized); try handle.truncate(atOffset: UInt64(DurableFileEffectJournal.fileBytes + 1)); try handle.close()
        try host.withLockedVault(grant, action: .recycle) { permit in
            for name in ["symlink", "hardlink", "regular", "folder", "fifo"] {
                denied(.unsafeFile) { _ = try RecyclePinnedFile(source: permit.vault.library, name: name, validate: { try permit.check(.recycle) }) }
            }
            denied(.budgetExceeded) { _ = try RecyclePinnedFile(source: permit.vault.library, name: "oversized", validate: { try permit.check(.recycle) }) }
        }
    }
    func testPinnedEmptyAndBinaryFilesRetainFullStampAndHash() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let data = Data((0..<70001).map { UInt8($0 % 251) })
        try Data().write(to: library(root).appendingPathComponent("empty")); try data.write(to: library(root).appendingPathComponent("日本語.bin"))
        try host.withLockedVault(grant, action: .recycle) { permit in
            let empty = try RecyclePinnedFile(source: permit.vault.library, name: "empty", validate: { try permit.check(.recycle) })
            XCTAssertEqual(empty.before.bytes, 0); XCTAssertEqual(empty.sha256, "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
            let file = try RecyclePinnedFile(source: permit.vault.library, name: "日本語.bin", validate: { try permit.check(.recycle) })
            XCTAssertEqual(file.before.bytes, 70001)
            XCTAssertEqual(file.sha256, "0a3d3958e38597b18e8d3faad4f3d88c281468a884fb9c3d07d67a14bdc476bc")
            try file.validateBefore { try permit.check(.recycle) }
            let original = library(root).appendingPathComponent("日本語.bin")
            try FileManager.default.moveItem(at: original, to: library(root).appendingPathComponent("preserved")); try data.write(to: original)
            denied(.staleState) { try file.validateBefore { try permit.check(.recycle) } }
        }
    }
    func testAncestorReplacementInvalidatesPinnedDirectories() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        denied(.staleState) { try host.withLockedVault(grant, action: .recycle) { permit in
            let source = permit.vault.library
            try FileManager.default.moveItem(at: library(root), to: child("kept-library"))
            try FileManager.default.createDirectory(at: library(root), withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
            denied(.staleState) { try source.validate() }
        } }
    }
    func testPrivateVaultPermissionsCannotBeRelaxedAfterApproval() throws {
        let (root, host, _) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: vault(root).path)
        denied(.unsafeFile) { try host.withLockedVault(grant, action: .recycle) { _ in XCTFail("relaxed private directory") } }
    }
    func testSlotLifetimeNeverDeletesAnOrphanOrPayload() throws {
        let (root, host, registration) = try recycleLab(), grant = try host.approve(.recycle, confirmed: true)
        let slotID = registration.slots[0].id
        try host.withLockedVault(grant, action: .recycle) { permit in
            let slot = try permit.vault.slot(slotID)
            try Data("preserve".utf8).write(to: slot.url.appendingPathComponent("payload"))
            denied(.denied) { _ = try permit.vault.slot(UUID()) }
        }
        XCTAssertEqual(try Data(contentsOf: vault(root).appendingPathComponent("entries/" + slotID.uuidString.lowercased() + "/payload")), Data("preserve".utf8))
    }
    func testSecondAdministratorCannotAdoptTheOriginalOwnersVault() throws {
        let (root, _, _) = try recycleLab(), file = root.appendingPathComponent("config/platform.json")
        var config = try SafeFS.read(PortableConfig.self, file)
        config.users.append(.init(id: "another-admin", role: "administrator")); try SafeFS.write(config, to: file)
        let second = try FixtureRecycleAuthority(root: root, userID: Data("another-admin".utf8))
        try FileManager.default.moveItem(at: vault(root), to: child("original-vault-preserved"))
        denied(.denied) { _ = try second.approve(.observe, confirmed: true) }
    }
}
