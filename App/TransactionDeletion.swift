import SwiftUI

struct TransactionDeletionConfirmation: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var transaction: LedgerTransaction?
    var onDeleted: () -> Void = {}
    @State private var isDeleting = false

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
        guard !isDeleting else { return }
        isDeleting = true
        transaction = nil
        Task {
            defer { isDeleting = false }
            if await store.deleteTransactionAsync(row.id, scope: scope, expected: row) { onDeleted() }
        }
    }
}

struct TransactionDuplicateConfirmation: ViewModifier {
    @EnvironmentObject private var store: MobileLedgerStore
    @Binding var transaction: LedgerTransaction?
    @Binding var route: EditorRoute?

    func body(content: Content) -> some View {
        content.alert("Duplicate Transaction", isPresented: Binding(
            get: { transaction != nil }, set: { if !$0 { transaction = nil } }
        ), presenting: transaction) { row in
            Button("Duplicate") { duplicate(row, useToday: false) }
            Button("Duplicate With Today's Date") { duplicate(row, useToday: true) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func duplicate(_ row: LedgerTransaction, useToday: Bool) {
        guard let draft = store.duplicateTransactionDraft(row.id, useToday: useToday) else {
            transaction = nil
            store.validationError = ValidationError(message: "This transaction no longer exists.")
            return
        }
        transaction = nil
        route = .transaction(draft, "New Transaction")
    }
}

/// Register and Quick Search use identical actions and confirmation rules.
struct TransactionRowSwipeActions: ViewModifier {
    // Rows receive immutable display values; they do not each subscribe to the
    // entire store. Clear actions apply the boolean advertised by this row.
    let store: MobileLedgerStore
    let transaction: LedgerTransaction?
    @Binding var pendingDeletion: LedgerTransaction?
    @Binding var pendingDuplication: LedgerTransaction?
    @State private var isDeleting = false

    func body(content: Content) -> some View {
        content
            .swipeActions(edge: .trailing, allowsFullSwipe: false) {
                if let transaction {
                    // A destructive role removes the cell optimistically, before
                    // confirmation or asynchronous query refresh updates the list.
                    Button("Delete") {
                        if let rule = transaction.recurrenceRule, rule.frequency != .never {
                            pendingDeletion = transaction
                        } else {
                            guard !isDeleting else { return }
                            isDeleting = true
                            Task {
                                defer { isDeleting = false }
                                _ = await store.deleteTransactionAsync(transaction.id, scope: .occurrence, expected: transaction)
                            }
                        }
                    }.tint(.red).disabled(isDeleting)
                    Button("Duplicate") { pendingDuplication = transaction }.tint(.gray)
                }
            }
            .swipeActions(edge: .leading) {
                if let transaction {
                    let targetCleared = !transaction.cleared
                    Button(targetCleared ? "Cleared" : "Uncleared") {
                        FinancePerformanceTrace.begin("swipe-clear-\(transaction.id.uuidString)-\(targetCleared)")
                        store.setTransactionCleared(transaction.id, cleared: targetCleared)
                    }.tint(.blue)
                }
            }
    }
}
