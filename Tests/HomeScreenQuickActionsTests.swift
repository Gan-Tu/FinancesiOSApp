import XCTest
import UIKit
@testable import FinancesClone

@MainActor
final class HomeScreenQuickActionsTests: XCTestCase {
    private final class Recorder {
        var menus: [[UIApplicationShortcutItem]] = []
        var opened: [UUID] = []
        var onPublish: (([UIApplicationShortcutItem]) -> Void)?
        func publish(_ items: [UIApplicationShortcutItem]) { menus.append(items); onPublish?(items) }
    }

    private func preferences(suite: String = "quick-action-tests-" + UUID().uuidString) -> UserDefaults {
        let value = UserDefaults(suiteName: suite)!
        value.set("", forKey: HomeScreenQuickActions.preferenceKey)
        addTeardownBlock { value.removePersistentDomain(forName: suite) }
        return value
    }
    private func fixture() -> JournalData {
        let first = Ledger(name: "SYNTHETIC Alpha", listIndex: 0)
        let second = Ledger(name: "SYNTHETIC Beta", listIndex: 1)
        let templates = (0..<7).map { index in
            TransactionTemplate(ledgerID: index == 6 ? UUID() : (index < 3 ? first.id : second.id),
                name: ["Coffee", "Lunch", "Transit", "Coffee", "Scan Receipt", "Disabled", "Orphan"][index],
                note: "", payee: "", cleared: true, enabled: index != 5,
                scanInvoice: index == 4, listIndex: index % 3)
        }
        return JournalData(ledgers: [first, second], transactionTemplates: templates, syncEnabled: false)
    }
    private func manager(_ prefs: UserDefaults, _ recorder: Recorder) -> HomeScreenQuickActions {
        HomeScreenQuickActions(preferences: prefs, publish: { recorder.publish($0) }, openTemplate: { recorder.opened.append($0) })
    }
    private func selected(_ ids: [UUID], in prefs: UserDefaults) {
        prefs.set(ids.map(\.uuidString).joined(separator: ","), forKey: HomeScreenQuickActions.preferenceKey)
    }
    private func item(_ id: UUID, title: String = "A stale display name") -> UIApplicationShortcutItem {
        UIApplicationShortcutItem(type: HomeScreenQuickActions.shortcutPrefix + id.uuidString, localizedTitle: title)
    }
    private func menuIDs(_ recorder: Recorder) -> [UUID] {
        (recorder.menus.last ?? []).compactMap { HomeScreenQuickActions.templateID(from: $0) }
    }

    func testFreshInstallSeedsPreferredJournalOnceAndExplicitEmptyStaysEmpty() {
        let prefs = preferences(), recorder = Recorder()
        prefs.removeObject(forKey: HomeScreenQuickActions.preferenceKey)
        var data = fixture()
        data.selectedLedgerID = data.ledgers[1].id
        let actions = manager(prefs, recorder)
        actions.update(data: JournalData(), hiddenLedgerIDs: [])
        XCTAssertNil(prefs.object(forKey: HomeScreenQuickActions.preferenceKey), "Wait for the first real catalog")
        actions.update(data: data, hiddenLedgerIDs: [])
        let ids = data.transactionTemplates.map(\.id)
        XCTAssertEqual(menuIDs(recorder), [ids[3], ids[4], ids[0], ids[1]])
        actions.removeTemplates(at: IndexSet(integersIn: 0..<4))
        XCTAssertEqual(prefs.string(forKey: HomeScreenQuickActions.preferenceKey), "")
        let reopenedRecorder = Recorder()
        let reopened = manager(prefs, reopenedRecorder)
        reopened.update(data: data, hiddenLedgerIDs: [])
        XCTAssertTrue(reopened.selectedTemplates.isEmpty)
        XCTAssertTrue(menuIDs(reopenedRecorder).isEmpty)
    }

