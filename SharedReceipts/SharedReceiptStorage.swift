import Foundation

enum SharedReceiptStorage {
    static let groupIdentifier = "group.dev.gan.FinancesApp.iOS"

    static func inbox(demo: Bool = false) throws -> SharedReceiptInbox {
        guard let container = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw SharedReceiptError(message: "Finances could not access shared receipts. Open Finances once, then try sharing again.")
        }
        return SharedReceiptInbox(directory: container.appendingPathComponent(demo ? "DemoReceipts" : "Receipts", isDirectory: true))
    }

    #if DEBUG
    // Set only by the explicitly isolated native-share UI test launch. Release
    // builds never read this flag or open the demo inbox.
    static var usesDemoInbox: Bool {
        get { UserDefaults(suiteName: groupIdentifier)?.bool(forKey: "nativeShareDemo") ?? false }
        set { UserDefaults(suiteName: groupIdentifier)?.set(newValue, forKey: "nativeShareDemo") }
    }
    static var demoAIBehavior: String {
        get { UserDefaults(suiteName: groupIdentifier)?.string(forKey: "nativeShareAIBehavior") ?? "disabled" }
        set { UserDefaults(suiteName: groupIdentifier)?.set(newValue, forKey: "nativeShareAIBehavior") }
    }
    #endif
}
