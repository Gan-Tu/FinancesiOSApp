import AppIntents
import Foundation

struct JournalIntentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Journal"
    static let defaultQuery = JournalIntentQuery()
    var id: UUID
    var name: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)") }
}

struct JournalIntentQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [JournalIntentEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [JournalIntentEntity] {
        try await SystemIntegrationCatalogRepository.shared.load().journals.map { .init(id: $0.id, name: $0.name) }
    }
    func entities(matching string: String) async throws -> [JournalIntentEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) }
    }
}

struct TemplateIntentEntity: AppEntity {
    static let typeDisplayRepresentation: TypeDisplayRepresentation = "Transaction Template"
    static let defaultQuery = TemplateIntentQuery()
    var id: UUID
    var name: String
    var journalName: String
    var displayRepresentation: DisplayRepresentation { .init(title: "\(name)", subtitle: "\(journalName)") }
}

struct TemplateIntentQuery: EntityStringQuery {
    func entities(for identifiers: [UUID]) async throws -> [TemplateIntentEntity] {
        try await suggestedEntities().filter { identifiers.contains($0.id) }
    }
    func suggestedEntities() async throws -> [TemplateIntentEntity] {
        try await SystemIntegrationCatalogRepository.shared.load().templates.map { .init(id: $0.id, name: $0.name, journalName: $0.journalName) }
    }
    func entities(matching string: String) async throws -> [TemplateIntentEntity] {
        try await suggestedEntities().filter { $0.name.localizedStandardContains(string) || $0.journalName.localizedStandardContains(string) }
    }
}

struct NewFinancesTransactionIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let title: LocalizedStringResource = "New Transaction"
    static let description = IntentDescription("Open an editable transaction draft. Nothing is recorded until you save.")
    static let openAppWhenRun = true
    @Parameter(title: "Journal") var journal: JournalIntentEntity?
    @Parameter(title: "Amount") var amount: IntentCurrencyAmount?
    @Parameter(title: "Payee") var payee: String?
    @Parameter(title: "Notes") var notes: String?
    static var parameterSummary: some ParameterSummary {
        Summary("Draft a transaction in \(\.$journal)") { \.$amount; \.$payee; \.$notes }
    }
    func perform() async throws -> some IntentResult {
        let capture = try CaptureSuggestion(source: .shortcut, date: Date(), amount: amount?.amount,
            currencyCode: amount?.currencyCode ?? "", merchant: payee ?? "", card: "", note: notes ?? "", journalID: journal?.id).validated()
        await SystemEntryRouter.shared.openNewTransaction(capture)
        return .result()
    }
}

struct UseFinancesTemplateIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let title: LocalizedStringResource = "Use Transaction Template"
    static let description = IntentDescription("Open a new transaction using one of your included templates.")
    static let openAppWhenRun = true
    @Parameter(title: "Template") var template: TemplateIntentEntity
    static var parameterSummary: some ParameterSummary { Summary("Create a transaction using \(\.$template)") }
    func perform() async throws -> some IntentResult {
        await SystemEntryRouter.shared.openTemplate(template.id)
        return .result()
    }
}

struct OpenFinancesSuggestionsIntent: AppIntent {
    static let authenticationPolicy: IntentAuthenticationPolicy = .requiresLocalDeviceAuthentication
    static let title: LocalizedStringResource = "Open Suggestions"
    static let description = IntentDescription("Review pending purchases captured from Wallet automations.")
    static let openAppWhenRun = true
    func perform() async throws -> some IntentResult {
        await SystemEntryRouter.shared.openSuggestions()
        return .result()
    }
}

struct CaptureWalletTransactionIntent: AppIntent {
    static let title: LocalizedStringResource = "Add Apple Pay to Suggestions"
    static let description = IntentDescription("Use with a Wallet transaction automation. Save a purchase to Suggestions for review; this does not post a transaction.")
    static let openAppWhenRun = false
    @Parameter(title: "Amount", inputConnectionBehavior: .connectToPreviousIntentResult) var amount: IntentCurrencyAmount
    @Parameter(title: "Merchant") var merchant: String
    @Parameter(title: "Card Name") var card: String?
    @Parameter(title: "Currency Code (optional override)") var currencyCode: String?
    @Parameter(title: "Date") var date: Date?
    @Parameter(title: "Journal") var journal: JournalIntentEntity?
    static var parameterSummary: some ParameterSummary {
        Summary("Add \(\.$amount) at \(\.$merchant) to Suggestions") { \.$card; \.$currencyCode; \.$date; \.$journal }
    }
    func perform() async throws -> some IntentResult & ProvidesDialog {
        let suggestion = CaptureSuggestion(source: .applePay, date: date ?? Date(), amount: amount.amount,
            currencyCode: currencyCode?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false ? currencyCode! : amount.currencyCode,
            merchant: merchant, card: card ?? "", note: "", journalID: journal?.id)
        try await CaptureSuggestionRepository.shared.add(suggestion)
        await MainActor.run { NotificationCenter.default.post(name: .financesSuggestionsChanged, object: nil) }
        return .result(dialog: "Saved to Suggestions. Review it in Finances before adding it to your journal.")
    }
}

extension Notification.Name {
    static let financesSuggestionsChanged = Notification.Name("FinancesSuggestionsChanged")
}

struct FinancesAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: NewFinancesTransactionIntent(), phrases: ["Log an expense in \(.applicationName)", "New transaction in \(.applicationName)"], shortTitle: "New Transaction", systemImageName: "square.and.pencil")
        AppShortcut(intent: UseFinancesTemplateIntent(), phrases: ["Use a template in \(.applicationName)"], shortTitle: "Use Template", systemImageName: "doc.badge.plus")
        AppShortcut(intent: OpenFinancesSuggestionsIntent(), phrases: ["Open suggestions in \(.applicationName)"], shortTitle: "Suggestions", systemImageName: "tray")
        AppShortcut(intent: NewReceiptTransactionIntent(), phrases: ["New receipt in \(.applicationName)"], shortTitle: "Receipt Transaction", systemImageName: "doc.viewfinder")
    }
}
