#if DEBUG
import SwiftUI
import UIKit

/// Exercises the real extension with an in-memory image, like an unsaved
/// screenshot. Only reachable in an explicitly isolated demo launch.
struct SharedReceiptShareQA: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @State private var ready = false
    @State private var sharing = false
    var body: some View {
        VStack {
            Button("Share Unsaved QA Screenshot") { sharing = true }.disabled(!ready)
            Text("\(store.data.transactions.count) transactions").accessibilityIdentifier("share-qa-transaction-count")
        }
        .padding().background(.regularMaterial)
        .task {
            await SystemEntryRouter.shared.waitForCatalogUpdates()
            ready = true
        }
        .sheet(isPresented: $sharing, onDismiss: {
            Task { await SystemEntryRouter.shared.restoreSharedReceipts(store: store) }
        }) { InMemoryReceiptShare() }
    }
}

private struct InMemoryReceiptShare: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: 390, height: 220))
        let image = renderer.image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 390, height: 220))
            ("SYNTHETIC RECEIPT\nCoffee 12.50\nNot a real purchase" as NSString).draw(at: CGPoint(x: 24, y: 30),
                withAttributes: [.font: UIFont.systemFont(ofSize: 24), .foregroundColor: UIColor.black])
        }
        return UIActivityViewController(activityItems: [image], applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}
#endif
