import XCTest
import SwiftUI
import MarkdownUI
import WebKit
@testable import FinancesClone

@MainActor
final class AssistantMarkdownTests: XCTestCase {
    private let source = """
    ## Total: **888.96 USD**

    Personal spending, including *uncleared* entries.

    ### Dining — $373.85
    | Date (2026) | Payee | Amount |
    |:---|:---|---:|
    | Sep 16 | TEST Coffee Shop | $5.50 |
    | Sep 16 | TEST Mixed Purchase — dining portion | $10.00 |
    | Sep 15 | Bistro | $48.50 |

    - Groceries: **$515.11**
    - Dining: $373.85

    1. Read the receipt.
    2. Check the account.

    > Amounts are in USD. Transfers are excluded.

    ```swift
    let amount = Decimal(string: "888.96")
    ```

    [Source](https://example.com/receipt) · ~~Old estimate~~
    """

    func testFinanceMarkdownRecognizesBlocksTablesAndInlineFormatting() {
        let html = MarkdownContent(source).renderHTML()
        for expected in ["<h2>", "<h3>", "<table>", "<thead>", "<tbody>", "<ul>", "<ol>", "<blockquote>", "<pre>", "<strong>", "<em>", "<del>"] {
            XCTAssertTrue(html.contains(expected), "Missing Markdown structure: \(expected)")
        }
        XCTAssertTrue(html.contains("888.96"))
        XCTAssertTrue(html.contains("$5.50"))
        XCTAssertFalse(MarkdownContent(source).renderPlainText().contains("##"))
    }

    func testOnlyExplicitWebLinksCanOpenFromModelMarkdown() throws {
        for link in ["https://example.com/receipt", "http://localhost:5184/"] { XCTAssertTrue(AssistantMarkdown.permitsLink(try XCTUnwrap(URL(string: link)))) }
        for link in ["javascript:alert(1)", "file:///private/receipt", "finances://delete", "https://user:password@example.com/"] {
            XCTAssertFalse(AssistantMarkdown.permitsLink(try XCTUnwrap(URL(string: link))))
        }
    }

    func testTableHasOneSelectionRangeAcrossCellsAndRows() async throws {
        let host = UIHostingController(rootView: AssistantMarkdown(source: source))
        let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
        let window = UIWindow(windowScene: scene)
        window.frame = CGRect(x: 0, y: 0, width: 320, height: 720)
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true }
        host.view.frame = window.bounds
        host.view.layoutIfNeeded()
        let table = try await loadedTable(in: host.view)
        let selected = try await table.evaluateJavaScript("""
        const cells = document.querySelectorAll('td');
        const range = document.createRange();
        range.setStart(cells[1].firstChild, 5);
        range.setEnd(cells[5].firstChild, 6);
        const selection = window.getSelection();
        selection.removeAllRanges(); selection.addRange(range);
        selection.toString();
        """) as? String
        let text = try XCTUnwrap(selected)
        XCTAssertTrue(text.hasPrefix("Coffee Shop"), text)
        for expected in ["$5.50", "Sep 16", "TEST Mixed Purchase", "$10.00"] {
            XCTAssertTrue(text.contains(expected), text)
        }
        XCTAssertFalse(text.contains("Bistro"), "Partial selection must exclude later rows")
        XCTAssertTrue(table.configuration.preferences.isTextInteractionEnabled)
        XCTAssertFalse(table.configuration.defaultWebpagePreferences.allowsContentJavaScript)
        XCTAssertFalse(table.configuration.websiteDataStore.isPersistent)
    }

    func testTableDocumentDoesNotLoadModelImagesOrExecutableHTML() {
        let markdown = """
        | Image | Content |
        |---|---|
        | ![receipt](https://example.com/tracker.png) | <script>alert(1)</script> |
        """
        let document = AssistantSelectableTable.document(html: AssistantSelectableTable.renderHTML(markdown), fontSize: 17, isDark: false)
        XCTAssertTrue(document.contains("default-src 'none'"))
        XCTAssertTrue(document.contains("<span>receipt</span>"))
        XCTAssertFalse(document.contains("<img"))
        XCTAssertFalse(document.contains("<script>"))
    }

    func testTablePreservesEscapedPipesInlineFormattingAndColumnAlignment() {
        let markdown = #"""
        | Category | Amount |
        |:---|---:|
        | **Food** \| Dining | `$5.50` |
        | [Receipt](https://example.com/receipt) | *$12.00* |
        """#
        let html = AssistantSelectableTable.renderHTML(MarkdownContent(markdown).renderMarkdown())
        for expected in ["<th align=\"left\">Category</th>", "<th align=\"right\">Amount</th>",
                         "<strong>Food</strong> | Dining", "<code>$5.50</code>", "<em>$12.00</em>",
                         "href=\"https://example.com/receipt\""] {
            XCTAssertTrue(html.contains(expected), "Missing \(expected): \(html)")
        }
    }

    func testFinanceMarkdownRendersInNarrowLightAndAccessibleDarkLayouts() async throws {
        for (scheme, size, name) in [(ColorScheme.light, DynamicTypeSize.large, "light"), (.dark, .accessibility1, "dark-large-text")] {
            let root = ScrollView {
                AssistantMarkdown(source: source).padding(12)
                    .background(Color(uiColor: .secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
                    .padding(12)
            }.environment(\.colorScheme, scheme).environment(\.dynamicTypeSize, size)
            let host = UIHostingController(rootView: root)
            let scene = try XCTUnwrap(UIApplication.shared.connectedScenes.first as? UIWindowScene)
            let window = UIWindow(windowScene: scene)
            window.frame = CGRect(x: 0, y: 0, width: 320, height: 720)
            window.rootViewController = host; window.makeKeyAndVisible()
            host.view.frame = window.bounds; host.view.layoutIfNeeded()
            let table = try await loadedTable(in: host.view)
            try await Task.sleep(for: .milliseconds(100))
            host.view.layoutIfNeeded()
            XCTAssertGreaterThan(table.bounds.height, 50, "The loaded table must be visible")
            XCTAssertGreaterThan(table.scrollView.contentSize.width, table.bounds.width, "The wide table must scroll horizontally")
            let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
            XCTAssertTrue(scrolls.contains { $0.contentSize.width > $0.bounds.width + 1 }, "Wide tables/code should scroll inside the bubble")
            if let outer = scrolls.first { XCTAssertLessThanOrEqual(outer.contentSize.width, 321, "The transcript must not overflow horizontally") }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Assistant Markdown \(name)"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

    private func loadedTable(in view: UIView) async throws -> WKWebView {
        let table = try XCTUnwrap(descendants(view).compactMap { $0 as? WKWebView }.first)
        for _ in 0..<100 {
            if (try? await table.evaluateJavaScript("document.querySelectorAll('td').length")) as? Int == 9 { return table }
            try await Task.sleep(for: .milliseconds(100))
        }
        XCTFail("Table cells did not load")
        return table
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
