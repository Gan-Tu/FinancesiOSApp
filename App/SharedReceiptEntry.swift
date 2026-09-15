import AppIntents
import Foundation

extension SharedReceiptInbox {
    static let shared = SharedReceiptInbox(directory: SystemIntegrationStorage.directory
        .appendingPathComponent("Receipts", isDirectory: true))
}

struct NewReceiptTransactionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let title: LocalizedStringResource = "New Transaction with Receipts"
    static let description = IntentDescription("Open a new transaction with images or PDF receipts attached. Review it and choose Save in Finances when ready.")
    static var openAppWhenRun: Bool { true }

    // The broad file parameter keeps the action available on iOS 17. The inbox
    // validates image/PDF types before publishing any incoming receipt request.
    @Parameter(title: "Receipts", inputConnectionBehavior: .connectToPreviousIntentResult)
    var receipts: [IntentFile]

    static var parameterSummary: some ParameterSummary {
        Summary("Create a transaction with \(\.$receipts)")
    }

    func perform() async throws -> some IntentResult {
        let entry = try await SharedReceiptInbox.shared.stage(intentFiles: receipts)
        try await SystemEntryRouter.shared.openSharedReceipt(entry)
        return .result()
    }
}
