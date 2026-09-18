import SwiftUI

/// Indentation belongs to the entire label, including the dot and description.
/// Currency and selection controls stay at the trailing edge.
struct AccountSelectionLabel: View {
    let account: Account
    let depth: Int
    var currency: String = ""
    var selected = false
    var showCurrency = true
    @ScaledMetric(relativeTo: .body) private var selectionWidth: CGFloat = 20

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            HStack(spacing: 10) {
                if account.kind == .income || account.kind == .expense {
                    Circle().fill(AppColors.color(account.colorName)).frame(width: 14, height: 14)
                }
                VStack(alignment: .leading, spacing: 2) {
                    Text(account.name).foregroundColor(Color(uiColor: .label))
                        .fixedSize(horizontal: false, vertical: true)
                    if !account.note.isEmpty {
                        Text(account.note).font(.footnote).foregroundColor(Color(uiColor: .secondaryLabel))
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
            if showCurrency { Text(currency).foregroundColor(Color(uiColor: .secondaryLabel)).fixedSize() }
            if selected {
                Image(systemName: "checkmark")
                    .fontWeight(.semibold).foregroundColor(.blue)
                    .frame(width: selectionWidth)
                    .accessibilityIdentifier("account-selection-checkmark")
            } else {
                Spacer(minLength: 0).frame(width: selectionWidth).accessibilityHidden(true)
            }
        }
        .padding(.leading, CGFloat(max(depth, 0)) * 22)
        .frame(maxWidth: .infinity, alignment: .leading)
        .contentShape(Rectangle())
        .alignmentGuide(.listRowSeparatorLeading) { _ in 0 }
    }
}
