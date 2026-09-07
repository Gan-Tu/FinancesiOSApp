#!/usr/bin/env python3
"""Headless synthetic register benchmark; never opens a journal or Simulator."""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
BENCHMARK = r'''import Foundation
public func benchmark() {
 for size in [10000, 30000] {
  let ledger = Ledger(name: "Synthetic large journal")
  let usd = Commodity(ledgerID: ledger.id, symbol: "USD", name: "US Dollar")
  let root = Account(ledgerID: ledger.id, name: "Assets", kind: .asset)
  let accounts = (0..<200).map { Account(ledgerID: ledger.id, parentID: root.id, commodityID: usd.id, name: "Cash \($0)", kind: .asset) }
  let expense = Account(ledgerID: ledger.id, name: "Expenses", kind: .expense)
  let rows = (0..<size).map { index in
   LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1800000000 + Double(index)), payee: "Synthetic shop", note: "Synthetic transaction \(index)", number: "", cleared: true, postings: [Posting(accountID: accounts[index % accounts.count].id, commodityID: usd.id, amount: -10), Posting(accountID: expense.id, commodityID: usd.id, amount: 10)])
  }
  let data = JournalData(ledgers: [ledger], commodities: [usd], accounts: [root] + accounts + [expense], transactions: rows)
  for (name, scope) in [("all", MobileTransactionScope.all), ("account_group", .account(root.id))] {
   var times: [Double] = []
   for _ in 0..<3 {
    let start = ContinuousClock.now
    let result = RegisterPresentation.build(data: data, rows: rows, scope: scope)
    precondition(result.balances.count == size)
    let components = start.duration(to: .now).components
    times.append(Double(components.seconds) * 1000 + Double(components.attoseconds) / 1e15)
   }
   print("rows=\(size) scope=\(name) median_ms=\(times.sorted()[1])")
  }
 }
}
'''

with tempfile.TemporaryDirectory(prefix="finances-register-benchmark-") as directory:
    package = Path(directory)
    source = package / "Sources/FinancesClone"
    executable = package / "Sources/Benchmark"
    source.mkdir(parents=True)
    executable.mkdir(parents=True)
    (package / "Package.swift").write_text('''// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "FinancesPerformance", platforms: [.macOS(.v14)], targets: [.target(name: "FinancesClone"), .executableTarget(name: "Benchmark", dependencies: ["FinancesClone"])])
''')
    for relative in ["Core/Models.swift", "App/RegisterPresentation.swift"]:
        path = ROOT / relative
        (source / path.name).write_text(path.read_text())
    # Reuse the app's actual scope/day value types without linking its UIKit store.
    store = (ROOT / "App/MobileLedgerStore.swift").read_text()
    scope = store[store.index("enum MobileTransactionScope:"):store.index("enum MobileNewTransactionKind:")]
    day = store[store.index("struct MobileTransactionDaySection:"):store.index("struct MobileAccountFlowAccount:")]
    (source / "ScopeTypes.swift").write_text("import Foundation\n" + scope + day)
    (source / "BenchmarkEntry.swift").write_text(BENCHMARK)
    (executable / "main.swift").write_text("import FinancesClone\nbenchmark()\n")
    subprocess.run(["swift", "run", "-c", "release", "--package-path", str(package), "Benchmark"], check=True)
