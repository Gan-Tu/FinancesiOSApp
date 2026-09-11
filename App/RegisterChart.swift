import SwiftUI
import Charts

struct RegisterChart: View {
    let months: [RegisterMonth]
    let isLoading: Bool
    @AppStorage("display.chartMonths", store: MobileDisplayPreferences.defaults) private var monthsShown = 6
    @AppStorage private var currencyID: String
    @State private var selectedDate: Date?
    @ScaledMetric(relativeTo: .caption) private var captionHeight = 18

    init(months: [RegisterMonth], ledgerID: UUID?, isLoading: Bool = false) {
        self.months = months
        self.isLoading = isLoading
        _currencyID = AppStorage(wrappedValue: "", "display.chartCurrency.\(ledgerID?.uuidString ?? "all")", store: MobileDisplayPreferences.defaults)
    }

    private var currencies: [RegisterMoney] {
        var seen = Set<UUID>()
        return months.flatMap { $0.income + $0.expenses }.filter { seen.insert($0.id).inserted }.sorted { $0.symbol < $1.symbol }
    }
    private var period: Int { [6, 12, 24].contains(monthsShown) ? monthsShown : 6 }
    private var visible: [RegisterMonth] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -(period - 1), to: Calendar.current.dateInterval(of: .month, for: Date())!.start)!
        return months.filter { $0.date >= cutoff && $0.date <= Date() }.sorted { $0.date < $1.date }
    }

    var body: some View {
        let availableCurrencies = currencies
        let preferredCurrency = UUID(uuidString: currencyID)
        let selectedCurrency = availableCurrencies.first { $0.id == preferredCurrency }?.id ?? availableCurrencies.first?.id
        let visibleMonths = visible
        let summary = selectionSummary(visibleMonths: visibleMonths, selectedCurrency: selectedCurrency,
                                       currencies: availableCurrencies)
        VStack(spacing: 12) {
            HStack {
                Text("Cash Flow").font(.headline)
                Spacer()
                if availableCurrencies.count > 1 {
                    Picker("Currency", selection: Binding(get: { selectedCurrency }, set: { currencyID = $0?.uuidString ?? "" })) {
                        ForEach(availableCurrencies) { Text($0.symbol).tag(Optional($0.id)) }
                    }.labelsHidden()
                }
                Picker("Period", selection: Binding(get: { period }, set: { monthsShown = $0 })) {
                    Text("6 Months").tag(6); Text("12 Months").tag(12); Text("24 Months").tag(24)
                }.labelsHidden()
            }.frame(minHeight: 32)
            if isLoading {
                ProgressView("Loading Transactions").font(.footnote).frame(height: 170)
            } else if visibleMonths.isEmpty {
                Text("No cash flow in this period").foregroundStyle(.secondary).frame(height: 170)
            } else {
                Chart(visibleMonths) { month in
                    BarMark(x: .value("Month", month.date, unit: .month), y: .value("Amount", value(month.income, currencyID: selectedCurrency)))
                        .foregroundStyle(by: .value("Type", "Income")).position(by: .value("Type", "Income"))
                    BarMark(x: .value("Month", month.date, unit: .month), y: .value("Amount", -value(month.expenses, currencyID: selectedCurrency)))
                        .foregroundStyle(by: .value("Type", "Expenses")).position(by: .value("Type", "Expenses"))
                }
                .chartForegroundStyleScale(["Income": Color.green, "Expenses": Color.red])
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartXSelection(value: $selectedDate)
                .frame(height: 170)
            }
            Text(summary ?? " ")
                .font(.caption).foregroundStyle(.secondary).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading).frame(height: captionHeight)
                .opacity(summary == nil ? 0 : 1).accessibilityHidden(summary == nil)
        }
        .padding(.vertical, 4)
        .onChange(of: currencyID) { selectedDate = nil }
        .onChange(of: monthsShown) { selectedDate = nil }
    }
    private func selectionSummary(visibleMonths: [RegisterMonth], selectedCurrency: UUID?, currencies: [RegisterMoney]) -> String? {
        guard !isLoading, !visibleMonths.isEmpty else { return nil }
        let selectedMonth = selectedDate.flatMap { date in visibleMonths.first { Calendar.current.isDate($0.date, equalTo: date, toGranularity: .month) } }
        let months = selectedMonth.map { [$0] } ?? visibleMonths
        let net = months.reduce(Decimal.zero) { total, month in
            total + (month.income.first { $0.id == selectedCurrency }?.amount ?? 0) + (month.expenses.first { $0.id == selectedCurrency }?.amount ?? 0)
        }
        let label = selectedMonth?.date.formatted(.dateTime.month(.wide).year()) ?? "\(period) months"
        return "\(label): \(moneyString(net, symbol: currencies.first(where: { $0.id == selectedCurrency })?.symbol ?? "USD")) net"
    }
    private func value(_ values: [RegisterMoney], currencyID: UUID?) -> Double { NSDecimalNumber(decimal: values.first { $0.id == currencyID }?.amount ?? 0).doubleValue }
}

