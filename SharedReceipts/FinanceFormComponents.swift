import SwiftUI

/// Geometry follows the compact grouped forms in the supplied iPhone recording.
/// Minimum heights grow with Dynamic Type instead of clipping larger text.
struct FinanceForm<Content: View>: View {
    var spacing: CGFloat = 40
    var topInset: CGFloat = 18
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: spacing) { content }
                .padding(.horizontal, 22)
                .padding(.top, topInset)
                .padding(.bottom, 24)
                .frame(maxWidth: 620)
                .frame(maxWidth: .infinity)
        }
        .background(Color(uiColor: .systemGroupedBackground))
        .scrollDismissesKeyboard(.interactively)
    }
}

struct FinanceFormCard<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 0) { content }
            .frame(maxWidth: .infinity)
            .background(Color(uiColor: .secondarySystemGroupedBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10))
    }
}

struct FinanceFormRow<Content: View>: View {
    var last = false
    var separatorLeading: CGFloat = 20
    @ViewBuilder let content: Content
    @ScaledMetric(relativeTo: .body) private var minimumHeight: CGFloat = 47
    var body: some View {
        content
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 20)
            .padding(.vertical, 8)
            .frame(minHeight: minimumHeight)
            .overlay(alignment: .bottom) {
                if !last { Divider().padding(.leading, separatorLeading) }
            }
    }
}

/// Form cards live in a ScrollView, where SwiftUI's List-only swipeActions
/// do not run. A horizontal scroller lets the system arbitrate vertical form
/// scrolling and horizontal reveals without a competing drag recognizer.
struct FinanceDeletableFormRow<Content: View>: View {
    var last = false
    let canDelete: Bool
    let deleteIdentifier: String
    let delete: () -> Void
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 0) {
                FinanceFormRow(last: last) { content }
                    .containerRelativeFrame(.horizontal)
                if canDelete {
                    Button(role: .destructive, action: delete) {
                        Text("Delete")
                            .foregroundStyle(.white)
                            .frame(width: 80)
                            .frame(maxHeight: .infinity)
                            .background(Color.red)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .accessibilityIdentifier(deleteIdentifier)
                }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .contentShape(Rectangle())
        .scrollBounceBehavior(.basedOnSize)
        .scrollTargetBehavior(PostingDeleteScrollBehavior())
        .accessibilityActions {
            if canDelete { Button("Remove Posting", role: .destructive, action: delete) }
        }
        .contextMenu {
            if canDelete { Button("Remove Posting", role: .destructive, action: delete) }
        }
    }
}

private struct PostingDeleteScrollBehavior: ScrollTargetBehavior {
    func updateTarget(_ target: inout ScrollTarget, context: TargetContext) {
        let revealWidth = max(0, context.contentSize.width - context.containerSize.width)
        target.rect.origin.x = target.rect.minX > revealWidth / 2 ? revealWidth : 0
    }
}

struct FinanceFormLabel: View {
    let title: String
    let value: String
    var chevron = true
    var body: some View {
        HStack(spacing: 8) {
            Text(title).foregroundStyle(.primary)
            Spacer(minLength: 12)
            Text(value).foregroundStyle(.secondary).lineLimit(1)
            if chevron { Image(systemName: "chevron.right").font(.footnote.weight(.semibold)).foregroundStyle(.tertiary) }
        }.contentShape(Rectangle())
    }
}

struct CompactGroupedFormStyle: ViewModifier {
    var sectionSpacing: CGFloat = 20
    func body(content: Content) -> some View {
        content
            .contentMargins(.horizontal, 22, for: .scrollContent)
            .environment(\.defaultMinListRowHeight, 47)
            .listRowSpacing(0)
            .listSectionSpacing(.custom(sectionSpacing))
    }
}

extension View {
    func compactGroupedForm(sectionSpacing: CGFloat = 20) -> some View { modifier(CompactGroupedFormStyle(sectionSpacing: sectionSpacing)) }
}
