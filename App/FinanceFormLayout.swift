import SwiftUI

/// A record-based upload bar, or an activity bar when CloudKit has no total.
struct CloudSyncProgressBar: View {
    let progress: CloudSyncProgress
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var moving = false

    var body: some View {
        Group {
            if let fraction = progress.fractionCompleted {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
            } else {
                GeometryReader { geometry in
                    Capsule().fill(Color.accentColor.opacity(0.16))
                        .overlay(alignment: .leading) {
                            Capsule().fill(Color.accentColor)
                                .frame(width: geometry.size.width * 0.3)
                                .offset(x: geometry.size.width * (reduceMotion ? 0.35 : moving ? 0.7 : 0))
                                .animation(reduceMotion ? nil : .easeInOut(duration: 1.2).repeatForever(autoreverses: true), value: moving)
                        }
                }
                .onAppear { moving = true }
                .onDisappear { moving = false }
            }
        }
        .frame(height: 4)
        .tint(.accentColor)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Sync progress")
        .accessibilityValue(progress.detail ?? progress.message)
        .accessibilityIdentifier("cloud-sync-progress-bar")
    }
}

struct CloudSyncRunningStatus: View {
    let progress: CloudSyncProgress

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(progress.message.isEmpty ? progress.phase.title : progress.message,
                  systemImage: progress.phase.symbol)
                .foregroundStyle(.primary)
            CloudSyncProgressBar(progress: progress)
            if let detail = progress.detail {
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }
}

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

/// Keep the native button gesture (including scroll/swipe cancellation), but
/// make its entire row surface visibly respond without dimming the text.
struct TransactionRowButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .foregroundStyle(.primary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(configuration.isPressed ? Color(uiColor: .systemGray4) : .clear)
    }
}
