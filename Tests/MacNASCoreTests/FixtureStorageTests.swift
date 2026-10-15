import Foundation
import XCTest
@testable import MacNASCore

final class FixtureVolumeRegistryTests: XCTestCase {
    let library = "fixture-library"
    func reference() -> VolumeReference {
        VolumeReference(libraryID: library, volumeID: UUID(), relativePath: "fixture/data", estimatedBytes: 35_000_000_000_000)
    }
    func observation(_ reference: VolumeReference) -> FixtureVolumeObservation {
        FixtureVolumeObservation(volumeID: reference.volumeID, displayName: "same-name", authorized: true)
    }
    let admin = LogicalUser(id: "fixture-owner", role: "administrator")
    let reader = LogicalUser(id: "fixture-family", role: "reader")
    func denied(_ code: NASError, _ body: () throws -> Void, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try body(), file: file, line: line) { XCTAssertEqual($0 as? NASError, code, file: file, line: line) }
    }
    func bind(_ registry: FixtureVolumeRegistry, access: FixtureVolumeAccess = .readWrite) throws {
        let caller = UUID(), preview = try registry.preview(libraryID: library, access: access, caller: caller)
        try registry.commit(preview, caller: caller, confirmed: true)
    }
    func testMissingAndSameNameWrongUUIDNeverBind() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        XCTAssertEqual(registry.statuses()[0].state, .missing)
        try registry.update([observation(self.reference())])
        XCTAssertEqual(registry.statuses()[0].state, .missing)
        let p = try registry.preview(libraryID: library, access: .readOnly, caller: UUID())
        denied(.replay) { try registry.commit(p, caller: UUID(), confirmed: true) }
        denied(.missingVolume) { _ = try registry.permit(libraryID: library, user: admin) }
    }
    func testDuplicateUUIDIsAmbiguousAndDoesNotChooseAName() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        try registry.update([observation(reference), observation(reference)])
        XCTAssertEqual(registry.statuses()[0].state, .ambiguous)
        denied(.missingVolume) { _ = try registry.permit(libraryID: library, user: admin) }
    }
    func testSystemAndUnauthorizedVolumesNeverIssueACommitGrant() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        var value = observation(reference); value.isSystem = true
        try registry.update([value]); XCTAssertEqual(registry.statuses()[0].state, .systemVolume)
        value.isSystem = false; value.authorized = false
        try registry.update([value]); XCTAssertEqual(registry.statuses()[0].state, .authorizationRequired)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin) }
    }
    func testExplicitBindingAndReadOnlyRightsAreDistinct() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        try registry.update([observation(reference)])
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin) }
        try bind(registry, access: .readOnly)
        XCTAssertEqual(registry.statuses()[0].state, .readyReadOnly)
        _ = try registry.permit(libraryID: library, user: admin)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin, access: .readWrite) }
    }
    func testReadOnlyMediaBlocksWriteBindingAndLaterWriteAccess() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        var value = observation(reference); value.isReadOnly = true
        try registry.update([value])
        XCTAssertEqual(try registry.preview(libraryID: library, access: .readWrite, caller: UUID()).state, .readOnly)
        try bind(registry, access: .readOnly)
        _ = try registry.permit(libraryID: library, user: admin)
        value.isReadOnly = false; try registry.update([value]); try bind(registry)
        value.isReadOnly = true; try registry.update([value])
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin, access: .readWrite) }
    }
    func testRenamePreservesIdentityButUnmountReturnRequiresFreshApproval() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        var value = observation(reference); try registry.update([value]); try bind(registry)
        value.displayName = "renamed"; try registry.update([value])
        _ = try registry.permit(libraryID: library, user: admin, access: .readWrite)
        try registry.update([]); XCTAssertEqual(registry.statuses()[0].state, .missing)
        try registry.update([value]); XCTAssertEqual(registry.statuses()[0].state, .needsBinding)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin) }
    }
    func testRemountAndMediaReplacementDoNotReuseOldBinding() throws {
        for changeMedia in [false, true] {
            let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
            var value = observation(reference); try registry.update([value]); try bind(registry)
            if changeMedia { value.mediaID = UUID() } else { value.mountID = UUID() }
            try registry.update([value]); XCTAssertEqual(registry.statuses()[0].state, .needsBinding)
            denied(.denied) { _ = try registry.permit(libraryID: library, user: admin) }
        }
    }
    func testCabinetDisappearanceRevokesAllItsMembersWithoutRevokingOthers() throws {
        let references = (0..<3).map { VolumeReference(libraryID: "library-\($0)", volumeID: UUID(), relativePath: "data", estimatedBytes: 1) }
        let registry = try FixtureVolumeRegistry(references: references), caller = UUID()
        let observations = references.enumerated().map { i, ref in
            FixtureVolumeObservation(volumeID: ref.volumeID, displayName: "disk-\(i)", cabinetID: i < 2 ? "cabinet-A" : "cabinet-B", authorized: true)
        }
        try registry.update(observations)
        for ref in references {
            try registry.commit(registry.preview(libraryID: ref.libraryID, access: .readOnly, caller: caller), caller: caller, confirmed: true)
        }
        try registry.update([observations[2]])
        XCTAssertEqual(registry.statuses().map(\.state), [.missing, .missing, .readyReadOnly])
        try registry.update(observations)
        XCTAssertEqual(registry.statuses().map(\.state), [.needsBinding, .needsBinding, .readyReadOnly])
    }
    func testApprovalBindsCallerAndConsumesFailedConfirmation() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference]), caller = UUID()
        try registry.update([observation(reference)])
        let first = try registry.preview(libraryID: library, access: .readOnly, caller: caller)
        denied(.denied) { try registry.commit(first, caller: UUID(), confirmed: true) }
        denied(.replay) { try registry.commit(first, caller: caller, confirmed: true) }
        let second = try registry.preview(libraryID: library, access: .readOnly, caller: caller)
        denied(.denied) { try registry.commit(second, caller: caller, confirmed: false) }
        denied(.replay) { try registry.commit(second, caller: caller, confirmed: true) }
    }
    func testChangedPreviewExpiryStaleInventoryAndCrossRegistryAreRejected() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference]), caller = UUID()
        try registry.update([observation(reference)])
        let start = Date(timeIntervalSince1970: 1000)
        let expired = try registry.preview(libraryID: library, access: .readOnly, caller: caller, now: start)
        denied(.expired) { try registry.commit(expired, caller: caller, confirmed: true, now: start.addingTimeInterval(30)) }
        let stale = try registry.preview(libraryID: library, access: .readOnly, caller: caller)
        try registry.update([observation(reference)])
        denied(.staleState) { try registry.commit(stale, caller: caller, confirmed: true) }
        let preview = try registry.preview(libraryID: library, access: .readOnly, caller: caller)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(preview)) as? [String: Any])
        json["requestedAccess"] = "readWrite"
        let changed = try JSONDecoder().decode(FixtureVolumePreview.self, from: JSONSerialization.data(withJSONObject: json))
        denied(.denied) { try registry.commit(changed, caller: caller, confirmed: true) }
        let other = try FixtureVolumeRegistry(references: [reference])
        denied(.replay) { try other.commit(preview, caller: caller, confirmed: true) }
    }
    func testRevokeEndedSessionAndServiceRestartRequireNewBinding() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference]), caller = UUID(), value = observation(reference)
        try registry.update([value])
        let preview = try registry.preview(libraryID: library, access: .readOnly, caller: caller)
        registry.endSession(caller); denied(.replay) { try registry.commit(preview, caller: caller, confirmed: true) }
        try bind(registry); try registry.revoke(libraryID: library)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: admin) }
        let restarted = try FixtureVolumeRegistry(references: [reference]); try restarted.update([value])
        XCTAssertEqual(restarted.statuses()[0].state, .needsBinding)
    }
    func testReaderGrantAndRevocationAreCheckedAgainForEveryPermit() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference])
        try registry.update([observation(reference)]); try bind(registry)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: reader) }
        try registry.setReaders([reader.id], libraryID: library)
        let permit = try registry.permit(libraryID: library, user: reader)
        denied(.denied) { _ = try registry.permit(libraryID: library, user: reader, access: .readWrite) }
        try registry.setReaders([], libraryID: library)
        denied(.denied) { try registry.validate(permit, user: reader) }
    }
    func testInventoryChangesInvalidateInFlightPermitsAndPendingBudgetIsBounded() throws {
        let reference = reference(), registry = try FixtureVolumeRegistry(references: [reference]), value = observation(reference)
        try registry.update([value]); try bind(registry)
        let permit = try registry.permit(libraryID: library, user: admin)
        try registry.update([value])
        denied(.staleState) { try registry.validate(permit, user: admin) }
        let now = Date(timeIntervalSince1970: 1000), caller = UUID()
        for _ in 0..<128 { _ = try registry.preview(libraryID: library, access: .readOnly, caller: caller, now: now) }
        denied(.budgetExceeded) { _ = try registry.preview(libraryID: library, access: .readOnly, caller: caller, now: now) }
        _ = try registry.preview(libraryID: library, access: .readOnly, caller: caller, now: now.addingTimeInterval(31))
    }
    func testInvalidReferencesAndInventoryAreRejected() throws {
        var ref = reference(); ref.relativePath = "../escape"
        denied(.unsafePath) { _ = try FixtureVolumeRegistry(references: [ref]) }
        let valid = reference()
        denied(.invalidSchema) { _ = try FixtureVolumeRegistry(references: [valid, valid]) }
        let registry = try FixtureVolumeRegistry(references: [valid]); var bad = observation(valid); bad.displayName = ""
        denied(.invalidSchema) { try registry.update([bad]) }
    }
}

