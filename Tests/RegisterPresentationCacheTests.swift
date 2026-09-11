import XCTest
@testable import FinancesClone

@MainActor
final class RegisterPresentationCacheTests: XCTestCase {
    private actor Gate {
        var continuations: [CheckedContinuation<Void, Never>] = []
        var released = false
        func wait() async {
            if released { return }
            await withCheckedContinuation { continuations.append($0) }
        }
        func release() { released = true; let waiting = continuations; continuations.removeAll(); for continuation in waiting { continuation.resume() } }
    }

    private func request(_ data: JournalData, query: String = "") -> RegisterRenderRequest {
        RegisterRenderRequest(data: data, rows: data.transactions, scope: .all, search: query, dateInterval: nil, transactionIDs: nil)
    }
    private func key(_ request: RegisterRenderRequest, cache: RegisterPresentationCache) -> RegisterPresentationCacheKey {
        RegisterPresentationCacheKey(revision: cache.revision, ledgerID: request.data.selectedLedgerID, request: request)
    }

    func testConcurrentLoadsShareWorkAndRevisionRejectsLateResults() async throws {
        let data = DemoData.fixture()
        let request = request(data)
        let gate = Gate()
        let started = expectation(description: "Renderer started")
        let cache = RegisterPresentationCache { request in
            started.fulfill()
            await gate.wait()
            return RegisterRenderResult(presentation: RegisterPresentation.build(data: request.data, rows: request.rows, scope: request.scope))
        }
        let oldKey = key(request, cache: cache)
        let first = Task { try await cache.load(request, key: oldKey) }
        await fulfillment(of: [started], timeout: 5)
        let second = Task { try await cache.load(request, key: oldKey) }
        for _ in 0..<20 where cache.joinedCount == 0 { await Task.yield() }
        XCTAssertEqual(cache.renderCount, 1)
        XCTAssertEqual(cache.joinedCount, 1)
        cache.invalidate()
        await gate.release()
        for task in [first, second] {
            do { _ = try await task.value; XCTFail("Old revisions must never be published") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        }
        XCTAssertNil(cache.cached(for: oldKey))
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testRenderingConcurrencyIsBoundedAndCancelledQueueEntriesAreRemoved() async throws {
        let gate = Gate()
        let started = expectation(description: "Two active renders"); started.expectedFulfillmentCount = 2
        let cache = RegisterPresentationCache(maximumConcurrentRenders: 2) { request in
            started.fulfill()
            await gate.wait()
            return RegisterRenderResult(presentation: RegisterPresentation.build(data: request.data, rows: request.rows, scope: request.scope))
        }
        let data = DemoData.fixture()
        let a = request(data, query: "a"), b = request(data, query: "b"), c = request(data, query: "c")
        let first = Task { try await cache.load(a, key: key(a, cache: cache)) }
        let second = Task { try await cache.load(b, key: key(b, cache: cache)) }
        await fulfillment(of: [started], timeout: 5)
        let queued = Task { try await cache.load(c, key: key(c, cache: cache)) }
        for _ in 0..<20 where cache.queuedCount == 0 { await Task.yield() }
        XCTAssertEqual(cache.activeRenderCount, 2)
        XCTAssertEqual(cache.queuedCount, 1)
        queued.cancel()
        do { _ = try await queued.value; XCTFail("Queued caller was cancelled") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        XCTAssertEqual(cache.queuedCount, 0)
        await gate.release()
        _ = try await first.value; _ = try await second.value
        XCTAssertEqual(cache.maximumObservedActiveRenders, 2)
        XCTAssertEqual(cache.renderCount, 2)
    }

    func testMemoryWarningDoesNotStrandVisibleWaiterOrImmediatelyRefillCache() async throws {
        let gate = Gate()
        let started = expectation(description: "Visible render")
        let cache = RegisterPresentationCache { request in
            started.fulfill()
            await gate.wait()
            return RegisterRenderResult(presentation: RegisterPresentation.build(data: request.data, rows: request.rows, scope: request.scope))
        }
        let request = request(DemoData.fixture())
        let cacheKey = key(request, cache: cache)
        let visible = Task { try await cache.load(request, key: cacheKey) }
        await fulfillment(of: [started], timeout: 5)
        cache.purge()
        await gate.release()
        let result = try await visible.value
        XCTAssertEqual(result.presentation.amounts.count, request.rows.count)
        XCTAssertNil(cache.cached(for: cacheKey))
        XCTAssertEqual(cache.activeRenderCount, 0)
    }

    func testLRUAndMemoryBudgetBoundResultsAndPurgeReleasesThem() async throws {
        let cache = RegisterPresentationCache(maximumEntries: 2, maximumRows: 5) { request in
            let amounts = Dictionary(uniqueKeysWithValues: request.rows.map { ($0.id, [RegisterMoney]()) })
            return RegisterRenderResult(presentation: RegisterPresentation(months: [], amounts: amounts, balances: [:]))
        }
        let data = DemoData.fixture()
        let a = RegisterRenderRequest(data: data, rows: Array(data.transactions.prefix(3)), scope: .all, search: "a", dateInterval: nil, transactionIDs: nil)
        let b = RegisterRenderRequest(data: data, rows: Array(data.transactions.prefix(2)), scope: .all, search: "b", dateInterval: nil, transactionIDs: nil)
        let c = RegisterRenderRequest(data: data, rows: Array(data.transactions.prefix(2)), scope: .all, search: "c", dateInterval: nil, transactionIDs: nil)
        let aKey = key(a, cache: cache), bKey = key(b, cache: cache), cKey = key(c, cache: cache)
        _ = try await cache.load(a, key: aKey)
        _ = try await cache.load(b, key: bKey)
        XCTAssertNotNil(cache.cached(for: aKey))
        _ = try await cache.load(c, key: cKey)
        XCTAssertNotNil(cache.cached(for: aKey))
        XCTAssertNil(cache.cached(for: bKey))
        XCTAssertNotNil(cache.cached(for: cKey))
        XCTAssertEqual(cache.retainedRows, 5)
        XCTAssertEqual(cache.entryCount, 2)
        let large = request(data, query: "too large")
        _ = try await cache.load(large, key: key(large, cache: cache))
        XCTAssertLessThanOrEqual(cache.retainedRows, 5)
        XCTAssertNil(cache.cached(for: key(large, cache: cache)))
        cache.purge()
        XCTAssertEqual(cache.retainedRows, 0)
        XCTAssertEqual(cache.entryCount, 0)
    }

    func testStoreInvalidatesForContentButKeepsNavigationProgressAndTemplateChangesCached() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = DemoData.fixture(includeTemplates: true)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let request = request(data)
        let originalRevision = store.registerContentRevision
        let cacheKey = key(request, cache: store.registerPresentations)
        _ = try await store.registerPresentations.load(request, key: cacheKey)
        store.selectLedger(data.ledgers[1].id)
        store.cloudKitSyncDidUpdate(.running(message: "Uploading", detail: "1 of 2", fractionCompleted: 0.5, phase: .uploading))
        var template = store.templateDraft(for: data.transactionTemplates[0]); template.name = "Updated template"
        store.saveTransactionTemplate(template)
        XCTAssertEqual(store.registerContentRevision, originalRevision)
        XCTAssertNotNil(store.registerPresentations.cached(for: cacheKey))
        store.setTransactionCleared(data.transactions[0].id, cleared: !data.transactions[0].cleared)
        XCTAssertGreaterThan(store.registerContentRevision, originalRevision)
        XCTAssertNil(store.registerPresentations.cached(for: cacheKey))
        let beforeRename = store.registerContentRevision
        store.renameJournal(data.ledgers[0].id, name: "Renamed")
        XCTAssertGreaterThan(store.registerContentRevision, beforeRename)
        let beforeAccount = store.registerContentRevision
        var account = store.draft(for: data.accounts[1]); account.name = "New account label"
        store.saveAccount(account)
        XCTAssertGreaterThan(store.registerContentRevision, beforeAccount)
        try store.flushLocalChanges()
    }

    func testCalendarBoundariesAndStoreOwnershipSeparateCacheKeys() async throws {
        let data = DemoData.fixture()
        let a = RegisterPresentationCache(), b = RegisterPresentationCache()
        let request = request(data)
        let aKey = key(request, cache: a)
        _ = try await a.load(request, key: aKey)
        XCTAssertNil(b.cached(for: aKey))
        var later = request
        later.referenceDate = request.referenceDate.addingTimeInterval(86400)
        XCTAssertEqual(key(request, cache: a), key(later, cache: a), "A normal register stays reusable across day changes")
        let today = RegisterRenderRequest(data: data, rows: data.transactions, scope: .today, search: "", dateInterval: nil, transactionIDs: nil, filtersScope: true)
        var tomorrow = today; tomorrow.referenceDate = today.referenceDate.addingTimeInterval(86400)
        XCTAssertNotEqual(key(today, cache: a), key(tomorrow, cache: a))
    }

    func testCancellationInterruptsExpensivePresentationAndDailyBalancePasses() throws {
        let data = DemoData.fixture()
        XCTAssertThrowsError(try RegisterPresentation.build(data: data, rows: data.transactions, scope: .all, calendar: .current, cancellationCheck: { throw CancellationError() }))
        XCTAssertThrowsError(try AccountBalanceProjection.build(data: data, rows: data.transactions, cutoff: .distantFuture, cancellationCheck: { throw CancellationError() }))
        let cutoff = Calendar.current.dateInterval(of: .day, for: Date())!.end
        let projection = AccountBalanceProjection.build(data: data, rows: data.transactions.sorted { $0.date > $1.date }, cutoff: cutoff)
        let checking = try XCTUnwrap(data.accounts.first { $0.name == "Checking" })
        let expected = data.transactions.filter { $0.date < cutoff }.flatMap(\.postings).filter { $0.accountID == checking.id }.reduce(Decimal.zero) { $0 + $1.amount }
        XCTAssertEqual(projection.balances[checking.id]?.first?.amount, expected)
    }

    func testRegisterHeaderTotalsMatchCashFlowAcrossSplitCurrencyAndCategoryScopes() throws {
        var data = DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_788_858_000))
        let ledger = data.ledgers[0].id
        let groceries = try XCTUnwrap(data.accounts.first { $0.name == "Groceries" })
        let transportation = try XCTUnwrap(data.accounts.first { $0.name == "Transportation" })
        let usd = try XCTUnwrap(data.commodities.first { $0.ledgerID == ledger })
        let eur = Commodity(ledgerID: ledger, symbol: "EUR", name: "Euro")
        data.commodities.append(eur)
        data.transactions.append(LedgerTransaction(ledgerID: ledger, date: data.transactions[0].date,
            payee: "Split", note: "Refund and expense", number: "", cleared: true,
            postings: [Posting(accountID: groceries.id, commodityID: usd.id, amount: -12),
                       Posting(accountID: transportation.id, commodityID: eur.id, amount: 25)]))
        let rows = data.transactions.sorted { $0.date > $1.date }
        for scope in [MobileTransactionScope.all, .account(groceries.parentID ?? groceries.id), .account(transportation.id), .currency(usd.id), .currency(eur.id)] {
            let presentation = RegisterPresentation.build(data: data, rows: rows, scope: scope)
            for month in presentation.months {
                let expected = RegisterCashFlow.build(data: data, rows: month.days.flatMap(\.transactions), scope: scope)
                XCTAssertEqual(month.income, RegisterCashFlow.totals(expected.income))
                XCTAssertEqual(month.expenses, RegisterCashFlow.totals(expected.expenses))
            }
        }
    }

