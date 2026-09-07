import XCTest
import SQLite3
import CryptoKit
@testable import FinancesClone

@MainActor
final class MobileCompanionTests: XCTestCase {
    func testTemplateDraftCannotOutliveItsDeletedJournal() throws {
        for editing in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
            var draft = store.templateDraft(for: nil)
            draft.name = "Stale template"
            draft.postings = []
            let owner = try XCTUnwrap(draft.ledgerID)
            if editing {
                store.saveTransactionTemplate(draft)
                XCTAssertNil(store.validationError)
                draft = store.templateDraft(for: try XCTUnwrap(store.data.transactionTemplates.first { $0.name == draft.name }))
            }
            store.deleteJournal(owner)
            try store.flushLocalChanges()
            let before = store.data.transactionTemplates
            store.saveTransactionTemplate(draft)
            XCTAssertNotNil(store.validationError)
            XCTAssertEqual(store.data.transactionTemplates, before)
            try store.flushLocalChanges()
            let reopened = MobileLedgerStore(supportDirectory: folder)
            XCTAssertFalse(reopened.requiresJournalRecovery)
            XCTAssertFalse(reopened.data.ledgers.contains { $0.id == owner })
            XCTAssertEqual(reopened.data.transactionTemplates, before)
        }
    }

    func testDeletedEditorsCannotRecreateAccountsCurrenciesOrTemplates() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let cash = try XCTUnwrap(store.data.accounts.first { $0.name == "Cash" })
        let accountDraft = store.draft(for: cash)
        store.deleteAccount(cash.id)
        XCTAssertNil(store.validationError)
        let accounts = store.data.accounts
        store.saveAccount(accountDraft)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.accounts, accounts)

        let eur = try XCTUnwrap(store.data.commodities.first { $0.symbol == "EUR" })
        let currencyDraft = store.draft(for: eur)
        store.deleteCurrency(eur.id)
        XCTAssertNil(store.validationError)
        let currencies = store.data.commodities
        store.saveCurrency(currencyDraft)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.commodities, currencies)

        var templateDraft = store.templateDraft(for: nil)
        templateDraft.name = "Deleted template"
        store.saveTransactionTemplate(templateDraft)
        XCTAssertNil(store.validationError)
        let template = try XCTUnwrap(store.data.transactionTemplates.first { $0.name == templateDraft.name })
        templateDraft = store.templateDraft(for: template)
        store.deleteTransactionTemplate(template.id)
        let templates = store.data.transactionTemplates
        store.saveTransactionTemplate(templateDraft)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.transactionTemplates, templates)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder)
        XCTAssertFalse(reopened.requiresJournalRecovery)
        XCTAssertEqual(reopened.data.accounts.sorted { $0.id.uuidString < $1.id.uuidString }, accounts.sorted { $0.id.uuidString < $1.id.uuidString })
        XCTAssertEqual(reopened.data.commodities, currencies)
        XCTAssertEqual(reopened.data.transactionTemplates, templates)
    }

    func testBackupRestoreDoesNotRegenerateDeletedRepeatingOccurrences() throws {
        for deletedIndex in [0, 1] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let source = MobileLedgerStore(supportDirectory: folder.appendingPathComponent("source"), initialData: DemoData.fixture())
            var draft = source.makeTransactionDraft()
            draft.note = "Backup repeating series"
            draft.postings[0].amount = "-10"; draft.postings[1].amount = "10"
            draft.repeatFrequency = .monthly; draft.repeatOccurrenceCount = 3
            source.saveTransaction(draft)
            XCTAssertNil(source.validationError)
            let series = source.data.transactions.filter { $0.note == draft.note }.sorted { $0.date < $1.date }
            XCTAssertEqual(series.count, 3)
            let ruleID = try XCTUnwrap(series.first?.recurrenceRule?.id)
            source.deleteTransaction(series[deletedIndex].id, scope: .occurrence)
            XCTAssertNil(source.validationError)
            let expected = Set(series.enumerated().filter { $0.offset != deletedIndex }.map { $0.element.id })
            let backup = try source.exportBackupFile()
            let receiverFolder = folder.appendingPathComponent("receiver")
            let receiver = MobileLedgerStore(supportDirectory: receiverFolder, initialData: DemoData.fixture())
            receiver.importBackup(from: backup)
            XCTAssertNil(receiver.validationError)
            try receiver.flushLocalChanges()
            let sqliteData = try XCTUnwrap(receiver.cloudKitSQLiteStore.loadData())
            XCTAssertTrue(sqliteData.transactions.filter { $0.recurrenceRule?.id == ruleID }.allSatisfy { $0.recurrenceRule?.preservesImportedMaterializations == true })
            let reopened = MobileLedgerStore(supportDirectory: receiverFolder)
            XCTAssertFalse(reopened.requiresJournalRecovery)
            XCTAssertEqual(Set(reopened.data.transactions.filter { $0.recurrenceRule?.id == ruleID }.map(\.id)), expected)
            let existing = try XCTUnwrap(reopened.data.transactions.first { $0.recurrenceRule?.id == ruleID })
            var edit = reopened.draft(for: existing); edit.note = "Restored detail edit"
            reopened.saveTransaction(edit)
            XCTAssertNil(reopened.validationError)
            try reopened.flushLocalChanges()
            let final = MobileLedgerStore(supportDirectory: receiverFolder)
            XCTAssertEqual(Set(final.data.transactions.filter { $0.recurrenceRule?.id == ruleID }.map(\.id)), expected)
            var newSeries = final.makeTransactionDraft()
            newSeries.note = "New repeating series after restore"
            newSeries.postings[0].amount = "-15"; newSeries.postings[1].amount = "15"
            newSeries.repeatFrequency = .monthly; newSeries.repeatOccurrenceCount = 3
            final.saveTransaction(newSeries)
            XCTAssertNil(final.validationError)
            XCTAssertEqual(final.data.transactions.filter { $0.note == newSeries.note }.count, 3)
            try final.flushLocalChanges()
            let newRows = try XCTUnwrap(final.cloudKitSQLiteStore.loadData()).transactions.filter { $0.note == newSeries.note }
            XCTAssertEqual(newRows.count, 3)
            XCTAssertTrue(newRows.allSatisfy { $0.recurrenceRule?.preservesImportedMaterializations == false })
        }
    }

    func testNestedReceiptsSurviveRestoreReopenAndOtherReceiptDeletion() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        var journal = store.data
        let receipts = [Data("First receipt".utf8), Data("Second receipt".utf8)]
        var files: [MobileBackupAttachment] = []
        for index in 0..<2 {
            let path = "Attachments/scans/2026/receipt-\(index).txt"
            let asset = AttachmentAsset(originalFilename: "receipt-\(index).txt", storedPath: path, mimeType: "text/plain", sizeBytes: Int64(receipts[index].count))
            journal.transactions[index].attachment = AttachmentContainer(assets: [asset])
            files.append(MobileBackupAttachment(storedPath: path, originalFilename: asset.originalFilename, data: receipts[index]))
        }
        files.append(files[0])
        let backup = folder.appendingPathComponent("nested.json")
        try JSONEncoder.appEncoder.encode(MobileBackupPayload(journalData: journal, attachments: files)).write(to: backup)
        store.importBackup(from: backup)
        XCTAssertNil(store.validationError)
        let reopened = MobileLedgerStore(supportDirectory: folder)
        let remaining = try XCTUnwrap(reopened.transaction(journal.transactions[1].id)?.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: remaining)), receipts[1])
        reopened.deleteTransaction(journal.transactions[0].id)
        XCTAssertNil(reopened.validationError)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: remaining)), receipts[1])
    }

    func testRejectedBackupsPreserveOriginalReceiptBytesAndJournal() throws {
        for mode in ["missing-payload", "missing-package", "invalid-journal", "duplicate-account", "duplicate-transaction", "database-failure"] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
            let originalBytes = Data("Original receipt that must survive".utf8)
            let input = folder.appendingPathComponent("original.txt")
            try originalBytes.write(to: input)
            let asset = try store.importAttachment(from: input)
            var draft = store.draft(for: try XCTUnwrap(store.data.transactions.first))
            draft.attachments = [asset]
            store.saveTransactionAndFlush(draft)
            XCTAssertNil(store.validationError)
            let original = store.data
            let durableBefore = try XCTUnwrap(store.cloudKitSQLiteStore.loadData())
            var candidate = original
            candidate.ledgers[0].name = "Restored journal"
            let newBytes = Data("Replacement bytes".utf8)
            var files = [MobileBackupAttachment(storedPath: asset.storedPath, originalFilename: asset.originalFilename, data: newBytes)]
            if mode.hasPrefix("missing") {
                candidate.transactions[1].attachment = AttachmentContainer(assets: [AttachmentAsset(originalFilename: "missing.txt", storedPath: "Attachments/missing.txt", mimeType: "text/plain", sizeBytes: 1)])
            }
            if mode == "invalid-journal" { candidate.transactions[0].postings[0].accountID = UUID() }
            if mode == "duplicate-account" { candidate.accounts.append(candidate.accounts[0]) }
            if mode == "duplicate-transaction" { candidate.transactions.append(candidate.transactions[0]) }
            if mode == "database-failure" {
                try executeReviewSQL("CREATE TRIGGER reject_restore BEFORE DELETE ON ledgers BEGIN SELECT RAISE(ABORT, 'Synthetic restore failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
            }
            let backup: URL
            if mode == "missing-package" {
                backup = folder.appendingPathComponent("backup.fin", isDirectory: true)
                let file = backup.appendingPathComponent(asset.storedPath)
                try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try newBytes.write(to: file)
                try JSONEncoder.appEncoder.encode(candidate).write(to: backup.appendingPathComponent("Journal.json"))
            } else {
                backup = folder.appendingPathComponent("backup.json")
                // Duplicate equal paths can legitimately occur in exported shared receipts.
                if mode == "database-failure" { files.append(files[0]) }
                try JSONEncoder.appEncoder.encode(MobileBackupPayload(journalData: candidate, attachments: files)).write(to: backup)
            }
            store.importBackup(from: backup)
            XCTAssertNotNil(store.validationError, mode)
            XCTAssertEqual(store.data.transactions, original.transactions, mode)
            XCTAssertEqual(store.data.ledgers, original.ledgers, mode)
            XCTAssertEqual(try store.cloudKitSQLiteStore.loadData()?.transactions, durableBefore.transactions, mode)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: asset)), originalBytes, mode)
            let restoredFolders = try FileManager.default.contentsOfDirectory(atPath: folder.appendingPathComponent("Attachments").path).filter { $0.hasPrefix("Restore-") }
            XCTAssertTrue(restoredFolders.isEmpty, mode)
        }
    }

    func testDeletingReceiptDoesNotRemovePendingEditorAttachment() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let input = folder.appendingPathComponent("receipt.txt")
        try Data("Saved receipt".utf8).write(to: input)
        let savedAsset = try store.importAttachment(from: input)
        let row = try XCTUnwrap(store.data.transactions.first)
        var draft = store.draft(for: row); draft.attachments = [savedAsset]
        store.saveTransactionAndFlush(draft)
        let pendingBytes = Data("Receipt in another unsaved editor".utf8)
        try pendingBytes.write(to: input)
        let pendingAsset = try store.importAttachment(from: input)
        store.deleteTransaction(row.id)
        XCTAssertNil(store.validationError)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: savedAsset).path))
        XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: pendingAsset)), pendingBytes)
    }

    func testSyncPreservesUnlockedSessionAndExplicitLock() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        store.setPasswordLock(password: "synthetic-password", confirmation: "synthetic-password")
        store.lockApp(); store.unlock(password: "synthetic-password")
        let context = "synthetic-unlock-context"
        _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "synthetic-account")
        try store.cloudKitCommitRemote([], data: store.data, contextKey: context, changeToken: Data([1]))
        XCTAssertFalse(store.requiresUnlock)
        var changed = store.data
        changed.transactions[0].note = "Unrelated remote note"
        let bytes = try JSONEncoder.appEncoder.encode(changed.transactions[0])
        let remote = CloudKitSyncRecord(recordType: "transaction", recordID: changed.transactions[0].id.uuidString, contentHash: SHA256.hash(data: bytes).map { String(format: "%02x", $0) }.joined(), payloadJSON: String(decoding: bytes, as: UTF8.self), clientChangeID: UUID().uuidString, systemFields: Data([2]))
        try store.cloudKitCommitRemote([remote], data: changed, contextKey: context, changeToken: Data([2]))
        XCTAssertFalse(store.requiresUnlock)
        var conflictRemote = remote
        conflictRemote.clientChangeID = UUID().uuidString
        conflictRemote.systemFields = Data([3])
        try store.cloudKitSQLiteStore.saveCloudKitConflict(local: remote, remote: conflictRemote, contextKey: context)
        let conflict = try XCTUnwrap(store.cloudKitSQLiteStore.unresolvedCloudKitConflicts(contextKey: context).first)
        try store.cloudKitCommitConflictResolution(id: conflict.id, keepLocal: true, data: store.data, contextKey: context)
        XCTAssertFalse(store.requiresUnlock)
        store.lockApp()
        try store.cloudKitCommitRemote([], data: store.data, contextKey: context, changeToken: Data([4]))
        XCTAssertTrue(store.requiresUnlock)
    }

    func testCyclicAccountPullIsRejectedBeforeJournalOrCheckpointChanges() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let context = "synthetic-cycle-context"
        _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "synthetic-account")
        try store.cloudKitCommitRemote([], data: store.data, contextKey: context, changeToken: Data([1]))
        let original = store.data
        var candidate = original
        let first = try XCTUnwrap(candidate.accounts.firstIndex { $0.name == "Checking" })
        let second = try XCTUnwrap(candidate.accounts.firstIndex { $0.name == "Cash" })
        candidate.accounts[first].parentID = candidate.accounts[second].id
        candidate.accounts[second].parentID = candidate.accounts[first].id
        XCTAssertThrowsError(try store.cloudKitCommitRemote([], data: candidate, contextKey: context, changeToken: Data([2])))
        XCTAssertEqual(store.data.accounts, original.accounts)
        XCTAssertEqual(Set(try XCTUnwrap(store.cloudKitSQLiteStore.loadData()).accounts), Set(original.accounts))
        XCTAssertEqual(try store.cloudKitSQLiteStore.cloudKitChangeToken(contextKey: context), Data([1]))
        // Previously saved invalid data must enter recovery instead of rebuilding a cyclic cache.
        try store.cloudKitSQLiteStore.replaceData(candidate, trackSyncChanges: false)
        let reopened = MobileLedgerStore(supportDirectory: folder)
        XCTAssertTrue(reopened.requiresJournalRecovery)
    }

    func testClaimedReceiptSurvivesDeleteOrRestoreUntilUploadRetryIsAcknowledged() throws {
        for restore in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
            let input = folder.appendingPathComponent("receipt.txt")
            let bytes = Data("Original upload bytes".utf8)
            try bytes.write(to: input)
            let asset = try store.importAttachment(from: input)
            let row = try XCTUnwrap(store.data.transactions.first)
            var draft = store.draft(for: row); draft.attachments = [asset]
            store.saveTransactionAndFlush(draft)
            let context = "synthetic-retry-context"
            _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "synthetic-account")
            let submitted = try store.cloudKitSQLiteStore.claimCloudKitChanges(contextKey: context, limit: 1000)
            let receipt = try XCTUnwrap(submitted.first { $0.recordType == "attachment_asset" })
            if restore {
                let backup = try store.exportBackupFile()
                store.importBackup(from: backup)
            } else { store.deleteTransaction(row.id) }
            XCTAssertNil(store.validationError)
            XCTAssertEqual(try Data(contentsOf: store.attachmentURL(for: asset)), bytes)
            let reopened = MobileLedgerStore(supportDirectory: folder)
            let retry = try reopened.cloudKitSQLiteStore.claimCloudKitChanges(contextKey: context, limit: 1000)
            let retriedReceipt = try XCTUnwrap(retry.first { $0.clientChangeID == receipt.clientChangeID })
            XCTAssertEqual(retriedReceipt.assetSHA256, receipt.assetSHA256)
            XCTAssertEqual(try Data(contentsOf: XCTUnwrap(retriedReceipt.assetFileURL)), bytes)
            for tag in 1...5 {
                let pending = try reopened.cloudKitSQLiteStore.claimCloudKitChanges(contextKey: context, limit: 1000)
                if pending.isEmpty { break }
                let accepted = pending.map { record in
                    var saved = record; saved.systemFields = Data([UInt8(tag)]); return saved
                }
                try reopened.cloudKitSQLiteStore.acknowledgeCloudKitRecords(accepted, submitted: pending, contextKey: context)
            }
            XCTAssertTrue(try reopened.cloudKitSQLiteStore.claimCloudKitChanges(contextKey: context, limit: 1000).isEmpty)
            try reopened.cloudKitSyncDidFinish(at: Date())
            XCTAssertFalse(FileManager.default.fileExists(atPath: store.attachmentURL(for: asset).path))
            if restore {
                let restored = try XCTUnwrap(reopened.transaction(row.id)?.attachment?.assets.first)
                XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: restored)), bytes)
            }
        }
    }

    func testOriginalImportPrefersExternalReceiptAndPreservesPriorDataOnCommitFailure() throws {
        for failCommit in [false, true] {
            let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            defer { try? FileManager.default.removeItem(at: folder) }
            let local = folder.appendingPathComponent("Local", isDirectory: true)
            let original = folder.appendingPathComponent("Original/Attachments/receipt.txt")
            let existing = local.appendingPathComponent("Attachments/receipt.txt")
            let oldBytes = Data("Old local receipt".utf8), importedBytes = Data("Current original receipt".utf8)
            for url in [original, existing] { try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true) }
            try oldBytes.write(to: existing); try importedBytes.write(to: original)
            var journal = DemoData.fixture()
            let asset = AttachmentAsset(originalFilename: "receipt.txt", storedPath: "Attachments/receipt.txt", mimeType: "text/plain", sizeBytes: Int64(oldBytes.count))
            journal.transactions[0].attachment = AttachmentContainer(assets: [asset])
            let store = MobileLedgerStore(supportDirectory: local, initialData: journal)
            let before = try XCTUnwrap(store.cloudKitSQLiteStore.loadData())
            var imported = journal
            imported.transactions[0].attachment?.assets[0].storedPath = original.path
            if failCommit {
                try executeReviewSQL("CREATE TRIGGER reject_original BEFORE DELETE ON ledgers BEGIN SELECT RAISE(ABORT, 'Synthetic original import failure'); END", at: store.cloudKitSQLiteStore.databaseURL)
                XCTAssertThrowsError(try store.applyOriginalFinancesImportedData(imported))
                XCTAssertEqual(store.data.transactions, journal.transactions)
                XCTAssertEqual(try store.cloudKitSQLiteStore.loadData()?.transactions, before.transactions)
                XCTAssertEqual(try Data(contentsOf: existing), oldBytes)
            } else {
                let result = try store.applyOriginalFinancesImportedData(imported)
                XCTAssertEqual(result.attachmentSummary.copiedAttachments, 1)
                XCTAssertEqual(result.attachmentSummary.missingAttachments, 0)
                let reopened = MobileLedgerStore(supportDirectory: local)
                let restored = try XCTUnwrap(reopened.transaction(journal.transactions[0].id)?.attachment?.assets.first)
                XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: restored)), importedBytes)
                XCTAssertNotEqual(reopened.attachmentURL(for: restored), existing)
            }
            XCTAssertEqual(try Data(contentsOf: original), importedBytes)
        }
    }

    func testRemoteReceiptRelocationCleansTheOldFileAfterCommit() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let oldFile = folder.appendingPathComponent("Attachments/old.txt")
        let newFile = folder.appendingPathComponent("Attachments/new.txt")
        try FileManager.default.createDirectory(at: oldFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let bytes = Data("Receipt restored on another device".utf8)
        try bytes.write(to: oldFile); try bytes.write(to: newFile)
        var data = DemoData.fixture()
        data.transactions[0].attachment = AttachmentContainer(assets: [AttachmentAsset(originalFilename: "receipt.txt", storedPath: "Attachments/old.txt", mimeType: "text/plain", sizeBytes: Int64(bytes.count))])
        let store = MobileLedgerStore(supportDirectory: folder, initialData: data)
        let context = "synthetic-relocation-context"
        _ = try store.cloudKitSQLiteStore.bindCloudKitAccount(contextKey: context, accountID: "synthetic-account")
        var moved = store.data
        moved.transactions[0].attachment?.assets[0].storedPath = "Attachments/new.txt"
        try store.cloudKitCommitRemote([], data: moved, contextKey: context, changeToken: Data([1]))
        XCTAssertFalse(FileManager.default.fileExists(atPath: oldFile.path))
        XCTAssertEqual(try Data(contentsOf: newFile), bytes)
        let reopened = MobileLedgerStore(supportDirectory: folder)
        let asset = try XCTUnwrap(reopened.transaction(moved.transactions[0].id)?.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: asset)), bytes)
    }

    private func executeReviewSQL(_ sql: String, at url: URL) throws {
        var database: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &database), SQLITE_OK)
        defer { sqlite3_close(database) }
        guard let database, sqlite3_exec(database, sql, nil, nil, nil) == SQLITE_OK else {
            throw NSError(domain: "SyntheticSQLiteTest", code: 1)
        }
    }

    func testDuplicatePreservesDateOrUsesTodayAsSelected() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture(referenceDate: Date().addingTimeInterval(-90 * 86400)))
        let original = try XCTUnwrap(store.data.transactions.first)
        var ids = Set(store.data.transactions.map(\.id))
        store.duplicateTransaction(original.id, useToday: false)
        let datedCopy = try XCTUnwrap(store.data.transactions.first { !ids.contains($0.id) })
        XCTAssertEqual(datedCopy.date, original.date)
        ids.insert(datedCopy.id)
        let before = Date()
        store.duplicateTransaction(original.id, useToday: true)
        let todayCopy = try XCTUnwrap(store.data.transactions.first { !ids.contains($0.id) })
        XCTAssertGreaterThanOrEqual(todayCopy.date, before)
        XCTAssertLessThanOrEqual(todayCopy.date, Date())
        XCTAssertEqual(todayCopy.postings.map(\.amount), original.postings.map(\.amount))
    }

    func testCurrentBalancesExcludeFutureOnLoadEditAndDelete() throws {
        let now = Date()
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let account = try XCTUnwrap(data.accounts.first { $0.name == "Checking" })
        let expected = data.transactions.filter { $0.date <= now }.flatMap(\.postings).filter { $0.accountID == account.id }.reduce(Decimal.zero) { $0 + $1.amount }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: data)
        func balance() -> Decimal { store.balanceRows(for: account.id).reduce(.zero) { $0 + $1.amount } }
        XCTAssertEqual(balance(), expected)
        XCTAssertEqual(store.ledgerTotalsByKind(ledgerID: account.ledgerID)[.asset]?.first?.amount, expected)
        let original = try XCTUnwrap(data.transactions.first)
        var draft = store.draft(for: original)
        draft.date = try XCTUnwrap(Calendar.current.date(byAdding: .year, value: 8, to: now))
        store.saveTransactionAndFlush(draft)
        XCTAssertEqual(balance(), expected + Decimal(string: "67.31")!)
        draft.date = original.date
        store.saveTransactionAndFlush(draft)
        XCTAssertEqual(balance(), expected)
        let future = try XCTUnwrap(store.data.transactions.first { $0.date > now })
        store.deleteTransaction(future.id)
        XCTAssertEqual(balance(), expected)
        var today = store.draft(for: try XCTUnwrap(store.data.transactions.first { $0.date > now }))
        today.date = Calendar.current.dateInterval(of: .day, for: now)!.end.addingTimeInterval(-1)
        store.saveTransactionAndFlush(today)
        XCTAssertEqual(balance(), expected - 50)
        XCTAssertNil(store.validationError)
    }

    func testDeletionPersistsItsTombstoneBeforeReturning() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let id = try XCTUnwrap(store.data.transactions.first?.id)
        store.deleteTransaction(id)
        XCTAssertNil(store.validationError)
        XCTAssertTrue(try store.cloudKitSQLiteStore.deletedTransactionIDs().contains(id))
        XCTAssertFalse(try XCTUnwrap(store.cloudKitSQLiteStore.loadData()).transactions.contains { $0.id == id })
    }

    func testCloudKitReceiptLocationSurvivesDeletionThroughSymlinkedFolder() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let real = folder.appendingPathComponent("real"), alias = folder.appendingPathComponent("alias")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: alias, withDestinationURL: real)
        let store = MobileLedgerStore(supportDirectory: alias, initialData: DemoData.fixture())
        let source = folder.appendingPathComponent("receipt.txt")
        try Data("Synthetic receipt".utf8).write(to: source)
        let asset = try store.importAttachment(from: source)
        let originalURL = try store.cloudKitAttachmentURL(for: asset)
        var draft = store.draft(for: try XCTUnwrap(store.data.transactions.first))
        draft.attachments = [asset]
        store.saveTransactionAndFlush(draft)
        XCTAssertNil(store.validationError)
        store.deleteTransaction(try XCTUnwrap(draft.id))
        try store.flushLocalChanges()
        XCTAssertFalse(FileManager.default.fileExists(atPath: originalURL.path))
        XCTAssertEqual(try store.cloudKitAttachmentURL(for: asset), originalURL)
    }

    func testRegisterStartsAtTodayWithFiveYearsOfFutureEntries() throws {
        let now = Date()
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let presentation = RegisterPresentation.build(data: data, rows: data.transactions, scope: .all)
        XCTAssertEqual(presentation.initialDay(now: now), Calendar.current.startOfDay(for: now))
        XCTAssertEqual(presentation.months.flatMap(\.days).flatMap(\.transactions).count, 84)
        let historical = data.transactions.filter { $0.date <= now }
        XCTAssertNil(RegisterPresentation.build(data: data, rows: historical, scope: .all).initialDay(now: now))
    }

    func testFutureOnlyRegisterStartsAtNearestScheduledDay() throws {
        let now = Date()
        let data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        let future = data.transactions.filter { $0.date > now }
        let presentation = RegisterPresentation.build(data: data, rows: future, scope: .all)
        let nearest = try XCTUnwrap(future.map(\.date).min())
        XCTAssertEqual(presentation.initialDay(now: now), Calendar.current.startOfDay(for: nearest))
    }

    func testUnclearedBadgeCountsWholeTodayAndExcludesFutureAndOtherJournal() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let lateToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        var data = DemoData.fixture(referenceDate: now, includeFutureEntries: true)
        data.transactions[0].date = lateToday
        data.transactions[0].cleared = false
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        XCTAssertEqual(store.unclearedTransactionCount(ledgerID: data.ledgers[0].id, now: now, calendar: calendar), 7)
        XCTAssertEqual(store.unclearedTransactionCount(ledgerID: data.ledgers[1].id, now: now, calendar: calendar), 0)
        XCTAssertEqual(store.transactions(scope: .uncleared, ledgerID: data.ledgers[0].id).count, 67)
        XCTAssertFalse(RegisterPresentation.isFuture(lateToday, now: now, calendar: calendar))
        XCTAssertTrue(RegisterPresentation.isFuture(tomorrow, now: now, calendar: calendar))
    }

    func testNewJournalStartsWithZeroMoneyAndNoTransactions() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        store.addJournal(name: "Empty Journal")
        XCTAssertTrue(store.data.transactions.isEmpty)
        XCTAssertTrue(store.ledgerTotalsByKind().values.flatMap { $0 }.allSatisfy { $0.amount == 0 })
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertTrue(reopened.data.transactions.isEmpty)
    }

    func testReceiptBytesSurviveBackupAndReopen() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let source = folder.appendingPathComponent("receipt.txt")
        let bytes = Data("Synthetic receipt: Lunch 25.00".utf8)
        try bytes.write(to: source)
        let asset = try store.importAttachment(from: source)
        let row = try XCTUnwrap(store.data.transactions.first)
        var draft = store.draft(for: row); draft.attachments = [asset]
        store.saveTransaction(draft)
        XCTAssertEqual(store.backupAttachmentCount, 1)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        let restored = try XCTUnwrap(reopened.transaction(row.id)?.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: reopened.attachmentURL(for: restored)), bytes)
        let backup = try reopened.exportBackupFile()
        let receiver = MobileLedgerStore(supportDirectory: folder.appendingPathComponent("receiver"), initialData: JournalData())
        receiver.importBackup(from: backup)
        XCTAssertNil(receiver.validationError)
        let received = try XCTUnwrap(receiver.transaction(row.id)?.attachment?.assets.first)
        XCTAssertEqual(try Data(contentsOf: receiver.attachmentURL(for: received)), bytes)
        reopened.deleteTransaction(row.id)
        XCTAssertEqual(reopened.backupAttachmentCount, 0)
    }

    func testFilteredRegisterPreservesPriorBalanceAndAccountSign() throws {
        let data = DemoData.fixture()
        let account = try XCTUnwrap(data.accounts.first { $0.name == "Checking" })
        let latest = try XCTUnwrap(data.transactions.max { $0.date < $1.date })
        let presentation = RegisterPresentation.build(data: data, rows: [latest], scope: .account(account.id))
        XCTAssertEqual(presentation.amounts[latest.id]?.first?.amount, Decimal(string: "-67.31"))
        let expected = data.transactions.filter { $0.date <= latest.date }.flatMap(\.postings).filter { $0.accountID == account.id }.reduce(Decimal.zero) { $0 + $1.amount }
        XCTAssertEqual(presentation.balances[latest.id]?.first?.amount, expected)
    }

    func testMixedCurrenciesNeverAddTogether() throws {
        var data = DemoData.fixture()
        let journal = data.ledgers[0]
        let currency = Commodity(ledgerID: journal.id, symbol: "EUR", name: "Euro")
        data.commodities.append(currency)
        var transaction = data.transactions[0]
        transaction.id = UUID()
        transaction.postings = transaction.postings.map { p in var p = p; p.id = UUID(); p.commodityID = currency.id; return p }
        data.transactions.append(transaction)
        let presentation = RegisterPresentation.build(data: data, rows: data.transactions, scope: .all)
        let month = try XCTUnwrap(presentation.months.first)
        XCTAssertEqual(Set(month.expenses.map(\.symbol)), Set(["USD", "EUR"]))
        XCTAssertEqual(month.expenses.first { $0.symbol == "EUR" }?.amount, Decimal(string: "-67.31"))
    }

    func testDecimalInputKeepsCryptocurrencyPrecision() throws {
        let amount = try XCTUnwrap(Decimal(string: "0.000123456789"))
        XCTAssertEqual(decimalFromInput(decimalInputString(amount)), amount)
        XCTAssertEqual(decimalFromInput("(12.50*3)+7"), Decimal(string: "44.5"))
        XCTAssertNil(decimalFromInput("2/0"))
    }

    func testNewEntryUsesCurrentAccountAndJournalOrderPersists() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let cash = try XCTUnwrap(store.selectedLedgerAccounts.first { $0.name == "Cash" })
        let draft = store.makeTransactionDraft(kind: .expense, accountID: cash.id)
        XCTAssertTrue(draft.postings.contains { $0.accountID == cash.id })
        let first = try XCTUnwrap(store.orderedLedgers.first)
        store.moveJournals(from: IndexSet(integer: 0), to: 2)
        XCTAssertEqual(store.orderedLedgers.last?.id, first.id)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertEqual(reopened.orderedLedgers.last?.id, first.id)
    }

    func testSaveEditClearAndDeleteAreDurable() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        var draft = store.makeTransactionDraft()
        draft.note = "Acceptance entry"
        draft.postings[0].amount = "12.50*2"
        draft.postings[1].amount = "-25"
        store.saveTransaction(draft)
        XCTAssertNil(store.validationError)
        let saved = try XCTUnwrap(store.data.transactions.first { $0.note == "Acceptance entry" })
        var edit = store.draft(for: saved)
        edit.note = "Edited acceptance entry"
        store.saveTransaction(edit)
        store.setTransactionCleared(saved.id, cleared: true)
        try store.flushLocalChanges()
        let reopened = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertEqual(reopened.transaction(saved.id)?.note, "Edited acceptance entry")
        XCTAssertEqual(reopened.transaction(saved.id)?.cleared, true)
        reopened.deleteTransaction(saved.id, scope: .occurrence)
        try reopened.flushLocalChanges()
        let final = MobileLedgerStore(supportDirectory: folder, initialData: JournalData())
        XCTAssertNil(final.transaction(saved.id))
    }

    func testUnbalancedEntryDoesNotAlterSavedJournal() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: folder) }
        let store = MobileLedgerStore(supportDirectory: folder, initialData: DemoData.fixture())
        let count = store.data.transactions.count
        var draft = store.makeTransactionDraft()
        draft.postings[0].amount = "25"; draft.postings[1].amount = "-20"
        store.saveTransaction(draft)
        XCTAssertNotNil(store.validationError)
        XCTAssertEqual(store.data.transactions.count, count)
    }
}
