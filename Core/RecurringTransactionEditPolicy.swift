import Foundation

/// Schedule edits require explicit confirmation and apply from the selected entry forward.
struct RecurringTransactionEditPolicy: Equatable {
    let canEditRepeatSettings: Bool
    let requiresScheduleConfirmation: Bool

    init(initialDraft: TransactionDraft, editedDraft: TransactionDraft, anchorID: UUID?) {
        let existingSeries = initialDraft.id != nil && initialDraft.recurrenceRuleID != nil
        let isAnchor = existingSeries && initialDraft.id == anchorID
        canEditRepeatSettings = true
        requiresScheduleConfirmation = existingSeries && (
            (isAnchor && initialDraft.date != editedDraft.date) ||
            initialDraft.repeatFrequency != editedDraft.repeatFrequency ||
            initialDraft.repeatIntervalValue != editedDraft.repeatIntervalValue ||
            initialDraft.repeatOnWorkdays != editedDraft.repeatOnWorkdays ||
            initialDraft.repeatOccurrenceCount != editedDraft.repeatOccurrenceCount ||
            initialDraft.repeatEndDate != editedDraft.repeatEndDate
        )
    }
}
