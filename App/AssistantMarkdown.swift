import SwiftUI
import WebKit
import cmark_gfm
import cmark_gfm_extensions
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
            AssistantMarkdownTable(html: AssistantSelectableTable.renderHTML(configuration.content.renderMarkdown()))
                .markdownMargin(top: .em(0.2), bottom: .em(0.65))
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

/// SwiftUI's per-cell Text selection cannot extend across a Grid. A single
/// local HTML table gives WebKit one selection range across every cell/row.
private struct AssistantMarkdownTable: View {
    let html: String
    @State private var height: CGFloat = 1
    @ScaledMetric(relativeTo: .body) private var fontSize: CGFloat = 15.3
    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.openURL) private var openURL

    var body: some View {
        AssistantSelectableTable(html: html, fontSize: fontSize, isDark: colorScheme == .dark,
                                 height: $height, openLink: { openURL($0) })
            .frame(height: height)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AssistantSelectableTable: UIViewRepresentable {
    let html: String
    let fontSize: CGFloat
    let isDark: Bool
    @Binding var height: CGFloat
    let openLink: (URL) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(parent: self) }

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = false
        configuration.preferences.isTextInteractionEnabled = true
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.isOpaque = false
        view.backgroundColor = .clear
        view.scrollView.backgroundColor = .clear
        view.scrollView.bounces = false
        view.scrollView.showsVerticalScrollIndicator = false
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.navigationDelegate = context.coordinator
        view.accessibilityIdentifier = "assistant.table"
        return view
    }

    func updateUIView(_ view: WKWebView, context: Context) {
        context.coordinator.parent = self
        let document = Self.document(html: html, fontSize: fontSize, isDark: isDark)
        // Preserve an active selection when unrelated chat state updates.
        guard document != context.coordinator.document else { return }
        context.coordinator.document = document
        view.loadHTMLString(document, baseURL: nil)
    }

    static func renderHTML(_ markdown: String) -> String {
        // Render the parsed GFM table directly. MarkdownUI 2.4.1's rebuilt
        // cmark nodes omit cell metadata required by cmark 0.8's HTML renderer.
        cmark_gfm_core_extensions_ensure_registered()
        guard let parser = cmark_parser_new(CMARK_OPT_DEFAULT) else { return "" }
        defer { cmark_parser_free(parser) }
        for name in ["table", "strikethrough", "autolink", "tagfilter"] {
            if let syntax = cmark_find_syntax_extension(name) { cmark_parser_attach_syntax_extension(parser, syntax) }
        }
        cmark_parser_feed(parser, markdown, markdown.utf8.count)
        guard let document = cmark_parser_finish(parser) else { return "" }
        defer { cmark_node_free(document) }
        guard let html = cmark_render_html(document, CMARK_OPT_DEFAULT, cmark_parser_get_syntax_extensions(parser)) else { return "" }
        defer { free(html) }
        return String(cString: html)
    }

    static func document(html: String, fontSize: CGFloat, isDark: Bool) -> String {
        // cmark omits raw HTML and unsafe links by default. Images are
        // represented by their alt text, never fetched as a side effect.
        let content = html.replacingOccurrences(of: #"<img\b[^>]*\balt="([^"]*)"[^>]*>"#,
                                                 with: "<span>$1</span>", options: .regularExpression)
        return """
        <!doctype html><html><head>
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; base-uri 'none'; form-action 'none'">
        <style>
        :root { color-scheme: \(isDark ? "dark" : "light"); }
        body { margin: 0; font: \(fontSize)px -apple-system; color: \(isDark ? "#fff" : "#000");
               -webkit-text-size-adjust: none; -webkit-user-select: text; user-select: text; }
        table { border-collapse: collapse; width: max-content; }
        th, td { padding: 7px 10px; border: 1px solid \(isDark ? "#555" : "#ccc"); white-space: nowrap; }
        th { font-weight: 600; }
        tbody tr:nth-child(odd) { background: \(isDark ? "#ffffff09" : "#00000009"); }
        a { color: \(isDark ? "#64aaff" : "#0066cc"); }
        code { font-family: ui-monospace, monospace; }
        </style></head><body>\(content)</body></html>
        """
    }

    final class Coordinator: NSObject, WKNavigationDelegate {
        var parent: AssistantSelectableTable
        var document = ""

        init(parent: AssistantSelectableTable) { self.parent = parent }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            // Measure the table rather than the viewport so streaming edits
            // and Dynamic Type changes can shrink as well as grow the view.
            webView.evaluateJavaScript("document.querySelector('table').getBoundingClientRect().height") { [weak self] result, _ in
                guard let self, let value = result as? Double, value.isFinite, value > 0 else { return }
                self.parent.height = ceil(value)
            }
        }

        func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction) async -> WKNavigationActionPolicy {
            if action.navigationType == .linkActivated, let url = action.request.url,
               AssistantMarkdown.permitsLink(url) {
                parent.openLink(url)
            }
            // Only the locally loaded document belongs in the table view.
            return action.navigationType == .other && action.request.url?.absoluteString == "about:blank" ? .allow : .cancel
        }
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