final class FixtureStorageAPITests: LabTest {
    func testOwnerBindingDoesNotGrantReaderOrAllowCrossInstanceSession() throws {
        let api = try PrototypePlatformAPI(root: source()), owner = try api.beginFixtureSession(userID: "fixture-owner")
        let reader = try api.beginFixtureSession(userID: "fixture-family")
        let reference = try XCTUnwrap(api.fixtureVolumes.references.first)
        let value = FixtureVolumeObservation(volumeID: reference.volumeID, displayName: "fixture", authorized: true)
        denied(.denied) { try api.updateFixtureVolumeInventory([value], session: reader) }
        try api.updateFixtureVolumeInventory([value], session: owner)
        denied(.denied) { _ = try api.fixtureVolumeStatuses(session: reader) }
        let p = try api.previewFixtureVolumeBinding(libraryID: reference.libraryID, access: .readOnly, session: owner)
        try api.commitFixtureVolumeBinding(p, confirmed: true, session: owner)
        XCTAssertEqual(try api.fixtureVolumeStatuses(session: owner)[0].state, .readyReadOnly)
        let otherRoot = child("other"); try PortableInstance.createSynthetic(at: otherRoot)
        let other = try PrototypePlatformAPI(root: otherRoot)
        denied(.denied) { _ = try other.fixtureVolumeStatuses(session: owner) }
        api.endSession(owner); denied(.denied) { _ = try api.fixtureVolumeStatuses(session: owner) }
    }
    func testReferenceChangesInvalidateOldRegistryAndRecoveryRefusesBindingMutations() throws {
        let s = try source(), api = try PrototypePlatformAPI(root: s), owner = try api.beginFixtureSession(userID: "fixture-owner")
        let original = api.fixtureVolumes.references
        var refs = original; refs[0].volumeID = UUID()
        try SafeFS.write(refs, to: SafeFS.resolve(s, "logical-storage/references.json"))
        denied(.staleState) { _ = try api.fixtureVolumeStatuses(session: owner) }
        try SafeFS.write(original, to: SafeFS.resolve(s, "logical-storage/references.json"))
        var binding = try SafeFS.read(HostBinding.self, SafeFS.resolve(s, "host-binding/binding.json")); binding.mode = "read_only_recovery"
        try SafeFS.write(binding, to: SafeFS.resolve(s, "host-binding/binding.json"))
        denied(.denied) { try api.updateFixtureVolumeInventory([], session: owner) }
        denied(.denied) { try api.revokeFixtureVolumeBinding(libraryID: refs[0].libraryID, session: owner) }
    }
    func testUnknownReaderGrantAndPendingSessionRevocationAreDenied() throws {
        let api = try PrototypePlatformAPI(root: source()), owner = try api.beginFixtureSession(userID: "fixture-owner")
        let reference = try XCTUnwrap(api.fixtureVolumes.references.first)
        try api.updateFixtureVolumeInventory([.init(volumeID: reference.volumeID, displayName: "fixture", authorized: true)], session: owner)
        denied(.denied) { try api.setFixtureLibraryReaders(["not-configured"], libraryID: reference.libraryID, session: owner) }
        let p = try api.previewFixtureVolumeBinding(libraryID: reference.libraryID, access: .readOnly, session: owner)
        api.endSession(owner)
        let next = try api.beginFixtureSession(userID: "fixture-owner")
        denied(.replay) { try api.commitFixtureVolumeBinding(p, confirmed: true, session: next) }
    }
}
