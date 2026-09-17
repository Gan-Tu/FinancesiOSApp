import CloudKit
import CryptoKit
import Foundation
import XCTest
@testable import FinancesClone

private actor PreferencesTestCloud: CloudKitSyncTransport {
    var rows: [String: CloudKitSyncRecord] = [:]
    var identity = "A"
    var revision = 0
    var offline = false
    var conflictOnce = false
    var beforeSave: (@Sendable () async -> Void)?
    func accountIdentifier() async throws -> String { identity }
    func prepareZone() async throws {}
    func fetchChanges(since: Data?) async throws -> CloudKitSyncPage {
        if offline { throw AssistError.message("Offline") }
        return .init(records: rows[identity].map { [$0] } ?? [], changeToken: nil, moreComing: false)
    }
    func modifyRecords(_ records: [CloudKitSyncRecord]) async throws -> CloudKitSyncModifyResult {
        if let action = beforeSave { beforeSave = nil; await action() }
        if offline { throw AssistError.message("Offline") }
        if conflictOnce { conflictOnce = false; return .init(saved: [], conflicts: rows[identity].map { [$0] } ?? records) }
        if records[0].systemFields != rows[identity]?.systemFields {
            return .init(saved: [], conflicts: rows[identity].map { [$0] } ?? records)
        }
        var ack = records[0]; revision += 1; ack.systemFields = Data(String(revision).utf8); rows[identity] = ack
        return .init(saved: [ack], conflicts: [])
    }
    func setOffline(_ value: Bool) { offline = value }
    func setConflict() { conflictOnce = true }
    func switchAccount() { identity = "B" }
    func duringSave(_ action: @escaping @Sendable () async -> Void) { beforeSave = action }
    nonisolated func cancel() {}
}

