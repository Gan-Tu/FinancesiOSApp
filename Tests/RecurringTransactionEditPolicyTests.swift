import XCTest
@testable import FinancesClone

final class RecurringTransactionEditPolicyTests: XCTestCase {
    private func existingDraft() -> TransactionDraft {
        var draft = TransactionDraft()
        draft.id = UUID()
        draft.recurrenceRuleID = UUID()
        draft.repeatFrequency = .monthly
        return draft
    }

    func testNewRecurringEntryKeepsEditableScheduleWithoutSeriesConfirmation() {
        let initial = TransactionDraft()
        var edited = initial
        edited.repeatFrequency = .weekly
        let policy = RecurringTransactionEditPolicy(initialDraft: initial, editedDraft: edited, anchorID: nil)
        XCTAssertTrue(policy.canEditRepeatSettings)
        XCTAssertFalse(policy.requiresScheduleConfirmation)
    }

    func testGeneratedOccurrenceLocksRepeatButKeepsNormalDetailAndDateScopeChoices() {
        let initial = existingDraft()
        var edited = initial
        edited.note = "Just this occurrence"
        edited.date = initial.date.addingTimeInterval(86_400)
        let policy = RecurringTransactionEditPolicy(initialDraft: initial, editedDraft: edited, anchorID: UUID())
        XCTAssertFalse(policy.canEditRepeatSettings)
        XCTAssertFalse(policy.requiresScheduleConfirmation)
    }

    func testAnchorDetailsKeepBothExistingSaveChoices() {
        let initial = existingDraft()
        var edited = initial
        edited.payee = "Updated Payee"
        edited.note = "Updated Note"
        edited.cleared.toggle()
        edited.postings = [PostingDraft(accountID: UUID(), amount: "12"), PostingDraft(accountID: UUID(), amount: "-12")]
        let policy = RecurringTransactionEditPolicy(initialDraft: initial, editedDraft: edited, anchorID: initial.id)
        XCTAssertTrue(policy.canEditRepeatSettings)
        XCTAssertFalse(policy.requiresScheduleConfirmation)
    }

    func testEveryAnchorScheduleControlAndDateRequiresExplicitSeriesConfirmation() {
        let initial = existingDraft()
        let edits: [(inout TransactionDraft) -> Void] = [
            { $0.date = $0.date.addingTimeInterval(86_400) },
            { $0.repeatFrequency = .never },
            { $0.repeatFrequency = .weekly },
            { $0.repeatIntervalValue = 2 },
            { $0.repeatOnWorkdays = true },
            { $0.repeatOccurrenceCount = 4 },
            { $0.repeatEndDate = $0.date.addingTimeInterval(86_400 * 30) }
        ]
        for edit in edits {
            var edited = initial
            edit(&edited)
            let policy = RecurringTransactionEditPolicy(initialDraft: initial, editedDraft: edited, anchorID: initial.id)
            XCTAssertTrue(policy.canEditRepeatSettings)
            XCTAssertTrue(policy.requiresScheduleConfirmation)
        }
        XCTAssertFalse(RecurringTransactionEditPolicy(initialDraft: initial, editedDraft: initial, anchorID: initial.id).requiresScheduleConfirmation)
    }
}