    func testBackgroundMonthSummaryPreservesDateScopeAndSelectedTransactionIDs() async throws {
        let data = DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_788_858_000))
        let row = try XCTUnwrap(data.transactions.first)
        let month = try XCTUnwrap(Calendar.current.dateInterval(of: .month, for: row.date))
        let request = RegisterRenderRequest(data: data, rows: data.transactions, scope: .all,
            search: "", dateInterval: month, transactionIDs: [row.id], filtersScope: true)
        let actual = try await RegisterRenderWorker.shared.cashFlow(request)
        let expected = RegisterCashFlow.build(data: data, rows: [row], scope: .all)
        XCTAssertEqual(RegisterCashFlow.totals(actual.income), RegisterCashFlow.totals(expected.income))
        XCTAssertEqual(RegisterCashFlow.totals(actual.expenses), RegisterCashFlow.totals(expected.expenses))
        XCTAssertTrue((actual.income + actual.expenses).allSatisfy { $0.transactionIDs == [row.id] })
    }

    func testFlatRegisterRowsKeepAllHeadersOrderAndStableTransactionIdentities() throws {
        var data = DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_788_858_000))
        let rows = data.transactions.sorted { $0.date > $1.date }
        let presentation = RegisterPresentation.build(data: data, rows: rows, scope: .all)
        var expected: [RegisterListItem.ID] = []
        for month in presentation.months {
            expected.append(.month(month.date))
            for day in month.days {
                expected.append(.day(day.date))
                expected.append(contentsOf: day.transactions.map { .transaction($0.id) })
            }
        }
        XCTAssertEqual(presentation.listItems.map(\.id), expected)
        XCTAssertEqual(Set(expected).count, expected.count)
        let firstID = try XCTUnwrap(rows.first?.id)
        let index = try XCTUnwrap(data.transactions.firstIndex { $0.id == firstID })
        data.transactions[index].cleared.toggle()
        let updated = RegisterPresentation.build(data: data, rows: data.transactions.sorted { $0.date > $1.date }, scope: .all)
        XCTAssertEqual(updated.listItems.map(\.id), expected, "A clear swipe must update a stable row, not recreate the register")
    }

    func testTenThousandEntryRegisterCacheBenchmark() async throws {
        var data = DemoData.fixture(referenceDate: Date(timeIntervalSince1970: 1_788_858_000))
        let prototype = data.transactions[0]
        data.transactions = (0..<10000).map { index in
            var row = prototype
            row.id = UUID(); row.date = prototype.date.addingTimeInterval(-Double(index % 730) * 86400)
            row.postings = row.postings.map { posting in var copy = posting; copy.id = UUID(); return copy }
            return row
        }.sorted { $0.date > $1.date }
        let cache = RegisterPresentationCache()
        let request = request(data)
        let cacheKey = key(request, cache: cache)
        let coldStart = ContinuousClock.now
        let cold = try await cache.load(request, key: cacheKey)
        let coldTime = coldStart.duration(to: .now)
        let warmStart = ContinuousClock.now
        for _ in 0..<25 {
            let warm = try await cache.load(request, key: cacheKey)
            XCTAssertEqual(warm.presentation.amounts.count, cold.presentation.amounts.count)
        }
        let warmTime = warmStart.duration(to: .now)
        XCTAssertEqual(cache.renderCount, 1)
        XCTAssertEqual(cache.hitCount, 25)
        print("REGISTER_CACHE_BENCHMARK rows=10000 cold=\(coldTime) cached25=\(warmTime)")
    }
}