struct MonthSummaryView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    let month: Date
    let scope: MobileTransactionScope
    let ledgerID: UUID?
    var transactionIDs: Set<UUID>? = nil
    @State private var route: EditorRoute?
    @State private var navigationPath: [MobileRoute] = []
    @State private var cashFlow = RegisterCashFlow(income: [], expenses: [])
    @State private var hasLoaded = false
    @State private var loadError: String?

    private var interval: DateInterval { Calendar.current.dateInterval(of: .month, for: month)! }

    var body: some View {
        NavigationStack(path: $navigationPath) {
            List {
                ForEach([AccountKind.income, .expense]) { kind in
                    Section(kind.title) {
                        ForEach(kind == .income ? cashFlow.income : cashFlow.expenses) { bucket in
                            let account = bucket.account
                            NavigationLink {
                                TransactionListScreen(scope: .account(account.id), title: account.name, route: $route, dateInterval: interval, transactionIDs: bucket.transactionIDs, ledgerID: ledgerID, openTransaction: { navigationPath.append(.transaction($0)) })
                            } label: {
                                HStack {
                                    Circle().fill(AppColors.color(account.colorName)).frame(width: 10, height: 10)
                                    Text(account.name)
                                    Spacer()
                                    VStack(alignment: .trailing) {
                                        ForEach(bucket.amounts) { value in
                                            Text(moneyString(value.amount, symbol: value.symbol)).monospacedDigit().foregroundStyle(.secondary)
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            }
            .overlay {
                if let loadError {
                    ContentUnavailableView("Couldn’t Load Summary", systemImage: "exclamationmark.triangle", description: Text(loadError))
                } else if !hasLoaded {
                    ProgressView("Loading Summary")
                }
            }
            .task(id: store.registerContentRevision) {
                let revision = store.registerContentRevision
                let request = RegisterRenderRequest(data: store.data, rows: store.registerSourceRows(ledgerID: ledgerID),
                    scope: scope, search: "", dateInterval: interval, transactionIDs: transactionIDs, filtersScope: true)
                do {
                    let result = try await RegisterRenderWorker.shared.cashFlow(request)
                    try Task.checkCancellation()
                    guard revision == store.registerContentRevision else { return }
                    var update = Transaction(animation: nil); update.disablesAnimations = true
                    withTransaction(update) { cashFlow = result; hasLoaded = true; loadError = nil }
                } catch is CancellationError { /* The old projection stays visible while its replacement loads. */ }
                catch {
                    guard revision == store.registerContentRevision, !Task.isCancelled else { return }
                    loadError = error.localizedDescription
                }
            }
            .navigationTitle(month.formatted(.dateTime.month(.wide).year()))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .sheet(item: $route) { EditorSheet(route: $0) }
            .navigationDestination(for: MobileRoute.self) { target in
                if case .transaction(let id) = target { TransactionDetailScreen(transactionID: id, route: $route) }
            }
        }
    }
}