@MainActor final class AssistantPreferencesTests: XCTestCase {
    private var directories: [URL] = []
    private func make(_ cloud: PreferencesTestCloud, directory: URL? = nil) -> AssistantPreferencesStore {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(dir)
        return AssistantPreferencesStore(directory: dir, network: cloud)
    }
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; directories = [] }
    func testAcknowledgedSettingsRestoreAfterReinstallAndOverrideLegacyHistory() async throws {
        let cloud = PreferencesTestCloud(), first = make(cloud)
        first.legacySettings = { _ in AssistantSettings(customInstructions: "Old chat instructions") }
        await first.refresh()
        let desired = AssistantSettings(model: "gpt-5.6-sol", effort: "high", customInstructions: "My app preferences")
        try first.edit(desired, expected: first.value)
        await first.refresh()
        XCTAssertFalse(first.pending)
        first.disconnect()
        let reinstall = make(cloud) // A new installation has no local cache.
        reinstall.legacySettings = { _ in AssistantSettings(customInstructions: "Stale conversation") }
        await reinstall.refresh()
        XCTAssertEqual(reinstall.settings, desired)
        XCTAssertTrue(reinstall.ready)
        XCTAssertFalse(reinstall.pending)
        reinstall.legacySettings = { _ in nil } // Deleting chat history cannot remove app preferences.
        await reinstall.refresh()
        XCTAssertEqual(reinstall.settings, desired)
        reinstall.disconnect()
    }
    func testOfflineOutboxAndAccountIsolation() async throws {
        let cloud = PreferencesTestCloud(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let first = make(cloud, directory: dir)
        await first.refresh()
        await cloud.setOffline(true)
        let desired = AssistantSettings(customInstructions: "Private pending instructions")
        try first.edit(desired, expected: first.value)
        await first.refresh(); XCTAssertTrue(first.pending); first.disconnect()
        let restarted = make(cloud, directory: dir)
        await restarted.refresh()
        XCTAssertEqual(restarted.settings, desired)
        XCTAssertTrue(restarted.pending)
        restarted.disconnect(); await cloud.switchAccount(); await cloud.setOffline(false)
        restarted.legacySettings = { subject in subject.hasSuffix(":A") ? desired : nil }
        await restarted.refresh()
        XCTAssertEqual(restarted.settings, AssistantSettings())
        XCTAssertFalse(restarted.pending)
        restarted.disconnect()
    }
    func testConcurrentPreferencesMergeAndConflict() async throws {
        let cloud = PreferencesTestCloud(), a = make(cloud), b = make(cloud)
        await a.refresh(); await b.refresh()
        try a.edit(AssistantSettings(model: "gpt-5.6-sol", effort: "high"), expected: a.value)
        try b.edit(AssistantSettings(customInstructions: "Use English"), expected: b.value)
        await a.refresh(); await b.refresh(); await a.refresh()
        XCTAssertEqual(a.settings, b.settings)
        XCTAssertEqual(a.settings.model, "gpt-5.6-sol")
        XCTAssertEqual(a.settings.customInstructions, "Use English")
        var local = a.settings; local.customInstructions = "Local"
        var remote = b.settings; remote.customInstructions = "Remote"
        try a.edit(local, expected: a.value); try b.edit(remote, expected: b.value)
        await a.refresh(); await b.refresh()
        XCTAssertEqual(b.conflicts, ["Custom instructions"])
        try b.resolve(keepLocal: false, expectedLocal: b.value, expectedRemote: b.remote)
        await b.refresh()
        XCTAssertEqual(b.settings.customInstructions, "Local")
        a.disconnect(); b.disconnect()
    }
    func testEditDuringUploadSurvivesAcknowledgment() async throws {
        let cloud = PreferencesTestCloud(), store = make(cloud)
        await store.refresh()
        try store.edit(AssistantSettings(customInstructions: "First"), expected: store.value)
        await cloud.duringSave { @MainActor in
            try? store.edit(AssistantSettings(customInstructions: "Newer edit"), expected: store.value)
        }
        await store.refresh()
        XCTAssertEqual(store.settings.customInstructions, "Newer edit")
        XCTAssertFalse(store.pending)
        store.disconnect()
    }
    func testAssistantZoneAndUTF16Limit() throws {
        let codec = CloudKitSyncRecordCodec(zoneID: CKRecordZone.ID(zoneName: AssistantPreferences.zone, ownerName: CKCurrentUserDefaultName))
        XCTAssertNoThrow(try codec.recordID(type: AssistantPreferences.domain, id: AssistantPreferences.recordID))
        XCTAssertThrowsError(try codec.recordID(type: ReceiptPreferences.domain, id: AssistantPreferences.recordID))
        let receipts = CloudKitSyncRecordCodec(zoneID: CKRecordZone.ID(zoneName: ReceiptPreferences.zone, ownerName: CKCurrentUserDefaultName))
        XCTAssertThrowsError(try receipts.recordID(type: AssistantPreferences.domain, id: AssistantPreferences.recordID))
        XCTAssertThrowsError(try AssistantPreferences(AssistantSettings(customInstructions: String(repeating: "😀", count: 2001))).validate())
        XCTAssertThrowsError(try AssistantPreferences(AssistantSettings(effort: "none")).validate())
    }
}
@MainActor final class ReceiptPreferencesTests: XCTestCase {
    private var directories: [URL] = []
    private func make(_ cloud: PreferencesTestCloud, directory: URL? = nil, defaults: UserDefaults? = nil) -> ReceiptPreferencesStore {
        let dir = directory ?? FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        directories.append(dir)
        return ReceiptPreferencesStore(directory: dir, network: cloud, defaults: defaults ?? UserDefaults(suiteName: UUID().uuidString)!)
    }
    private func edit(_ store: ReceiptPreferencesStore, model: String? = nil, effort: String? = nil, instructions: String? = nil) throws {
        var settings = store.settings
        if let model { settings.model = model }; if let effort { settings.effort = effort }; if let instructions { settings.instructions = instructions }
        try store.edit(settings, expected: store.value)
    }
    override func tearDown() { for dir in directories { try? FileManager.default.removeItem(at: dir) }; directories = [] }
    func testNativeWebPayloadAndZoneIsolation() throws {
        var value = ReceiptPreferences(); value.instructions = "中文\nUse groceries"
        let record = try value.record(previous: nil)
        XCTAssertEqual(try ReceiptPreferences.decode(record), value)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(record.payloadJSON!.utf8)) as? [String: Any])
        XCTAssertEqual(Set(object.keys), Set(["id", "version", "model", "effort", "instructions"]))
        let codec = CloudKitSyncRecordCodec(zoneID: CKRecordZone.ID(zoneName: ReceiptPreferences.zone, ownerName: CKCurrentUserDefaultName))
        XCTAssertNoThrow(try codec.recordID(type: ReceiptPreferences.domain, id: ReceiptPreferences.recordID))
        XCTAssertThrowsError(try codec.recordID(type: "account", id: ReceiptPreferences.recordID))
        var corrupt = record; corrupt.contentHash = "invalid"
        XCTAssertThrowsError(try ReceiptPreferences.decode(corrupt))
    }
    func testIndependentOfflineEditsConverge() async throws {
        let cloud = PreferencesTestCloud(), a = make(cloud), b = make(cloud)
        await a.refresh(); await b.refresh()
        try edit(a, model: "gpt-6-astra", effort: "high")
        try edit(b, instructions: "Merchant names")
        await a.refresh(); await b.refresh(); await a.refresh()
        XCTAssertEqual(a.value, b.value); XCTAssertEqual(a.value.model, "gpt-6-astra"); XCTAssertEqual(a.value.instructions, "Merchant names")
        XCTAssertFalse(a.pending); XCTAssertFalse(b.pending)
    }
    func testConflictRestartAndCloudChoicePreserveIndependentLocalChanges() async throws {
        let cloud = PreferencesTestCloud(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = make(cloud), b = make(cloud, directory: dir)
        await a.refresh(); await b.refresh()
        try edit(a, instructions: "Cloud"); try edit(b, model: "gpt-6-astra", instructions: "Local")
        await a.refresh(); await b.refresh()
        XCTAssertEqual(b.conflicts, ["Custom instructions"])
        b.disconnect()
        let restarted = make(cloud, directory: dir); await restarted.refresh()
        XCTAssertEqual(restarted.conflicts, ["Custom instructions"])
        try restarted.resolve(keepLocal: false, expectedLocal: restarted.value, expectedRemote: restarted.remote)
        await restarted.refresh(); await a.refresh()
        XCTAssertEqual(a.value.instructions, "Cloud"); XCTAssertEqual(a.value.model, "gpt-6-astra")
    }
    func testAtomicModelEffortConflictAndRevisionRetry() async throws {
        let cloud = PreferencesTestCloud(), a = make(cloud), b = make(cloud)
        await a.refresh(); await b.refresh()
        try edit(a, model: "gpt-6-astra"); try edit(b, effort: "none")
        await a.refresh(); await b.refresh()
        XCTAssertEqual(b.conflicts, ["Model and reasoning effort"])
        let oldRemote = b.remote
        try edit(a, effort: "high"); await a.refresh(); await b.refresh()
        XCTAssertThrowsError(try b.resolve(keepLocal: true, expectedLocal: b.value, expectedRemote: oldRemote))
        try b.resolve(keepLocal: true, expectedLocal: b.value, expectedRemote: b.remote)
        await cloud.setConflict(); await b.refresh(); await a.refresh()
        XCTAssertEqual(a.value.model, "gpt-5.6-terra"); XCTAssertEqual(a.value.effort, "none")
    }
    func testOfflinePersistenceAndEditDuringUpload() async throws {
        let cloud = PreferencesTestCloud(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let a = make(cloud, directory: dir); await a.refresh(); try edit(a, instructions: "First")
        await cloud.setOffline(true); await a.refresh(); XCTAssertTrue(a.pending); a.disconnect()
        let b = make(cloud, directory: dir); await b.refresh(); XCTAssertEqual(b.value.instructions, "First")
        await cloud.setOffline(false)
        await cloud.duringSave { @MainActor in
            var settings = b.settings; settings.instructions = "Typed during upload"
            try? b.edit(settings, expected: b.value)
        }
        await b.refresh(); XCTAssertFalse(b.pending); XCTAssertEqual(b.value.instructions, "Typed during upload")
    }
    func testAccountSwitchDoesNotLeakLegacyOrPendingPreferences() async throws {
        let cloud = PreferencesTestCloud(), defaults = UserDefaults(suiteName: UUID().uuidString)!
        var legacy = ReceiptAISettings(); legacy.instructions = "Legacy private instructions"
        defaults.set(try JSONEncoder().encode(legacy), forKey: "receipt-ai-settings-v1")
        let store = make(cloud, defaults: defaults); await store.refresh()
        XCTAssertEqual(store.value.instructions, legacy.instructions)
        try edit(store, instructions: "Offline private instructions")
        store.disconnect(); await cloud.switchAccount(); await store.refresh()
        XCTAssertEqual(store.value, ReceiptPreferences()); XCTAssertFalse(store.pending)
    }
    func testUnreadableNewAccountCacheDoesNotExposePreviousAccountSettings() async throws {
        let cloud = PreferencesTestCloud(), dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let store = make(cloud, directory: dir)
        await store.refresh(); try edit(store, instructions: "Account A private prompt"); await store.refresh()
        let key = SHA256.hash(data: Data("test:test:B".utf8)).map { String(format: "%02x", $0) }.joined()
        try Data("invalid cache".utf8).write(to: dir.appendingPathComponent(key + ".json"))
        await cloud.switchAccount(); await store.refresh()
        XCTAssertFalse(store.error.isEmpty)
        XCTAssertFalse(store.ready)
        XCTAssertEqual(store.value, ReceiptPreferences())
    }

}
