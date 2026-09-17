import XCTest
import SwiftUI
import MarkdownUI
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
            try await Task.sleep(for: .milliseconds(180))
            host.view.layoutIfNeeded()
            let scrolls = descendants(host.view).compactMap { $0 as? UIScrollView }
            XCTAssertTrue(scrolls.contains { $0.contentSize.width > $0.bounds.width + 1 }, "Wide tables/code should scroll inside the bubble")
            if let outer = scrolls.first { XCTAssertLessThanOrEqual(outer.contentSize.width, 321, "The transcript must not overflow horizontally") }
            let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true) }
            let attachment = XCTAttachment(image: image); attachment.name = "Assistant Markdown \(name)"; attachment.lifetime = .keepAlways; add(attachment)
            window.isHidden = true
        }
    }

    private func descendants(_ view: UIView) -> [UIView] { view.subviews.flatMap { [$0] + descendants($0) } }
}
