import SwiftUI
import Charts

struct RegisterChart: View {
    let months: [RegisterMonth]
    @State private var monthsShown = 6
    @State private var currencyID: UUID?
    @State private var selectedDate: Date?

    private var currencies: [RegisterMoney] {
        var seen = Set<UUID>()
        return months.flatMap { $0.income + $0.expenses }.filter { seen.insert($0.id).inserted }.sorted { $0.symbol < $1.symbol }
    }
    private var selectedCurrency: UUID? { currencyID ?? currencies.first?.id }
    private var visible: [RegisterMonth] {
        let cutoff = Calendar.current.date(byAdding: .month, value: -(monthsShown - 1), to: Calendar.current.dateInterval(of: .month, for: Date())!.start)!
        return months.filter { $0.date >= cutoff && $0.date <= Date() }.sorted { $0.date < $1.date }
    }

    var body: some View {
        VStack(spacing: 12) {
            HStack {
                Text("Cash Flow").font(.headline)
                Spacer()
                if currencies.count > 1 {
                    Picker("Currency", selection: Binding(get: { selectedCurrency }, set: { currencyID = $0 })) {
                        ForEach(currencies) { Text($0.symbol).tag(Optional($0.id)) }
                    }.labelsHidden()
                }
                Picker("Period", selection: $monthsShown) {
                    Text("6 Months").tag(6); Text("12 Months").tag(12); Text("24 Months").tag(24)
                }.labelsHidden()
            }
            if visible.isEmpty {
                Text("No cash flow in this period").foregroundStyle(.secondary).frame(height: 140)
            } else {
                Chart(visible) { month in
                    BarMark(x: .value("Month", month.date, unit: .month), y: .value("Amount", value(month.income)))
                        .foregroundStyle(by: .value("Type", "Income")).position(by: .value("Type", "Income"))
                    BarMark(x: .value("Month", month.date, unit: .month), y: .value("Amount", -value(month.expenses)))
                        .foregroundStyle(by: .value("Type", "Expenses")).position(by: .value("Type", "Expenses"))
                }
                .chartForegroundStyleScale(["Income": Color.green, "Expenses": Color.red])
                .chartXAxis { AxisMarks(values: .stride(by: .month)) { AxisValueLabel(format: .dateTime.month(.abbreviated)) } }
                .chartXSelection(value: $selectedDate)
                .frame(height: 170)
                if let selectedDate, let month = visible.first(where: { Calendar.current.isDate($0.date, equalTo: selectedDate, toGranularity: .month) }) {
                    Text("\(month.date.formatted(.dateTime.month(.wide).year())): \(moneyString(Decimal(value(month.income) + value(month.expenses)), symbol: currencies.first(where: { $0.id == selectedCurrency })?.symbol ?? "USD")) net")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        }.padding(.vertical, 4)
    }
    private func value(_ values: [RegisterMoney]) -> Double { NSDecimalNumber(decimal: values.first { $0.id == selectedCurrency }?.amount ?? 0).doubleValue }
}

struct MonthSummaryView: View {
    @EnvironmentObject private var store: MobileLedgerStore
    @Environment(\.dismiss) private var dismiss
    let month: Date
    let scope: MobileTransactionScope
    let ledgerID: UUID?
    @State private var route: EditorRoute?
    @State private var navigationPath: [MobileRoute] = []

    private var interval: DateInterval { Calendar.current.dateInterval(of: .month, for: month)! }
    private var rows: [LedgerTransaction] { store.transactions(scope: scope, ledgerID: ledgerID).filter { $0.date >= interval.start && $0.date < interval.end } }
    private var cashFlow: RegisterCashFlow { RegisterCashFlow.build(data: store.data, rows: rows, scope: scope) }

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
