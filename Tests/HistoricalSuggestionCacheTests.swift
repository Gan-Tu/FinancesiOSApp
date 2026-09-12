import CryptoKit
import Foundation
import XCTest
@testable import FinancesClone

@MainActor
final class HistoricalSuggestionCacheTests: XCTestCase {
    private actor Gate {
        private var released = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func wait() async {
            if !released { await withCheckedContinuation { waiters.append($0) } }
        }
        func release() {
            released = true
            let pending = waiters; waiters.removeAll()
            for waiter in pending { waiter.resume() }
        }
    }

    private actor BuildCounter {
        private var value = 0
        func increment() -> Int { value += 1; return value }
        func count() -> Int { value }
    }

    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []

    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testConcurrentQueriesShareOneIndexBuild() async throws {
        let data = fixtureData()
        let ledger = data.ledgers[0].id
        let gate = Gate(), builds = BuildCounter()
        let started = expectation(description: "Historical index build started")
        let cache = HistoricalTextSuggestionCache { snapshot in
            _ = await builds.increment(); started.fulfill()
            await gate.wait()
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        let revision = cache.revision
        let first = Task { try await cache.suggestions(data: data, ledgerID: ledger, field: .note, query: "Al", revision: revision, limit: 5) }
        await fulfillment(of: [started], timeout: 5)
        let second = Task { try await cache.suggestions(data: data, ledgerID: ledger, field: .payee, query: "Al", revision: revision, limit: 5) }
        for _ in 0..<10 { await Task.yield() }
        await gate.release()
        let firstValues = try await first.value, secondValues = try await second.value
        XCTAssertEqual(firstValues.map(\.text), ["Alpha note"])
        XCTAssertEqual(secondValues.map(\.text), ["Alpha merchant"])
        let count = await builds.count()
        XCTAssertEqual(count, 1, "Note/payee queries should reuse the same per-journal index")
        XCTAssertTrue(cache.hasCachedIndex(for: ledger))
    }

    func testInvalidationRejectsLateBuildAndAnOldSnapshotCannotStartUnderNewRevision() async throws {
        let oldData = fixtureData()
        let ledger = oldData.ledgers[0].id
        let gate = Gate(), builds = BuildCounter()
        let started = expectation(description: "Old index is held before completion")
        let cache = HistoricalTextSuggestionCache { snapshot in
            let number = await builds.increment()
            if number == 1 { started.fulfill(); await gate.wait() }
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        let oldRevision = cache.revision
        let old = Task { try await cache.suggestions(data: oldData, ledgerID: ledger, field: .note, query: "", revision: oldRevision, limit: 5) }
        await fulfillment(of: [started], timeout: 5)
        _ = cache.invalidate(ledgerIDs: [ledger])
        var current = oldData
        current.transactions[0].note = "Replacement note"
        let fresh = try await cache.suggestions(data: current, ledgerID: ledger, field: .note, query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(fresh.map(\.text), ["Replacement note"])
        await gate.release()
        do { _ = try await old.value; XCTFail("The canceled old generation must not publish") }
        catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        do {
            _ = try await cache.suggestions(data: oldData, ledgerID: ledger, field: .note, query: "", revision: oldRevision, limit: 5)
            XCTFail("A stale captured snapshot must not build under a newer revision")
        } catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
        let count = await builds.count()
        XCTAssertEqual(count, 2)
        let retained = try await cache.suggestions(data: current, ledgerID: ledger, field: .note, query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(retained.map(\.text), ["Replacement note"])
    }

    func testFutureEligibilityExpiresWarmIndexWithoutAnyMutation() async throws {
        var data = fixtureData()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let ledger = data.ledgers[0].id
        data.transactions[0].date = now.addingTimeInterval(60)
        let builds = BuildCounter()
        let cache = HistoricalTextSuggestionCache { snapshot in
            _ = await builds.increment()
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        let revision = cache.revision
        let before = try await cache.suggestions(data: data, ledgerID: ledger, field: .note, query: "", revision: revision, limit: 5, now: now)
        XCTAssertTrue(before.isEmpty)
        XCTAssertTrue(cache.hasCachedIndex(for: ledger, now: now.addingTimeInterval(59)))
        XCTAssertFalse(cache.hasCachedIndex(for: ledger, now: now.addingTimeInterval(60)))
        let eligible = try await cache.suggestions(data: data, ledgerID: ledger, field: .note, query: "", revision: revision, limit: 5, now: now.addingTimeInterval(60))
        XCTAssertEqual(eligible.map(\.text), ["Alpha note"])
        XCTAssertEqual(cache.revision, revision, "Time eligibility is independent of source mutation")
        let count = await builds.count()
        XCTAssertEqual(count, 2)
    }

    func testCacheBoundAndPerJournalInvalidationKeepUnrelatedIndexes() async throws {
        let data = fixtureData()
        let cache = HistoricalTextSuggestionCache(maximumCachedJournals: 2)
        for ledger in data.ledgers {
            _ = try await cache.suggestions(data: data, ledgerID: ledger.id, field: .note, query: "", revision: cache.revision, limit: 5)
        }
        XCTAssertFalse(cache.hasCachedIndex(for: data.ledgers[0].id))
        XCTAssertTrue(cache.hasCachedIndex(for: data.ledgers[1].id))
        XCTAssertTrue(cache.hasCachedIndex(for: data.ledgers[2].id))
        _ = cache.invalidate(ledgerIDs: [data.ledgers[1].id])
        XCTAssertFalse(cache.hasCachedIndex(for: data.ledgers[1].id))
        XCTAssertTrue(cache.hasCachedIndex(for: data.ledgers[2].id))
        _ = cache.invalidateAll()
        XCTAssertFalse(cache.hasCachedIndex(for: data.ledgers[2].id))
    }

    func testNavigationCancelsUnobservedPrewarmChildAfterItStarts() async throws {
        let data = fixtureData()
        let firstLedger = data.ledgers[0].id, secondLedger = data.ledgers[1].id
        let gate = Gate(), cancelled = BuildCounter()
        let started = expectation(description: "First speculative child started")
        let completed = expectation(description: "First speculative child completed cancellation")
        let nextStarted = expectation(description: "Replacement journal child started")
        let cache = HistoricalTextSuggestionCache { snapshot in
            if snapshot.ledgerID == firstLedger {
                started.fulfill()
                await gate.wait()
                if Task.isCancelled { _ = await cancelled.increment() }
                completed.fulfill()
                try Task.checkCancellation()
            } else { nextStarted.fulfill() }
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        cache.prewarm(data: data, ledgerID: firstLedger)
        await fulfillment(of: [started], timeout: 5)
        cache.prewarm(data: data, ledgerID: secondLedger)
        await fulfillment(of: [nextStarted], timeout: 5)
        await gate.release()
        await fulfillment(of: [completed], timeout: 5)
        let count = await cancelled.count()
        XCTAssertEqual(count, 1, "Canceling only the outer prewarm leaves its CPU child alive")
        XCTAssertFalse(cache.hasCachedIndex(for: firstLedger))
        let next = try await cache.suggestions(data: data, ledgerID: secondLedger, field: .note,
            query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(next.map(\.text), ["Beta note"])
    }

    func testVisibleQueryPromotesPrewarmAndNavigationDoesNotCancelItsChild() async throws {
        let data = fixtureData()
        let firstLedger = data.ledgers[0].id, secondLedger = data.ledgers[1].id
        let gate = Gate(), firstBuilds = BuildCounter()
        let started = expectation(description: "First speculative child started")
        let visibleEntered = expectation(description: "Visible caller joins on the same actor")
        let nextStarted = expectation(description: "Next journal prewarm started")
        let cache = HistoricalTextSuggestionCache { snapshot in
            if snapshot.ledgerID == firstLedger {
                _ = await firstBuilds.increment()
                started.fulfill()
                await gate.wait()
                try Task.checkCancellation()
            } else { nextStarted.fulfill() }
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        cache.prewarm(data: data, ledgerID: firstLedger)
        await fulfillment(of: [started], timeout: 5)
        let revision = cache.revision
        let visible = Task {
            // No actor hop intervenes before suggestions joins the pending child.
            visibleEntered.fulfill()
            return try await cache.suggestions(data: data, ledgerID: firstLedger, field: .note,
                query: "", revision: revision, limit: 5)
        }
        await fulfillment(of: [visibleEntered], timeout: 5)
        cache.prewarm(data: data, ledgerID: secondLedger)
        await fulfillment(of: [nextStarted], timeout: 5)
        await gate.release()
        let values = try await visible.value
        XCTAssertEqual(values.map(\.text), ["Alpha note"])
        let count = await firstBuilds.count()
        XCTAssertEqual(count, 1)
        XCTAssertTrue(cache.hasCachedIndex(for: firstLedger))
    }

    func testCancelledVisiblePrefixReusesSameJournalBuildButYieldsToWarmDifferentJournal() async throws {
        for switchJournal in [false, true] {
            let data = fixtureData()
            let firstLedger = data.ledgers[0].id, secondLedger = data.ledgers[1].id
            let gate = Gate(), firstBuilds = BuildCounter()
            let started = expectation(description: "Visible journal A build started")
            let childCancelled = switchJournal ? expectation(description: "Abandoned A child was canceled when navigating to warm B") : nil
            let cache = HistoricalTextSuggestionCache { snapshot in
                if snapshot.ledgerID == firstLedger {
                    _ = await firstBuilds.increment(); started.fulfill()
                    await withTaskCancellationHandler {
                        await gate.wait()
                    } onCancel: {
                        childCancelled?.fulfill()
                    }
                    try Task.checkCancellation()
                }
                return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
            }
            // A warm destination exposes the cancellation race: no pending B
            // job exists for a delayed A cancellation callback to discover.
            _ = try await cache.suggestions(data: data, ledgerID: secondLedger, field: .note,
                query: "", revision: cache.revision, limit: 5)
            let revision = cache.revision
            let first = Task {
                try await cache.suggestions(data: data, ledgerID: firstLedger, field: .note,
                    query: "Al", revision: revision, limit: 5)
            }
            await fulfillment(of: [started], timeout: 5)
            first.cancel()
            if switchJournal {
                let values = try await cache.suggestions(data: data, ledgerID: secondLedger, field: .note,
                    query: "", revision: revision, limit: 5)
                XCTAssertEqual(values.map(\.text), ["Beta note"])
                await fulfillment(of: [try XCTUnwrap(childCancelled)], timeout: 5)
                await gate.release()
                XCTAssertFalse(cache.hasCachedIndex(for: firstLedger))
            } else {
                let joined = expectation(description: "Next prefix joins the same journal build")
                let next = Task {
                    joined.fulfill()
                    return try await cache.suggestions(data: data, ledgerID: firstLedger, field: .note,
                        query: "Alp", revision: revision, limit: 5)
                }
                await fulfillment(of: [joined], timeout: 5)
                await gate.release()
                let values = try await next.value
                XCTAssertEqual(values.map(\.text), ["Alpha note"])
            }
            do { _ = try await first.value; XCTFail("The canceled old prefix must not return suggestions") }
            catch is CancellationError {} catch { XCTFail("Unexpected error: \(error)") }
            let count = await firstBuilds.count()
            XCTAssertEqual(count, 1, "Changing a prefix must not restart an otherwise reusable index build")
        }
    }

    func testDefaultColdIndexAllowsMainActorHeartbeatDuringLargeBuild() async throws {
        var data = fixtureData()
        let original = data.transactions[0]
        data.transactions = (0..<50_000).map { index in
            var row = original
            row.id = UUID(); row.note = "Synthetic history \(index)"; row.payee = "Synthetic merchant \(index % 123)"
            return row
        }
        let cache = HistoricalTextSuggestionCache()
        let snapshot = data, revision = cache.revision
        var finished = false
        let work = Task {
            defer { finished = true }
            return try await cache.suggestions(data: snapshot, ledgerID: original.ledgerID, field: .note,
                query: "Synthetic", revision: revision, limit: 5)
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(20))
        while cache.buildCount == 0, !finished, ContinuousClock.now < deadline { await Task.yield() }
        var heartbeatCount = 0
        while !finished, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(1))
            if !finished { heartbeatCount += 1 }
        }
        if !finished { work.cancel(); XCTFail("Synthetic indexing did not finish within the test safety deadline") }
        let values = try await work.value
        XCTAssertEqual(values.count, 5)
        XCTAssertGreaterThan(heartbeatCount, 0, "The main actor must keep handling events while the actual default index builds")
    }

    func testCacheBuilderRunsActualIndexConstructionOffMainThread() async throws {
        let data = fixtureData()
        let cache = HistoricalTextSuggestionCache { snapshot in
            // No suspension between the executor check and actual CPU work.
            // This deterministically verifies the cache's builder dispatch,
            // independently of hardware speed or event-loop timing thresholds.
            XCTAssertFalse(Thread.isMainThread)
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        let values = try await cache.suggestions(data: data, ledgerID: data.ledgers[0].id,
            field: .note, query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(values.map(\.text), ["Alpha note"])
    }

    func testMemoryPressureClearsWarmIndexesWithoutStrandingVisibleWaiterOrRefillingOldBuild() async throws {
        var data = fixtureData()
        let original = data.transactions.removeFirst()
        let firstLedger = original.ledgerID
        data.transactions.insert(contentsOf: (0..<8).map { index in
            var row = original
            row.id = UUID(); row.note = "Memory \(index)"
            return row
        }, at: 0)
        let snapshot = data
        let gate = Gate()
        let started = expectation(description: "Visible historical build is in progress")
        let cache = HistoricalTextSuggestionCache { snapshot in
            if snapshot.ledgerID == firstLedger {
                started.fulfill()
                await gate.wait()
                try Task.checkCancellation()
            }
            return HistoricalTextSuggestionIndex(transactions: snapshot.data.transactions, asOf: snapshot.asOf)
        }
        let revision = cache.revision
        _ = try await cache.suggestions(data: snapshot, ledgerID: snapshot.ledgers[1].id,
            field: .note, query: "", revision: revision, limit: 5)
        XCTAssertEqual(cache.cachedJournalCount, 1)
        let visible = Task {
            try await cache.suggestions(data: snapshot, ledgerID: firstLedger,
                field: .note, query: "", revision: revision, limit: 5)
        }
        await fulfillment(of: [started], timeout: 5)
        cache.purgeForMemoryPressure()
        XCTAssertEqual(cache.cachedJournalCount, 0)
        XCTAssertEqual(cache.revision, revision, "Memory pressure must not trigger a source-revision rebuild loop")
        await gate.release()
        let values = try await visible.value
        XCTAssertEqual(values.map(\.text), ["Memory 0", "Memory 1", "Memory 2", "Memory 3", "Memory 4"])
        XCTAssertEqual(cache.cachedJournalCount, 0, "A pre-warning build can satisfy the user without refilling purged memory")
        XCTAssertFalse(cache.hasCachedIndex(for: firstLedger))
    }

    func testStoreCRUDAndDatesRefreshValuesButUnrelatedMetadataKeepsCache() async throws {
        let f = try fixture()
        let store = f.store, ledger = f.data.ledgers[0].id
        let row = f.data.transactions[0]
        assertTexts(try await texts(store, ledger, .note), ["Alpha note"])
        _ = try await texts(store, f.data.ledgers[1].id, .note)
        let unchangedRevision = store.historicalTextSuggestions.revision
        store.setTransactionCleared(row.id, cleared: !row.cleared)
        var account = store.draft(for: f.data.accounts[0]); account.name = "Renamed account"
        _ = store.saveAccount(account)
        var currency = store.draft(for: f.data.commodities[0]); currency.name = "Renamed dollar"
        _ = store.saveCurrency(currency)
        var template = store.templateDraft(for: nil); template.ledgerID = ledger; template.name = "Template only"
        template.postings = [PostingTemplateDraft(accountID: f.data.accounts[0].id), PostingTemplateDraft(accountID: f.data.accounts[1].id)]
        _ = store.saveTransactionTemplate(template)
        store.renameJournal(ledger, name: "Renamed journal")
        XCTAssertEqual(store.historicalTextSuggestions.revision, unchangedRevision)
        XCTAssertTrue(store.historicalTextSuggestions.hasCachedIndex(for: ledger))

        var edited = store.draft(for: try XCTUnwrap(store.transaction(row.id)))
        edited.note = "Renamed note"; edited.payee = "Renamed merchant"
        let saved = await store.saveTransactionAndFlushAsync(edited)
        XCTAssertTrue(saved)
        assertTexts(try await texts(store, ledger, .note), ["Renamed note"])
        assertTexts(try await texts(store, ledger, .payee), ["Renamed merchant"])
        XCTAssertTrue(store.historicalTextSuggestions.hasCachedIndex(for: f.data.ledgers[1].id))

        let reference = Date()
        edited.date = reference.addingTimeInterval(3_600)
        let rescheduled = await store.saveTransactionAndFlushAsync(edited)
        XCTAssertTrue(rescheduled)
        assertTexts(try await texts(store, ledger, .note, now: reference), [])
        edited.date = reference.addingTimeInterval(-60)
        let movedBack = await store.saveTransactionAndFlushAsync(edited)
        XCTAssertTrue(movedBack)
        assertTexts(try await texts(store, ledger, .note), ["Renamed note"])

        var created = store.makeTransactionDraft(ledgerID: ledger)
        created.note = "Created note"; created.payee = "Created merchant"; created.date = reference.addingTimeInterval(-30)
        created.postings = [PostingDraft(accountID: f.data.accounts[0].id, amount: "-4", commodityID: f.data.commodities[0].id),
                            PostingDraft(accountID: f.data.accounts[1].id, amount: "4", commodityID: f.data.commodities[0].id)]
        let inserted = await store.saveTransactionAndFlushAsync(created)
        XCTAssertTrue(inserted)
        assertTextSet(Set(try await texts(store, ledger, .note)), ["Created note", "Renamed note"])
        let deleted = await store.deleteTransactionAsync(created.saveOperationID)
        XCTAssertTrue(deleted)
        assertTexts(try await texts(store, ledger, .note), ["Renamed note"])
        store.deleteJournal(ledger)
        XCTAssertFalse(store.historicalTextSuggestions.hasCachedIndex(for: ledger))
    }

    func testCloudPullConflictChoiceAndCrossJournalMoveInvalidateExactHistoricalSources() async throws {
        let f = try fixture()
        let store = f.store, ledger = f.data.ledgers[0].id, destination = f.data.ledgers[1].id
        let context = "synthetic-historical-suggestions"
        _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "Synthetic")
        _ = try await texts(store, ledger, .note)
        _ = try await texts(store, destination, .note)
        var remoteRow = f.data.transactions[0]
        remoteRow.note = "Remote note"; remoteRow.payee = "Remote merchant"
        var candidate = store.data; candidate.transactions[0] = remoteRow
        try store.cloudKitCommitRemote([record(remoteRow)], data: candidate, contextKey: context, changeToken: Data([1]))
        assertTexts(try await texts(store, ledger, .note), ["Remote note"])

        var local = store.draft(for: remoteRow); local.note = "Local conflicting note"
        let saved = await store.saveTransactionAndFlushAsync(local)
        XCTAssertTrue(saved)
        _ = try await texts(store, ledger, .note)
        let pending = try XCTUnwrap(store.cloudKitSQLiteStore.pendingCloudKitRecords(contextKey: context)["transaction:" + remoteRow.id.uuidString])
        remoteRow.note = "Chosen remote note"
        let remote = try record(remoteRow)
        try store.cloudKitSQLiteStore.saveCloudKitConflict(local: pending, remote: remote, contextKey: context)
        let conflict = try XCTUnwrap(store.cloudKitSQLiteStore.unresolvedCloudKitConflicts(contextKey: context).first)
        candidate = store.data; candidate.transactions[0] = remoteRow
        try store.cloudKitCommitConflictResolution(id: conflict.id, keepLocal: false, data: candidate, contextKey: context)
        assertTexts(try await texts(store, ledger, .note), ["Chosen remote note"])

        remoteRow.ledgerID = destination
        remoteRow.postings[0].accountID = f.data.accounts[2].id
        remoteRow.postings[1].accountID = f.data.accounts[3].id
        for index in remoteRow.postings.indices { remoteRow.postings[index].commodityID = f.data.commodities[1].id }
        candidate = store.data; candidate.transactions[0] = remoteRow
        try store.cloudKitCommitRemote([record(remoteRow)], data: candidate, contextKey: context, changeToken: Data([2]))
        assertTexts(try await texts(store, ledger, .note), [])
        assertTextSet(Set(try await texts(store, destination, .note)), ["Chosen remote note", "Beta note"])
        candidate = store.data; candidate.transactions.removeAll { $0.id == remoteRow.id }
        let deleted = CloudKitSyncRecord(recordType: "transaction", recordID: remoteRow.id.uuidString,
            operation: "delete", parentRecordID: destination.uuidString)
        try store.cloudKitCommitRemote([deleted], data: candidate, contextKey: context, changeToken: Data([3]))
        assertTexts(try await texts(store, destination, .note), ["Beta note"])
    }

    func testFutureScopeEditRefreshesHistoricalSuggestionFrequenciesForEveryAffectedOccurrence() async throws {
        var data = fixtureData()
        let anchor = data.transactions.removeFirst()
        let rule = RecurrenceRule(frequency: .daily, occurrenceCount: 3)
        let series = (0..<3).map { index in
            var row = anchor
            if index > 0 { row.id = UUID(); row.postings = row.postings.map { var posting = $0; posting.id = UUID(); return posting } }
            row.date = anchor.date.addingTimeInterval(Double(index) * 86_400)
            row.recurrenceRule = rule
            return row
        }
        data.transactions.insert(contentsOf: series, at: 0)
        let f = try fixture(data: data)
        let cache = f.store.historicalTextSuggestions
        let before = try await cache.suggestions(data: f.store.data, ledgerID: anchor.ledgerID, field: .note,
            query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(before.map(\.text), ["Alpha note"])
        XCTAssertEqual(before.first?.frequency, 3)
        var draft = f.store.draft(for: series[1]); draft.note = "Changed future terms"
        let saved = await f.store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(saved)
        let after = try await cache.suggestions(data: f.store.data, ledgerID: anchor.ledgerID, field: .note,
            query: "", revision: cache.revision, limit: 5)
        XCTAssertEqual(after.map(\.text), ["Changed future terms", "Alpha note"])
        XCTAssertEqual(after.map(\.frequency), [2, 1])
    }

    func testBackupRestoreReplacesTextAndEvictsRemovedJournalHistory() async throws {
        let f = try fixture()
        let ledger = f.data.ledgers[0].id
        _ = try await texts(f.store, ledger, .note)
        _ = try await texts(f.store, f.data.ledgers[1].id, .note)
        var replacement = f.data
        replacement.ledgers = Array(replacement.ledgers.prefix(1))
        replacement.accounts = Array(replacement.accounts.prefix(2))
        replacement.commodities = Array(replacement.commodities.prefix(1))
        replacement.transactions = Array(replacement.transactions.prefix(1))
        replacement.transactions[0].note = "Restored note"
        replacement.transactions[0].payee = "Restored merchant"
        let backup = f.directory.appendingPathComponent("synthetic-history-restore.json")
        try JSONEncoder.appEncoder.encode(replacement).write(to: backup)
        try await f.store.importBackupAsync(from: backup, progress: Progress(totalUnitCount: 1))
        assertTexts(try await texts(f.store, ledger, .note), ["Restored note"])
        assertTexts(try await texts(f.store, ledger, .payee), ["Restored merchant"])
        XCTAssertFalse(f.store.historicalTextSuggestions.hasCachedIndex(for: f.data.ledgers[1].id))
    }

    private func assertTexts(_ actual: [String], _ expected: [String], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func assertTextSet(_ actual: Set<String>, _ expected: Set<String>, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(actual, expected, file: file, line: line)
    }

    private func texts(_ store: MobileLedgerStore, _ ledger: UUID, _ field: HistoricalTextSuggestionField,
                       now: Date = Date()) async throws -> [String] {
        try await store.historicalTextSuggestions.suggestions(data: store.data, ledgerID: ledger, field: field,
            query: "", revision: store.historicalTextSuggestions.revision, limit: 20, now: now).map(\.text)
    }

    private func fixtureData() -> JournalData {
        var data = JournalData()
        for (index, word) in ["Alpha", "Beta", "Gamma"].enumerated() {
            let ledger = Ledger(name: "Synthetic \(word) journal", listIndex: index)
            let currency = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
            let bank = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Synthetic bank", kind: .asset)
            let expense = Account(ledgerID: ledger.id, commodityID: currency.id, name: "Synthetic expense", kind: .expense)
            let row = LedgerTransaction(ledgerID: ledger.id, date: Date(timeIntervalSince1970: 1_700_000_000 + Double(index)),
                payee: word + " merchant", note: word + " note", number: "SYN", cleared: true,
                postings: [Posting(accountID: bank.id, commodityID: currency.id, amount: -4),
                           Posting(accountID: expense.id, commodityID: currency.id, amount: 4, listIndex: 1)])
            data.ledgers.append(ledger); data.commodities.append(currency)
            data.accounts.append(contentsOf: [bank, expense]); data.transactions.append(row)
        }
        data.selectedLedgerID = data.ledgers.first?.id
        return data
    }

    private func fixture(data suppliedData: JournalData? = nil) throws -> (store: MobileLedgerStore, data: JournalData, directory: URL) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("HistoricalSuggestions-\(UUID().uuidString)")
        directories.append(directory)
        let data = suppliedData ?? fixtureData()
        let dependencies = CloudKitSyncDependencies(configuration: { nil }, makeClient: { _ in
            throw ValidationError(message: "Synthetic history tests cannot contact iCloud.")
        }, automaticTriggersEnabled: false)
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        XCTAssertFalse(store.requiresJournalRecovery)
        return (store, data, directory)
    }

    private func record(_ transaction: LedgerTransaction) throws -> CloudKitSyncRecord {
        let data = try JSONEncoder.appEncoder.encode(transaction)
        return CloudKitSyncRecord(recordType: "transaction", recordID: transaction.id.uuidString,
            parentRecordID: transaction.ledgerID.uuidString,
            contentHash: SHA256.hash(data: data).map { String(format: "%02x", Int($0)) }.joined(),
            payloadJSON: String(decoding: data, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data([1]))
    }
}
