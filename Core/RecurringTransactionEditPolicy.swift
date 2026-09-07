import Foundation

/// Keeps the editor's choices within the existing recurrence engine's scope:
/// generated rows can change details/date, while the first entry owns Repeat.
struct RecurringTransactionEditPolicy: Equatable {
    let canEditRepeatSettings: Bool
    let requiresScheduleConfirmation: Bool

    init(initialDraft: TransactionDraft, editedDraft: TransactionDraft, anchorID: UUID?) {
        let existingSeries = initialDraft.id != nil && initialDraft.recurrenceRuleID != nil
        let isAnchor = existingSeries && initialDraft.id == anchorID
        canEditRepeatSettings = !existingSeries || isAnchor
        requiresScheduleConfirmation = isAnchor && (
            initialDraft.date != editedDraft.date ||
            initialDraft.repeatFrequency != editedDraft.repeatFrequency ||
            initialDraft.repeatIntervalValue != editedDraft.repeatIntervalValue ||
            initialDraft.repeatOnWorkdays != editedDraft.repeatOnWorkdays ||
            initialDraft.repeatOccurrenceCount != editedDraft.repeatOccurrenceCount ||
            initialDraft.repeatEndDate != editedDraft.repeatEndDate
        )
    }
}
