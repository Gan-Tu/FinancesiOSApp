import SwiftUI

@MainActor
func compactTransactionDate(_ date: Date) -> String {
    let day: String
    if Calendar.current.isDateInToday(date) { day = "Today" }
    else if Calendar.current.isDateInYesterday(date) { day = "Yesterday" }
    else { day = date.formatted(.dateTime.month(.abbreviated).day().year()) }
    let time = DateFormatter()
    time.locale = Locale(identifier: "en_US_POSIX")
    time.dateFormat = "HH:mm"
    return day + " at " + time.string(from: date)
}

func repeatDescription(_ draft: TransactionDraft) -> String {
    guard draft.repeatFrequency != .never else { return "Never" }
    if draft.repeatIntervalValue == 1 && !draft.repeatOnWorkdays { return draft.repeatFrequency.title }
    return "Custom"
}

func repeatEndDescription(_ draft: TransactionDraft) -> String {
    if let count = draft.repeatOccurrenceCount { return "After \(count)" }
    if let end = draft.repeatEndDate { return end.formatted(date: .abbreviated, time: .omitted) }
    return "Never"
}

struct RepeatFrequencyEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Binding var draft: TransactionDraft
    private let choices: [RecurrenceFrequency] = [.never, .daily, .weekly, .monthly, .yearly]
    var body: some View {
        FinanceForm {
            FinanceFormCard {
                ForEach(choices) { frequency in
                    FinanceFormRow(last: frequency == .yearly) {
                        Button {
                            draft.repeatFrequency = frequency
                            draft.repeatIntervalValue = 1
                            draft.repeatOnWorkdays = false
                            dismiss()
                        } label: {
                            HStack {
                                Text(frequency.title).foregroundStyle(.primary)
                                Spacer()
                                if draft.repeatFrequency == frequency && draft.repeatIntervalValue == 1 && !draft.repeatOnWorkdays {
                                    Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint)
                                }
                            }.contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
            FinanceFormCard {
                FinanceFormRow(last: true) {
                    NavigationLink {
                        CustomRepeatEditor(draft: $draft)
                    } label: { FinanceFormLabel(title: "Custom", value: "") }
                    .buttonStyle(.plain)
                }
            }
        }
        .navigationTitle("Repeat").navigationBarTitleDisplayMode(.inline)
    }
}

struct CustomRepeatEditor: View {
    @Binding var draft: TransactionDraft
    var body: some View {
        FinanceForm {
            FinanceFormCard {
                FinanceFormRow {
                    HStack {
                    Text("Frequency")
                    Spacer()
                    Picker("Frequency", selection: $draft.repeatFrequency) {
                        ForEach([RecurrenceFrequency.daily, .weekly, .monthly, .yearly]) { Text($0.title).tag($0) }
                        if draft.repeatFrequency == .custom { Text("Imported Custom Pattern").tag(RecurrenceFrequency.custom) }
                    }.labelsHidden()
                    }
                }
                FinanceFormRow { Stepper("Every \(draft.repeatIntervalValue)", value: $draft.repeatIntervalValue, in: 1...99) }
                FinanceFormRow(last: true) { Toggle("Workdays", isOn: $draft.repeatOnWorkdays) }
            }
        }
        .navigationTitle("Custom Repeat").navigationBarTitleDisplayMode(.inline)
        .onAppear { if draft.repeatFrequency == .never { draft.repeatFrequency = .daily } }
    }
}

struct RepeatEndEditor: View {
    @Binding var draft: TransactionDraft
    var body: some View {
        FinanceForm {
            FinanceFormCard {
                FinanceFormRow {
                    Button {
                        draft.repeatEndDate = nil; draft.repeatOccurrenceCount = nil
                    } label: {
                        selection("Never", selected: draft.repeatEndDate == nil && draft.repeatOccurrenceCount == nil)
                    }.buttonStyle(.plain)
                }
                FinanceFormRow {
                    Button {
                        draft.repeatOccurrenceCount = nil
                        draft.repeatEndDate = draft.repeatEndDate ?? max(draft.date, Date())
                    } label: { selection("On Date", selected: draft.repeatEndDate != nil) }.buttonStyle(.plain)
                }
                if draft.repeatEndDate != nil {
                    DatePicker("End Date", selection: Binding(get: { draft.repeatEndDate ?? draft.date }, set: { draft.repeatEndDate = $0 }), in: draft.date..., displayedComponents: .date)
                        .datePickerStyle(.wheel).labelsHidden().frame(maxWidth: .infinity)
                    Divider()
                }
                FinanceFormRow(last: draft.repeatOccurrenceCount == nil) {
                    Button {
                        draft.repeatEndDate = nil; draft.repeatOccurrenceCount = draft.repeatOccurrenceCount ?? 1
                    } label: { selection("After", selected: draft.repeatOccurrenceCount != nil) }.buttonStyle(.plain)
                }
                if draft.repeatOccurrenceCount != nil {
                    FinanceFormRow(last: true) {
                        HStack {
                            Text("Occurrences")
                            TextField("Occurrences", value: Binding(get: { draft.repeatOccurrenceCount ?? 1 }, set: { draft.repeatOccurrenceCount = $0 }), format: .number)
                                .keyboardType(.numberPad).multilineTextAlignment(.trailing)
                        }
                    }
                }
            }
        }
        .navigationTitle("End Repeat").navigationBarTitleDisplayMode(.inline)
    }
    private func selection(_ title: String, selected: Bool) -> some View {
        HStack {
            Text(title).foregroundStyle(.primary)
            Spacer()
            if selected { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
        }.contentShape(Rectangle())
    }
}
