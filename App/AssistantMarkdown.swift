import SwiftUI
@preconcurrency import MarkdownUI

/// Native block rendering, shared by saved answers and the streaming reply.
/// Tables and code scroll independently instead of widening the chat bubble.
struct AssistantMarkdown: View, Equatable {
    let source: String

    var body: some View {
        Markdown(source)
            .markdownTheme(.assistant)
            .markdownImageProvider(AssistantMarkdownImageProvider())
            .markdownInlineImageProvider(AssistantMarkdownInlineImageProvider())
            .textSelection(.enabled)
            .environment(\.openURL, OpenURLAction { url in
                Self.permitsLink(url) ? .systemAction : .discarded
            })
            .frame(maxWidth: .infinity, alignment: .leading)
    }

    nonisolated static func permitsLink(_ url: URL) -> Bool {
        ["https", "http"].contains(url.scheme?.lowercased() ?? "")
            && !(url.host ?? "").isEmpty && url.user == nil && url.password == nil
    }
}

private extension MarkdownUI.Theme {
    @MainActor static let assistant = Theme.basic
        .text {
            ForegroundColor(.primary)
            BackgroundColor(nil)
        }
        .link { ForegroundColor(.accentColor) }
        .heading1 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.4)) }
                .markdownMargin(top: .em(0.6), bottom: .em(0.4))
                .accessibilityAddTraits(.isHeader)
        }
        .heading2 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.2)) }
                .markdownMargin(top: .em(0.6), bottom: .em(0.35))
                .accessibilityAddTraits(.isHeader)
        }
        .heading3 { configuration in
            configuration.label
                .markdownTextStyle { FontWeight(.semibold); FontSize(.em(1.05)) }
                .markdownMargin(top: .em(0.5), bottom: .em(0.3))
                .accessibilityAddTraits(.isHeader)
        }
        .paragraph { configuration in
            configuration.label
                .fixedSize(horizontal: false, vertical: true)
                .relativeLineSpacing(.em(0.12))
                .markdownMargin(top: .zero, bottom: .em(0.65))
        }
        .listItem { configuration in
            configuration.label.markdownMargin(top: .em(0.15))
        }
        .table { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: false)
                    .markdownTableBorderStyle(.init(color: Color.secondary.opacity(0.25)))
                    .markdownTableBackgroundStyle(.alternatingRows(.clear, Color.primary.opacity(0.035)))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .markdownMargin(top: .em(0.2), bottom: .em(0.65))
        }
        .tableCell { configuration in
            configuration.label
                .markdownTextStyle {
                    if configuration.row == 0 { FontWeight(.semibold) }
                    FontSize(.em(0.9))
                    BackgroundColor(nil)
                }
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
        }
        .codeBlock { configuration in
            ScrollView(.horizontal) {
                configuration.label
                    .fixedSize(horizontal: true, vertical: false)
                    .markdownTextStyle { FontFamilyVariant(.monospaced); FontSize(.em(0.88)) }
                    .padding(10)
            }
            .background(Color.primary.opacity(0.05), in: RoundedRectangle(cornerRadius: 8))
            .markdownMargin(top: .em(0.2), bottom: .em(0.65))
        }
        .blockquote { configuration in
            configuration.label
                .padding(.leading, 12)
                .overlay(alignment: .leading) { RoundedRectangle(cornerRadius: 2).fill(Color.secondary.opacity(0.4)).frame(width: 3) }
                .markdownMargin(top: .em(0.2), bottom: .em(0.65))
        }
}

/// Model-provided image URLs are never fetched automatically. Opening a web
/// image is an explicit link action; actual receipts use the app's file viewer.
@MainActor
private struct AssistantMarkdownImageProvider: @preconcurrency ImageProvider {
    func makeImage(url: URL?) -> some View {
        if let url, AssistantMarkdown.permitsLink(url) {
            Link(destination: url) { Label("Open image", systemImage: "photo") }
        } else {
            Label("Image unavailable", systemImage: "photo").foregroundStyle(.secondary)
        }
    }
}

private struct AssistantMarkdownInlineImageProvider: InlineImageProvider {
    func image(with url: URL, label: String) async throws -> Image { Image(systemName: "photo") }
}
