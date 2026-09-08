import SwiftUI

/// Device-local visibility; never changes journal contents or the shared schema.
struct JournalVisibility: Equatable {
    static let preferenceKey = "display.hiddenJournals"
    var hiddenIDs: Set<UUID>
    init(rawValue: String) {
        hiddenIDs = Set(rawValue.split(separator: ",").compactMap { UUID(uuidString: String($0)) })
    }
    var rawValue: String { hiddenIDs.map(\.uuidString).sorted().joined(separator: ",") }
    mutating func setHidden(_ hidden: Bool, id: UUID) {
        if hidden { hiddenIDs.insert(id) } else { hiddenIDs.remove(id) }
    }
    func visible(in journals: [Ledger]) -> [Ledger] { journals.filter { !hiddenIDs.contains($0.id) } }
    func hidden(in journals: [Ledger]) -> [Ledger] { journals.filter { hiddenIDs.contains($0.id) } }
}

struct HiddenJournalsView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @AppStorage(JournalVisibility.preferenceKey, store: MobileDisplayPreferences.defaults) private var hiddenJournalIDs = ""

    private var journals: [Ledger] { JournalVisibility(rawValue: hiddenJournalIDs).hidden(in: store.orderedLedgers) }

    var body: some View {
        List {
            Section {
                ForEach(journals) { journal in
                    HStack(spacing: 12) {
                        Label(journal.name, systemImage: "archivebox")
                            .frame(maxWidth: .infinity, alignment: .leading)
                        Button("Show") {
                            var visibility = JournalVisibility(rawValue: hiddenJournalIDs)
                            visibility.setHidden(false, id: journal.id)
                            withAnimation(FinanceMotion.disclosure(reduceMotion: reduceMotion)) { hiddenJournalIDs = visibility.rawValue }
                        }
                        .buttonStyle(.borderless)
                        .accessibilityLabel("Show journal \(journal.name)")
                    }
                    .frame(minHeight: 44)
                }
            } footer: {
                Text("Hidden journals are kept and continue syncing. Show a journal to return it to the Journals list on this device.")
            }
        }
        .listStyle(.insetGrouped).compactGroupedForm()
        .animation(FinanceMotion.disclosure(reduceMotion: reduceMotion), value: hiddenJournalIDs)
        .overlay {
            if journals.isEmpty { ContentUnavailableView("No Hidden Journals", systemImage: "archivebox", description: Text("Use Hide on a journal to keep it out of the main list.")) }
        }
        .navigationTitle("Hidden Journals")
        .navigationBarTitleDisplayMode(.inline)
    }
}
