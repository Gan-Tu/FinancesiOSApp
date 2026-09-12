import Foundation
import SQLite3
import XCTest
@testable import FinancesClone

/// Synthetic split amounts only. Fake CloudKit acknowledgements exercise the
/// actual offline outbox without contacting an account, journal, or server.
@MainActor
final class SplitTransactionPersistenceTests: XCTestCase {
    private var stores: [MobileLedgerStore] = []
    private var directories: [URL] = []
    private var acknowledgement: UInt8 = 0

    override func tearDown() async throws {
        for store in stores { await store.waitForCloudKitSyncIdle() }
        stores.removeAll()
        await MobileLedgerStore.drainPersistenceQueueForTesting()
        for directory in directories { try FileManager.default.removeItem(at: directory) }
        directories.removeAll()
        try await super.tearDown()
    }

    func testExistingThreeLegSplitSurvivesUnchangedEquivalentAndNoteOnlySaves() async throws {
        let f = fixture(amounts: [-140, 125, 15], nilCurrencyIndices: [2])
        let original = f.initial[0]
        var draft = f.store.draft(for: original)
        let unchanged = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(unchanged)
        try await verify(f, expected: [original.id: original.postings], queuedIDs: [])
        for text in ["125", "125.000", "100 + 25"] {
            draft = PostingBalance.settingAmount(text, at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
            assertDraft(draft, matches: original.postings)
            let saved = await f.store.saveTransactionAndFlushAsync(draft)
            XCTAssertTrue(saved)
            try await verify(f, expected: [original.id: original.postings], queuedIDs: [])
        }
        draft.note = "Notes edited without reallocating the fee"
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        try await verify(f, expected: [original.id: original.postings], queuedIDs: [original.id], notes: [original.id: draft.note])
        let reopened = reopen(f.directory)
        await reopened.waitForCloudKitSyncIdle()
        XCTAssertEqual(reopened.transaction(original.id)?.postings, original.postings)
    }

    func testFourLegSplitWithRepeatedAccountKeepsUnequalAllocations() async throws {
        let f = fixture(amounts: [-400, 225, 150, 25])
        let original = f.initial[0]
        XCTAssertEqual(original.postings[1].accountID, original.postings[3].accountID)
        var draft = f.store.draft(for: original)
        draft = PostingBalance.settingAmount("230", at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        XCTAssertEqual(draft.postings[0].amount, "-400.00")
        XCTAssertEqual(decimalFromInput(draft.postings[2].amount), 150)
        XCTAssertEqual(decimalFromInput(draft.postings[3].amount), 25)
        draft = PostingBalance.settingAmount("-405", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        var expected = original.postings
        expected[0].amount = -405; expected[1].amount = 230
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        try await verify(f, expected: [original.id: expected], queuedIDs: [original.id])
    }

    func testSixLegMulticurrencySplitPreservesOtherCurrencyAndLiteralNilCurrency() async throws {
        let f = fixture(amounts: [-140, 125, 15, -90, 80, 10], euroIndices: [3, 4, 5], nilCurrencyIndices: [2])
        let original = f.initial[0]
        var draft = f.store.draft(for: original)
        draft = PostingBalance.settingAmount("130", at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        draft = PostingBalance.settingAmount("-145", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        var expected = original.postings
        expected[0].amount = -145; expected[1].amount = 130
        assertDraft(draft, matches: expected)
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        try await verify(f, expected: [original.id: expected], queuedIDs: [original.id])
        XCTAssertEqual(Array(f.store.transaction(original.id)!.postings[3...5]), Array(original.postings[3...5]))
    }

    func testDuplicateKeepsEveryAllocationWithIndependentPostingIdentities() async throws {
        let f = fixture(amounts: [-400, 225, 150, 25], nilCurrencyIndices: [3])
        let original = f.initial[0]
        var draft = try XCTUnwrap(f.store.duplicateTransactionDraft(original.id, useToday: true, now: original.date.addingTimeInterval(3_600)))
        draft.note = "Synthetic duplicated split"
        let expectedDuplicate = zip(draft.postings, original.postings).enumerated().map { index, pair in
            Posting(id: pair.0.id, accountID: pair.1.accountID, commodityID: pair.1.commodityID, amount: pair.1.amount, listIndex: index)
        }
        XCTAssertTrue(Set(expectedDuplicate.map(\.id)).isDisjoint(with: original.postings.map(\.id)))
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        let duplicate = try XCTUnwrap(f.store.transaction(draft.saveOperationID))
        try await verify(f, expected: [original.id: original.postings, duplicate.id: expectedDuplicate], queuedIDs: [duplicate.id], notes: [duplicate.id: draft.note])
        XCTAssertEqual(duplicate.date, draft.date)
        XCTAssertNil(duplicate.recurrenceRule)
    }

    func testAddingFeeToTwoLegDraftDoesNotChangeOtherAmountsBeforeExplicitAdjustment() async throws {
        let f = fixture(amounts: [-125, 125])
        let original = f.initial[0]
        var draft = f.store.draft(for: original)
        let fee = PostingDraft(accountID: f.accounts[2].id, amount: "15", commodityID: nil, preservesNilCommodityID: true)
        draft.postings.append(fee)
        draft = PostingBalance.settingAmount("15.00", at: 2, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        XCTAssertEqual(draft.postings[0].amount, "-125.00")
        XCTAssertEqual(draft.postings[1].amount, "125.00")
        let unbalanced = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(unbalanced)
        try await verify(f, expected: [original.id: original.postings], queuedIDs: [], expectsValidationError: true)
        draft = PostingBalance.settingAmount("-140", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        var expected = original.postings; expected[0].amount = -140
        expected.append(Posting(id: fee.id, accountID: f.accounts[2].id, commodityID: nil, amount: 15, listIndex: 2))
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        try await verify(f, expected: [original.id: expected], queuedIDs: [original.id])
    }

    func testRemovingFeeAndEquivalentWritebackCannotSilentlyRebalanceRemainingTwoLegs() async throws {
        for text in ["90", "90.00", "45 * 2"] {
            let f = fixture(amounts: [-100, 90, 10])
            let original = f.initial[0]
            var draft = f.store.draft(for: original)
            draft.postings.removeLast()
            let before = draft.postings
            draft = PostingBalance.settingAmount(text, at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
            XCTAssertEqual(draft.postings[0], before[0], "An equivalent writeback must not silently change the untouched -100 leg")
            XCTAssertEqual(decimalFromInput(draft.postings[1].amount), 90)
            let silentlyAccepted = await f.store.saveTransactionAndFlushAsync(draft)
            XCTAssertFalse(silentlyAccepted, "The partial [-100,90] draft must remain unbalanced until the user changes a value")
            try await verify(f, expected: [original.id: original.postings], queuedIDs: [], expectsValidationError: true)
            draft = PostingBalance.settingAmount("-90", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
            var expected = Array(original.postings.prefix(2)); expected[0].amount = -90
            let explicitSave = await f.store.saveTransactionAndFlushAsync(draft)
            XCTAssertTrue(explicitSave)
            try await verify(f, expected: [original.id: expected], queuedIDs: [original.id])
        }
    }

    func testRemovingMiddleRepeatedAccountLegPreservesRemainingSplitIdentities() async throws {
        let f = fixture(amounts: [-400, 225, 150, 25])
        let original = f.initial[0]
        var draft = f.store.draft(for: original)
        draft.postings.remove(at: 1)
        let before = draft.postings
        draft = PostingBalance.settingAmount("150.00", at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        XCTAssertEqual(draft.postings[0], before[0])
        XCTAssertEqual(draft.postings[2], before[2])
        let rejected = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertFalse(rejected)
        try await verify(f, expected: [original.id: original.postings], queuedIDs: [], expectsValidationError: true)
        draft = PostingBalance.settingAmount("-175", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        var expected = [original.postings[0], original.postings[2], original.postings[3]]
        expected[0].amount = -175
        for index in expected.indices { expected[index].listIndex = index }
        let saved = await f.store.saveTransactionAndFlushAsync(draft)
        XCTAssertTrue(saved)
        try await verify(f, expected: [original.id: expected], queuedIDs: [original.id])
    }

    func testRecurringOccurrenceAndFutureSavesPreserveEverySplitTupleAndQueuedPayload() async throws {
        let f = fixture(amounts: [-140, 125, 15], nilCurrencyIndices: [2], recurring: true)
        let rows = f.initial
        let selected = rows[1]
        var expected = Dictionary(uniqueKeysWithValues: rows.map { ($0.id, $0.postings) })
        var draft = f.store.draft(for: selected)
        draft.note = "Occurrence-only split note"
        let occurrenceSaved = await f.store.saveTransactionAndFlushAsync(draft, scope: .occurrence)
        XCTAssertTrue(occurrenceSaved)
        try await verify(f, expected: expected, queuedIDs: [selected.id], notes: [selected.id: draft.note])
        draft = f.store.draft(for: f.store.transaction(selected.id))
        draft.note = "Future unequal split terms"
        draft = PostingBalance.settingAmount("130", at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        draft = PostingBalance.settingAmount("-145", at: 0, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        for row in rows where row.date >= selected.date {
            var postings = row.postings; postings[0].amount = -145; postings[1].amount = 130
            expected[row.id] = postings
        }
        let futureSaved = await f.store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(futureSaved)
        try await verify(f, expected: expected, queuedIDs: Set(rows.map(\.id)))
        draft = f.store.draft(for: f.store.transaction(selected.id))
        draft = PostingBalance.settingAmount("65 * 2", at: 1, in: draft, accounts: f.store.data.accounts, commodities: f.store.data.commodities)
        let equivalentSaved = await f.store.saveTransactionAndFlushAsync(draft, scope: .future)
        XCTAssertTrue(equivalentSaved)
        try await verify(f, expected: expected, queuedIDs: [])
    }

    private struct Fixture {
        let store: MobileLedgerStore
        let initial: [LedgerTransaction]
        let accounts: [Account]
        let directory: URL
        let context: String
    }

    private func fixture(amounts: [Decimal], euroIndices: Set<Int> = [], nilCurrencyIndices: Set<Int> = [], recurring: Bool = false) -> Fixture {
        let ledger = Ledger(name: "Synthetic split tests")
        let usd = Commodity(ledgerID: ledger.id, symbol: "USD", name: "Dollar")
        let eur = Commodity(ledgerID: ledger.id, symbol: "EUR", name: "Euro")
        let accounts = [Account(ledgerID: ledger.id, commodityID: usd.id, name: "Bank", kind: .asset),
                        Account(ledgerID: ledger.id, commodityID: usd.id, name: "Category A", kind: .expense),
                        Account(ledgerID: ledger.id, commodityID: usd.id, name: "Category B or fee", kind: .expense)]
        let postings = amounts.enumerated().map { index, amount in
            Posting(accountID: accounts[index % 3].id, commodityID: nilCurrencyIndices.contains(index) ? nil : (euroIndices.contains(index) ? eur.id : usd.id), amount: amount, listIndex: index)
        }
        // The fourth leg deliberately reuses Category A rather than the bank.
        var prepared = postings
        if amounts.count == 4 { prepared[3].accountID = accounts[1].id }
        let date = Date(timeIntervalSince1970: 1_789_041_600)
        var original = LedgerTransaction(ledgerID: ledger.id, date: date, payee: "Synthetic Merchant", note: "Initial unequal split", number: "SPLIT", cleared: true, postings: prepared)
        var rows = [original]
        if recurring {
            var calendar = Calendar(identifier: .gregorian); calendar.timeZone = TimeZone(secondsFromGMT: 0)!
            let rule = RecurrenceRule(frequency: .monthly, occurrenceCount: 3, templateHistory: RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: original), scheduleAnchorDate: date), preservesImportedMaterializations: false,
                continuation: RecurrenceContinuation(anchorDate: date, calendar: calendar, nextOccurrenceIndex: 3, consumedOccurrences: 3,
                    lastScheduledDay: calendar.startOfDay(for: calendar.date(byAdding: .month, value: 2, to: date)!)))
            original.recurrenceRule = rule
            rows = (0..<3).map { index in
                var row = original
                if index > 0 { row.id = UUID(); row.postings = row.postings.map { var p = $0; p.id = UUID(); return p } }
                row.date = calendar.date(byAdding: .month, value: index, to: date)!
                return row
            }
        }
        let directory = FileManager.default.temporaryDirectory.appending(path: "SplitPersistenceTests-\(UUID())")
        directories.append(directory)
        var dependencies = CloudKitSyncDependencies.live; dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory,
            initialData: JournalData(ledgers: [ledger], commodities: [usd, eur], accounts: accounts, transactions: rows, selectedLedgerID: ledger.id), cloudKitSyncDependencies: dependencies)
        stores.append(store)
        XCTAssertFalse(store.requiresJournalRecovery)
        let context = "synthetic-split-tests"
        do { _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "Synthetic") }
        catch { XCTFail("Could not bind synthetic test context: \(error)") }
        return Fixture(store: store, initial: rows, accounts: accounts, directory: directory, context: context)
    }

    private func reopen(_ directory: URL) -> MobileLedgerStore {
        var dependencies = CloudKitSyncDependencies.live; dependencies.automaticTriggersEnabled = false
        let store = MobileLedgerStore(supportDirectory: directory, cloudKitSyncDependencies: dependencies)
        stores.append(store)
        return store
    }

    private func assertDraft(_ draft: TransactionDraft, matches expected: [Posting], file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertEqual(draft.postings.count, expected.count, file: file, line: line)
        for (actual, expected) in zip(draft.postings, expected) {
            XCTAssertEqual(actual.id, expected.id, file: file, line: line)
            XCTAssertEqual(actual.accountID, expected.accountID, file: file, line: line)
            XCTAssertEqual(actual.commodityID, expected.commodityID, file: file, line: line)
            XCTAssertEqual(decimalFromInput(actual.amount), expected.amount, file: file, line: line)
        }
    }

    private func verify(_ f: Fixture, expected: [UUID: [Posting]], queuedIDs: Set<UUID>, notes: [UUID: String] = [:], expectsValidationError: Bool = false) async throws {
        await f.store.waitForCloudKitSyncIdle()
        if expectsValidationError { XCTAssertNotNil(f.store.validationError) }
        else { XCTAssertNil(f.store.validationError) }
        let disk = try XCTUnwrap(f.store.cloudKitSQLiteStore.loadData())
        let fallback = try XCTUnwrap(f.store.cloudKitSQLiteStore.loadData(maximumReadBufferBytes: 0))
        for (id, postings) in expected {
            XCTAssertEqual(f.store.transaction(id)?.postings, postings)
            XCTAssertEqual(disk.transactions.first { $0.id == id }?.postings, postings)
            XCTAssertEqual(fallback.transactions.first { $0.id == id }?.postings, postings)
            XCTAssertEqual(try rawPostings(id, at: f.store.cloudKitSQLiteStore.databaseURL), postings)
            let payload = try rawTransaction(id, at: f.store.cloudKitSQLiteStore.databaseURL)
            XCTAssertEqual(payload.postings, postings)
            if let note = notes[id] { XCTAssertEqual(payload.note, note) }
        }
        let claims = try f.store.cloudKitSQLiteStore.claimCloudKitChanges(contextKey: f.context, limit: 1_000)
        XCTAssertEqual(Set(claims.filter { $0.recordType == "transaction" }.compactMap { UUID(uuidString: $0.recordID) }), queuedIDs)
        XCTAssertTrue(claims.allSatisfy { $0.recordType == "transaction" && $0.operation == "upsert" })
        for claim in claims {
            let value = try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: XCTUnwrap(claim.payloadJSON?.data(using: .utf8)))
            XCTAssertEqual(value.postings, try XCTUnwrap(expected[value.id]))
            if let note = notes[value.id] { XCTAssertEqual(value.note, note) }
        }
        if !claims.isEmpty {
            acknowledgement &+= 1
            let accepted = claims.map { claim in var copy = claim; copy.systemFields = Data([acknowledgement]); return copy }
            try f.store.cloudKitSQLiteStore.acknowledgeCloudKitRecords(accepted, submitted: claims, contextKey: f.context)
        }
    }

    private func rawPostings(_ id: UUID, at url: URL) throws -> [Posting] {
        try query("SELECT id, account_id, commodity_id, amount, list_index FROM postings WHERE transaction_id = ? ORDER BY list_index", id: id, at: url) { row in
            let currency = text(row, 2).flatMap(UUID.init(uuidString:))
            return Posting(id: try XCTUnwrap(text(row, 0).flatMap(UUID.init(uuidString:))), accountID: try XCTUnwrap(text(row, 1).flatMap(UUID.init(uuidString:))),
                           commodityID: currency, amount: try XCTUnwrap(text(row, 3).flatMap { Decimal(string: $0) }), listIndex: Int(sqlite3_column_int64(row, 4)))
        }
    }

    private func rawTransaction(_ id: UUID, at url: URL) throws -> LedgerTransaction {
        try XCTUnwrap(query("SELECT payload_json FROM transactions WHERE id = ?", id: id, at: url) { row in
            try JSONDecoder.appDecoder.decode(LedgerTransaction.self, from: XCTUnwrap(text(row, 0)?.data(using: .utf8)))
        }.first)
    }

    private func query<T>(_ sql: String, id: UUID, at url: URL, map: (OpaquePointer) throws -> T) throws -> [T] {
        var database: OpaquePointer?, statement: OpaquePointer?
        guard sqlite3_open_v2(url.path, &database, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK, let database else { throw SQLiteJournalStoreError.openFailed("Synthetic split test") }
        defer { sqlite3_finalize(statement); sqlite3_close(database) }
        sqlite3_busy_timeout(database, 8_000)
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK, let statement else { throw SQLiteJournalStoreError.prepareFailed("Synthetic split test") }
        let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement, 1, id.uuidString, -1, transient) == SQLITE_OK else { throw SQLiteJournalStoreError.bindFailed("Synthetic split test") }
        var result: [T] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE { return result }
            guard status == SQLITE_ROW else { throw SQLiteJournalStoreError.stepFailed(String(cString: sqlite3_errmsg(database))) }
            result.append(try map(statement))
        }
    }

    private func text(_ row: OpaquePointer, _ index: Int32) -> String? {
        sqlite3_column_text(row, index).map { String(cString: $0) }
    }
}