    func testOnlyEnabledTemplatesFromVisibleExistingJournalsAreSelectable() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [data.ledgers[1].id])
        XCTAssertEqual(actions.availableTemplates.map(\.id), data.transactionTemplates.prefix(3).map(\.id))
        XCTAssertFalse(actions.addTemplate(data.transactionTemplates[3].id), "A hidden journal cannot publish a shortcut")
        XCTAssertFalse(actions.addTemplate(data.transactionTemplates[5].id), "A disabled template cannot publish a shortcut")
        XCTAssertFalse(actions.addTemplate(data.transactionTemplates[6].id), "An orphan cannot publish a shortcut")
        XCTAssertTrue(menuIDs(recorder).isEmpty)
    }

    func testSelectAtMostFourAndPublishTemplateTitleWithJournalSubtitle() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        let ids = data.transactionTemplates.prefix(4).map(\.id)
        for id in ids { XCTAssertTrue(actions.addTemplate(id)) }
        XCTAssertFalse(actions.canAddTemplate)
        XCTAssertFalse(actions.addTemplate(data.transactionTemplates[4].id))
        XCTAssertFalse(actions.addTemplate(ids[0]))
        XCTAssertEqual(menuIDs(recorder), ids)
        XCTAssertEqual(recorder.menus.last?.map(\.localizedTitle), ["Coffee", "Lunch", "Transit", "Coffee"])
        XCTAssertEqual(recorder.menus.last?.map(\.localizedSubtitle), ["SYNTHETIC Alpha", "SYNTHETIC Alpha", "SYNTHETIC Alpha", "SYNTHETIC Beta"])
        XCTAssertTrue(recorder.opened.isEmpty, "Configuring shortcuts must not open or save a transaction")
    }

    func testReorderRemoveAndSelectionSurviveCoordinatorRecreation() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        let ids = data.transactionTemplates.prefix(5).map(\.id)
        for id in ids.prefix(4) { XCTAssertTrue(actions.addTemplate(id)) }
        actions.moveTemplates(from: IndexSet(integer: 0), to: 4)
        XCTAssertEqual(menuIDs(recorder), [ids[1], ids[2], ids[3], ids[0]])
        actions.removeTemplates(at: IndexSet(integer: 1))
        XCTAssertTrue(actions.addTemplate(ids[4]))
        let expected = [ids[1], ids[3], ids[0], ids[4]]
        XCTAssertEqual(menuIDs(recorder), expected)
        let reopenedRecorder = Recorder()
        let reopened = manager(prefs, reopenedRecorder)
        reopened.update(data: data, hiddenLedgerIDs: [])
        XCTAssertEqual(reopened.selectedTemplates.map(\.id), expected)
        XCTAssertEqual(menuIDs(reopenedRecorder), expected)
    }

    func testStalePreferenceDuplicatesAndInvalidIDsCannotExceedFourShortcuts() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let ids = data.transactionTemplates.prefix(5).map(\.id)
        prefs.set((ids + ids).map(\.uuidString).joined(separator: ",") + ",bad-id", forKey: HomeScreenQuickActions.preferenceKey)
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        XCTAssertEqual(menuIDs(recorder), Array(ids.prefix(4)))
    }

    func testRenameUpdatesMenuIdentityAndTransactionOnlyChangesDoNotRepublish() {
        let prefs = preferences(), recorder = Recorder()
        var data = fixture()
        let id = data.transactionTemplates[0].id
        selected([id], in: prefs)
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        let originalType = recorder.menus.last?.first?.type
        let publications = recorder.menus.count
        data.transactions = DemoData.fixture().transactions
        actions.update(data: data, hiddenLedgerIDs: [])
        XCTAssertEqual(recorder.menus.count, publications, "Shortcut metadata does not depend on transaction history")
        data.transactionTemplates[0].name = "Renamed Coffee"
        data.ledgers[0].name = "Renamed Alpha"
        actions.update(data: data, hiddenLedgerIDs: [])
        XCTAssertEqual(recorder.menus.last?.first?.type, originalType)
        XCTAssertEqual(recorder.menus.last?.first?.localizedTitle, "Renamed Coffee")
        XCTAssertEqual(recorder.menus.last?.first?.localizedSubtitle, "Renamed Alpha")
        XCTAssertTrue(actions.handle(item(id)), "A stale displayed title must still resolve the stable UUID")
        XCTAssertEqual(recorder.opened, [id])
    }

    func testHiddenPreferenceChangesUpdateMenuWithoutAnyStoreMutation() async {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let id = data.transactionTemplates[0].id
        selected([id], in: prefs)
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        for (hidden, expected) in [(true, [UUID]()), (false, [id])] {
            let changed = expectation(description: "Visibility refresh")
            recorder.onPublish = { items in
                if items.compactMap({ HomeScreenQuickActions.templateID(from: $0) }) == expected { changed.fulfill() }
            }
            prefs.set(hidden ? data.ledgers[0].id.uuidString : "", forKey: JournalVisibility.preferenceKey)
            await fulfillment(of: [changed], timeout: 5)
            recorder.onPublish = nil
            XCTAssertEqual(menuIDs(recorder), expected)
        }
        XCTAssertTrue(recorder.opened.isEmpty)
    }

    func testBackgroundPreferenceNotificationSafelyRefreshesMenu() async {
        let suite = "quick-action-background-" + UUID().uuidString
        let prefs = preferences(suite: suite), recorder = Recorder(), data = fixture()
        let id = data.transactionTemplates[0].id
        selected([id], in: prefs)
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        let changed = expectation(description: "Background visibility hides action")
        recorder.onPublish = { if $0.isEmpty { changed.fulfill() } }
        let hiddenID = data.ledgers[0].id.uuidString
        let key = JournalVisibility.preferenceKey
        await Task.detached {
            let defaults = UserDefaults(suiteName: suite)!
            defaults.set(hiddenID, forKey: key)
            NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: defaults)
        }.value
        await fulfillment(of: [changed], timeout: 5)
        recorder.onPublish = nil
        XCTAssertTrue(menuIDs(recorder).isEmpty)
        XCTAssertFalse(actions.handle(item(id)))
    }

    func testColdLaunchQueuesUntilMetadataThenOpensExactlyOnce() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let id = data.transactionTemplates[0].id
        selected([id], in: prefs)
        let actions = manager(prefs, recorder)
        let delegate = HomeScreenQuickActionSceneDelegate(coordinator: actions)
        delegate.receiveColdLaunchShortcut(item(id))
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertTrue(recorder.menus.isEmpty, "Do not erase the cached system menu before data is available")
        actions.update(data: data, hiddenLedgerIDs: [])
        actions.update(data: data, hiddenLedgerIDs: [])
        XCTAssertEqual(recorder.opened, [id])
    }

    func testWarmDelegateRoutesOnlyConfiguredEligibleTemplateAndCompletesOnce() {
        let prefs = preferences(), recorder = Recorder(), data = fixture()
        let id = data.transactionTemplates[0].id
        selected([id], in: prefs)
        let actions = manager(prefs, recorder)
        actions.update(data: data, hiddenLedgerIDs: [])
        let delegate = HomeScreenQuickActionSceneDelegate(coordinator: actions)
        var responses: [Bool] = []
        delegate.performShortcut(item(id)) { responses.append($0) }
        delegate.performShortcut(item(data.transactionTemplates[1].id)) { responses.append($0) }
        delegate.performShortcut(UIApplicationShortcutItem(type: "unrelated", localizedTitle: "Other")) { responses.append($0) }
        XCTAssertEqual(responses, [true, false, false])
        XCTAssertEqual(recorder.opened, [id])
    }

    func testDisabledDeletedAndHiddenTemplatesRejectOldMenuItems() {
        for scenario in 0..<3 {
            let prefs = preferences(), recorder = Recorder()
            var data = fixture()
            let id = data.transactionTemplates[0].id
            selected([id], in: prefs)
            let actions = manager(prefs, recorder)
            actions.update(data: data, hiddenLedgerIDs: [])
            let staleItem = item(id)
            if scenario == 0 { data.transactionTemplates[0].enabled = false }
            if scenario == 1 { data.transactionTemplates.removeFirst() }
            actions.update(data: data, hiddenLedgerIDs: scenario == 2 ? [data.ledgers[0].id] : [])
            XCTAssertTrue(menuIDs(recorder).isEmpty)
            XCTAssertFalse(actions.handle(staleItem))
            XCTAssertTrue(recorder.opened.isEmpty)
        }
    }

    func testColdLaunchRejectsNowDeletedTemplateAndReplacingDormantSlotStaysBounded() {
        let prefs = preferences(), recorder = Recorder()
        var data = fixture()
        let ids = data.transactionTemplates.prefix(5).map(\.id)
        selected([ids[0], ids[1], ids[2], ids[3]], in: prefs)
        let actions = manager(prefs, recorder)
        XCTAssertTrue(actions.handle(item(ids[0])))
        data.transactionTemplates.removeFirst()
        actions.update(data: data, hiddenLedgerIDs: [])
        XCTAssertTrue(recorder.opened.isEmpty)
        XCTAssertTrue(actions.canAddTemplate)
        XCTAssertTrue(actions.addTemplate(ids[4]))
        XCTAssertEqual(menuIDs(recorder), [ids[1], ids[2], ids[3], ids[4]])
        XCTAssertFalse(actions.handle(item(ids[0])))
    }
}
