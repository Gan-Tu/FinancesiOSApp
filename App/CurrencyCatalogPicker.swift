import SwiftUI

struct CurrencyCatalogPicker: View {
    @Binding var selectedName: String
    @State private var search = ""

    private var options: [JournalCurrencyOption] {
        JournalCurrencyCatalog.commonFirstOptions.filter { option in
            search.isEmpty || option.name.localizedCaseInsensitiveContains(search) || option.symbol.localizedCaseInsensitiveContains(search)
        }
    }

    var body: some View {
        List(options) { option in
            CurrencyPickerChoice(option: option, selectedName: $selectedName)
            .listRowInsets(EdgeInsets(top: 0, leading: 20, bottom: 0, trailing: 20))
        }
        .listStyle(.insetGrouped)
        .compactGroupedForm()
        .searchable(text: $search, prompt: "Currency name or code")
        .navigationTitle("Currency")
        .navigationBarTitleDisplayMode(.large)
        .overlay { if options.isEmpty { ContentUnavailableView.search(text: search) } }
    }
}

private struct CurrencyPickerChoice: View {
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dismissSearch) private var dismissSearch
    let option: JournalCurrencyOption
    @Binding var selectedName: String
    var body: some View {
        Button {
            dismissSearch()
            selectedName = option.name
            dismiss()
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(option.name).foregroundColor(option.name == selectedName ? .blue : Color(uiColor: .label))
                    Text(option.symbol).font(.caption).foregroundColor(Color(uiColor: .secondaryLabel))
                }
                Spacer()
                if option.name == selectedName { Image(systemName: "checkmark").fontWeight(.semibold).foregroundStyle(.tint) }
            }.contentShape(Rectangle())
        }.buttonStyle(.plain)
    }
}
