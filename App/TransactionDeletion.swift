import SwiftUI

struct TransactionDeletionConfirmation: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var transaction: LedgerTransaction?
    var onDeleted: () -> Void = {}

    func body(content: Content) -> some View {
        content.confirmationDialog("You are deleting a repeating transaction.", isPresented: Binding(
            get: { transaction != nil }, set: { if !$0 { transaction = nil } }
        ), titleVisibility: .visible, presenting: transaction) { row in
            Button("Delete Only This Transaction", role: .destructive) { remove(row, scope: .occurrence) }
            if let rule = row.recurrenceRule, rule.frequency != .never {
                Button("Delete All Future Transactions", role: .destructive) { remove(row, scope: .future) }
            }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("Do you want to delete only the selected transaction or all future occurrences?")
        }
    }

    private func remove(_ row: LedgerTransaction, scope: RecurringJournalEditor.Scope) {
        store.deleteTransaction(row.id, scope: scope, expected: row)
        transaction = nil
        if store.validationError == nil { onDeleted() }
    }
}

struct TransactionDuplicateConfirmation: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var transaction: LedgerTransaction?

    func body(content: Content) -> some View {
        content.confirmationDialog("Duplicate Transaction", isPresented: Binding(
            get: { transaction != nil }, set: { if !$0 { transaction = nil } }
        ), titleVisibility: .hidden, presenting: transaction) { row in
            Button("Duplicate") { duplicate(row, useToday: false) }
            Button("Duplicate With Today's Date") { duplicate(row, useToday: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func duplicate(_ row: LedgerTransaction, useToday: Bool) {
        store.duplicateTransaction(row.id, useToday: useToday)
        if store.validationError == nil {
            do { try store.flushLocalChanges() }
            catch { store.validationError = ValidationError(message: "Duplicate failed: \(error.localizedDescription)") }
        }
        transaction = nil
    }
}
