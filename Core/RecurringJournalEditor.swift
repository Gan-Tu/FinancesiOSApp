import CryptoKit
import Foundation

/// Value-only recurrence editing shared with mobile. Scope, template history,
/// calendar calculations and generated identities follow the Mac editor.
enum RecurringJournalEditor {
    enum Scope: Equatable { case occurrence, future }
    static let horizonYears = 5

    static func anchor(ruleID: UUID, in rows: [LedgerTransaction]) -> LedgerTransaction? {
        rows.filter { $0.recurrenceRule?.id == ruleID }.min(by: precedes)
    }

    /// Partial peer uploads and per-item conflict choices may temporarily carry
    /// different embedded rule values. Background work must not pick a winner.
    static func mixedRuleIDs(in transactions: [LedgerTransaction]) -> Set<UUID> {
        var firstRules: [UUID: RecurrenceRule] = [:]
        var mixed: Set<UUID> = []
        for row in transactions {
            guard let rule = row.recurrenceRule, !mixed.contains(rule.id) else { continue }
            guard let first = firstRules[rule.id] else { firstRules[rule.id] = rule; continue }
            if first == rule { continue }
            let firstPayload = try? JSONEncoder.appEncoder.encode(first)
            let payload = try? JSONEncoder.appEncoder.encode(rule)
            if firstPayload == nil || firstPayload != payload { mixed.insert(rule.id) }
        }
        return mixed
    }

    struct DeletionResult {
        var journal: JournalData
        var deletedIDs: Set<UUID>
        var scheduleChanged: Bool
    }

    static func deleting(_ id: UUID, scope: Scope, in journal: JournalData, calendar: Calendar = .current, deletedIDs: Set<UUID> = []) throws -> DeletionResult {
        guard let row = journal.transactions.first(where: { $0.id == id }) else {
            throw ValidationError(message: "This transaction no longer exists.")
        }
        var result = journal
        var ids: Set<UUID> = [id]
        var scheduleChanged = false
        if var rule = row.recurrenceRule, rule.frequency != .never {
            let series = journal.transactions.filter { $0.ledgerID == row.ledgerID && $0.recurrenceRule?.id == rule.id }
            if scope == .occurrence, mixedRuleIDs(in: series).contains(rule.id) {
                // Removing one row does not select that row's shared rule for
                // every peer occurrence. Preserve each variant independently.
                let first = anchor(ruleID: rule.id, in: series)!
                let deletesAnchor = first.id == id
                var preserved: [RecurrenceRule: RecurrenceRule] = [:]
                for index in result.transactions.indices where result.transactions[index].id != id &&
                    result.transactions[index].ledgerID == row.ledgerID && result.transactions[index].recurrenceRule?.id == rule.id {
                    let prior = result.transactions[index].recurrenceRule!
                    let ownRule: RecurrenceRule
                    if let cached = preserved[prior] { ownRule = cached }
                    else {
                        var value = prior
                        if deletesAnchor, value.templateHistory?.scheduleAnchorDate == nil {
                            let sameVersion = series.first { $0.recurrenceRule == prior } ?? first
                            var history = value.templateHistory ?? RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: sameVersion))
                            history.scheduleAnchorDate = first.date
                            value.templateHistory = history
                        }
                        if value.continuation == nil {
                            // Infer before removal even for a non-anchor/last
                            // occurrence, retaining that consumed slot in backup.
                            value.continuation = inferredContinuation(rule: value, rows: series, calendar: calendar, deletedIDs: deletedIDs,
                                allowsAutomaticExtension: !journal.preservesRecurringMaterializations(for: result.transactions[index]))
                        }
                        preserved[prior] = value
                        ownRule = value
                    }
                    if ownRule != prior {
                        result.transactions[index].recurrenceRule = ownRule
                        scheduleChanged = true
                    }
                }
                if deletesAnchor { scheduleChanged = true }
                result.transactions.removeAll { ids.contains($0.id) }
                return DeletionResult(journal: result, deletedIDs: ids, scheduleChanged: scheduleChanged)
            }
            if scope == .future { ids = Set(series.filter { calendar.startOfDay(for: $0.date) >= calendar.startOfDay(for: row.date) }.map(\.id)) }
            let remaining = series.filter { !ids.contains($0.id) }
            if !remaining.isEmpty {
                let before = rule
                rule.continuation = inferredContinuation(rule: rule, rows: series, calendar: calendar, deletedIDs: deletedIDs,
                    allowsAutomaticExtension: rule.continuation?.allowsAutomaticExtension ?? !journal.preservesRecurringMaterializations(for: row))
                scheduleChanged = rule != before
                if scope == .future {
                    let cutoff = calendar.date(byAdding: .day, value: -1, to: calendar.startOfDay(for: row.date))!
                    rule.endDate = min(rule.endDate ?? cutoff, cutoff)
                    scheduleChanged = true
                } else if anchor(ruleID: rule.id, in: series)?.id == id {
                    var history = rule.templateHistory ?? RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: row))
                    history.scheduleAnchorDate = history.scheduleAnchorDate ?? row.date
                    rule.templateHistory = history
                    scheduleChanged = true
                }
                if scheduleChanged {
                    for index in result.transactions.indices where result.transactions[index].ledgerID == row.ledgerID && result.transactions[index].recurrenceRule?.id == rule.id {
                        result.transactions[index].recurrenceRule = rule
                    }
                }
            }
        }
        result.transactions.removeAll { ids.contains($0.id) }
        return DeletionResult(journal: result, deletedIDs: ids, scheduleChanged: scheduleChanged)
    }

    static func apply(
        _ proposed: LedgerTransaction, replacing previousID: UUID?, in journal: JournalData,
        scope: Scope = .occurrence, referenceDate: Date = Date(), calendar: Calendar = .current,
        deletedIDs: Set<UUID> = []
    ) throws -> JournalData {
        let previous = previousID.flatMap { id in journal.transactions.first { $0.id == id } }
        if previousID != nil && previous == nil {
            throw ValidationError(message: "This transaction no longer exists.")
        }
        guard journal.ledgers.contains(where: { $0.id == proposed.ledgerID }),
              previous.map({ $0.ledgerID == proposed.ledgerID && $0.id == proposed.id }) ?? true else {
            throw ValidationError(message: "The transaction must remain in its journal.")
        }
        var result = journal
        var edited = proposed
        if edited.recurrenceRule?.frequency == .never { edited.recurrenceRule = nil }
        let oldRule = previous?.recurrenceRule.flatMap { $0.frequency == .never ? nil : $0 }
        let originalAnchor = oldRule.flatMap { anchor(ruleID: $0.id, in: journal.transactions) }
        let hasMixedRules = oldRule.map { mixedRuleIDs(in: journal.transactions).contains($0.id) } ?? false
        // An explicit future edit uses the selected occurrence's version when
        // the group is mixed; choosing the earliest row would invent recency.
        let canonicalRule = hasMixedRules ? oldRule : originalAnchor?.recurrenceRule ?? oldRule
        let isAnchor = previous == nil || oldRule == nil || originalAnchor?.id == previousID
        let scheduleChanged = previous.map { old in
            old.date != edited.date || !scheduleMatches(canonicalRule, edited.recurrenceRule)
        } ?? false
        if let oldRule {
            guard edited.recurrenceRule == nil || edited.recurrenceRule?.id == oldRule.id else {
                throw ValidationError(message: "An existing occurrence must keep its repeating series.")
            }
            if !isAnchor && !scheduleMatches(canonicalRule, edited.recurrenceRule) {
                throw ValidationError(message: "Change Repeat settings from the first entry in this series.")
            }
            if isAnchor && scheduleChanged && scope != .future {
                throw ValidationError(message: "Confirm Update Repeating Schedule to change the first entry's date or Repeat settings.")
            }
            if isAnchor && scheduleChanged && canonicalRule?.frequency == .custom && edited.recurrenceRule?.frequency == .custom {
                throw ValidationError(message: "Choose a daily, weekly, monthly, or yearly schedule before changing this imported custom pattern.")
            }
            if !isAnchor {
                edited.recurrenceRule = canonicalRule
                if let originalAnchor, edited.date < originalAnchor.date {
                    throw ValidationError(message: "An individual occurrence must remain after the first entry. Change the first entry's date to move the schedule earlier.")
                }
                if edited.date != previous?.date,
                   journal.transactions.contains(where: {
                       $0.id != edited.id && $0.recurrenceRule?.id == oldRule.id &&
                       calendar.isDate($0.date, inSameDayAs: edited.date)
                   }) {
                    throw ValidationError(message: "Another occurrence already uses this date. Choose a different day.")
                }
            }
        } else if let rule = edited.recurrenceRule,
                  journal.transactions.contains(where: { $0.id != edited.id && $0.recurrenceRule?.id == rule.id }) {
            throw ValidationError(message: "A new repeating transaction must start its own series.")
        }
        if hasMixedRules, scope == .occurrence, let previousID, let oldRule,
           let index = result.transactions.firstIndex(where: { $0.id == previousID }) {
            // Validation above still checks identity, dates and Repeat scope.
            // Notes, amounts and receipts belong to this occurrence only.
            edited.recurrenceRule = oldRule
            result.transactions[index] = edited
            return result
        }
        if var rule = edited.recurrenceRule {
            rule.preservesImportedMaterializations = oldRule == nil || (isAnchor && scheduleChanged)
                ? false : canonicalRule?.preservesImportedMaterializations
            rule.intervalValue = max(rule.intervalValue, 1)
            if let count = rule.occurrenceCount, count < 1,
               oldRule == nil || canonicalRule?.occurrenceCount != count {
                throw ValidationError(message: "The number of occurrences must be at least one.")
            }
            if let end = rule.endDate, (oldRule == nil || (isAnchor && scheduleChanged)),
               calendar.startOfDay(for: end) < calendar.startOfDay(for: edited.date) {
                throw ValidationError(message: "The repeating end date cannot precede its first entry.")
            }
            var history = canonicalRule?.templateHistory ?? RecurrenceTemplateHistory(
                baseTemplate: RecurrenceTransactionTemplate(transaction: originalAnchor ?? edited)
            )
            let cadenceChanged = canonicalRule?.frequency != rule.frequency ||
                canonicalRule?.intervalValue != rule.intervalValue || canonicalRule?.onWorkdays != rule.onWorkdays
            if oldRule == nil || (isAnchor && (previous?.date != edited.date || cadenceChanged)) {
                history.scheduleAnchorDate = edited.date
            }
            if scope == .future, let previous {
                let oldDay = calendar.startOfDay(for: previous.date)
                let cutoff = isAnchor ? min(oldDay, calendar.startOfDay(for: edited.date)) : oldDay
                history.replaceFutureTemplate(RecurrenceTransactionTemplate(transaction: edited), from: cutoff)
            }
            rule.templateHistory = history
            if oldRule == nil || (isAnchor && scheduleChanged) {
                rule.continuation = RecurrenceContinuation(anchorDate: history.scheduleAnchorDate ?? edited.date, calendar: calendar)
            } else {
                rule.continuation = canonicalRule?.continuation ?? inferredContinuation(rule: rule,
                    rows: journal.transactions.filter { $0.recurrenceRule?.id == rule.id }, referenceDate: referenceDate,
                    calendar: calendar, deletedIDs: deletedIDs,
                    allowsAutomaticExtension: !journal.preservesRecurringMaterializations(for: originalAnchor ?? edited))
            }
            edited.recurrenceRule = rule
            // SQLite stores one rule per identity. Every in-memory occurrence
            // must carry the same explicit history before any snapshot is saved.
            for index in result.transactions.indices where result.transactions[index].recurrenceRule?.id == rule.id {
                result.transactions[index].recurrenceRule = rule
            }
        }
        if let index = result.transactions.firstIndex(where: { $0.id == edited.id }) {
            result.transactions[index] = edited
        } else { result.transactions.append(edited) }

        if isAnchor, oldRule != nil, edited.recurrenceRule == nil || scheduleChanged {
            result.transactions.removeAll { $0.id != edited.id && $0.recurrenceRule?.id == oldRule?.id }
        }
        if scope == .future, let previous, let rule = edited.recurrenceRule {
            let oldDay = calendar.startOfDay(for: previous.date)
            let cutoff = isAnchor ? min(oldDay, calendar.startOfDay(for: edited.date)) : oldDay
            for index in result.transactions.indices where result.transactions[index].id != edited.id &&
                result.transactions[index].recurrenceRule?.id == rule.id &&
                calendar.startOfDay(for: result.transactions[index].date) >= cutoff {
                // Dates, receipt identity, cleared status and import identifiers
                // belong to each occurrence, not to the future template.
                result.transactions[index].payee = edited.payee
                result.transactions[index].note = edited.note
                result.transactions[index].number = edited.number
                let destinationPostings = result.transactions[index].postings.sorted(by: postingDisplayPrecedes)
                result.transactions[index].postings = edited.postings.enumerated().map { position, posting in
                    // Posting identity belongs to this occurrence's displayed
                    // position, not to the edited occurrence or account value.
                    // Preserve it even for zero amounts and repeated accounts.
                    Posting(id: destinationPostings.indices.contains(position) ? destinationPostings[position].id : UUID(),
                            accountID: posting.accountID, commodityID: posting.commodityID,
                            amount: posting.amount, listIndex: position)
                }
            }
        }
        let countBefore = oldRule.map { old in journal.transactions.filter { $0.recurrenceRule?.id == old.id }.count } ?? 0
        if edited.recurrenceRule != nil && isAnchor &&
            (oldRule == nil || scheduleChanged || (countBefore <= 1 && canonicalRule?.continuation == nil && !journal.preservesRecurringMaterializations(for: edited))) {
            var index = MaterializationIndex(result.transactions)
            materialize(ruleID: edited.recurrenceRule!.id, in: &result, referenceDate: referenceDate, calendar: calendar, deletedIDs: deletedIDs,
                        index: &index)
        }
        if oldRule == nil && edited.recurrenceRule == nil,
           calendar.startOfDay(for: edited.date) > horizon(referenceDate, calendar: calendar) {
            result = materialized(result, referenceDate: referenceDate, calendar: calendar, deletedIDs: deletedIDs)
        }
        return result
    }

    private static func postingDisplayPrecedes(_ lhs: Posting, _ rhs: Posting) -> Bool {
        lhs.listIndex == rhs.listIndex ? lhs.id.canonicallyPrecedes(rhs.id) : lhs.listIndex < rhs.listIndex
    }

    static func materialized(_ journal: JournalData, referenceDate: Date = Date(), calendar: Calendar = .current, deletedIDs: Set<UUID> = []) -> JournalData {
        var result = journal
        let mixed = mixedRuleIDs(in: journal.transactions)
        let ruleIDs = Set(journal.transactions.filter { journal.shouldExtendRecurrences(for: $0) }.compactMap { $0.recurrenceRule?.id }).subtracting(mixed)
        guard !ruleIDs.isEmpty else { return result }
        var index = MaterializationIndex(journal.transactions)
        for id in ruleIDs.sorted(by: { $0.uuidString < $1.uuidString }) {
            materialize(ruleID: id, in: &result, referenceDate: referenceDate, calendar: calendar, deletedIDs: deletedIDs,
                        index: &index)
        }
        return result
    }

    /// What every rule's pass used to recompute by scanning the whole journal
    /// (once per rule and batch, with a calendar call per one-off row). It is
    /// built once and kept current as occurrences are appended, which is the
    /// only way materialization changes the journal: rows are never removed or
    /// reordered, and a row's rule identity never changes.
    private struct MaterializationIndex {
        /// Generated occurrences always carry their rule, so each journal's
        /// latest one-off date is fixed for the whole call. The start of a day
        /// only moves forward with time, so the latest entry's day is the
        /// latest of all their days.
        let latestOneOffDates: [UUID: Date]
        /// Every transaction ID in the journal being materialized.
        var allIDs: Set<UUID>
        /// Each rule's rows and their journal positions, in journal order.
        private var rowsByRule: [UUID: [LedgerTransaction]]
        private var positionsByRule: [UUID: [Int]]

        init(_ transactions: [LedgerTransaction]) {
            var latest: [UUID: Date] = [:]
            var ids = Set<UUID>(minimumCapacity: transactions.count)
            var rows: [UUID: [LedgerTransaction]] = [:]
            var positions: [UUID: [Int]] = [:]
            for (position, row) in transactions.enumerated() {
                ids.insert(row.id)
                if let ruleID = row.recurrenceRule?.id {
                    rows[ruleID, default: []].append(row)
                    positions[ruleID, default: []].append(position)
                } else if latest[row.ledgerID].map({ $0 < row.date }) ?? true {
                    latest[row.ledgerID] = row.date
                }
            }
            latestOneOffDates = latest
            allIDs = ids
            rowsByRule = rows
            positionsByRule = positions
        }

        func rows(ruleID: UUID) -> [LedgerTransaction] { rowsByRule[ruleID] ?? [] }
        func positions(ruleID: UUID) -> [Int] { positionsByRule[ruleID] ?? [] }

        func latestOneOffDay(ledgerID: UUID?, calendar: Calendar) -> Date {
            ledgerID.flatMap { latestOneOffDates[$0] }.map { calendar.startOfDay(for: $0) } ?? .distantPast
        }

        /// Records rows appended to the end of the journal for `ruleID`.
        mutating func appended(_ additions: [LedgerTransaction], ruleID: UUID, journalCount: Int) {
            guard !additions.isEmpty else { return }
            let start = journalCount - additions.count
            rowsByRule[ruleID, default: []].append(contentsOf: additions)
            positionsByRule[ruleID, default: []].append(contentsOf: start..<journalCount)
            for row in additions { allIDs.insert(row.id) }
        }
    }

    private static func materialize(ruleID: UUID, in journal: inout JournalData, referenceDate: Date, calendar: Calendar, deletedIDs: Set<UUID>,
                                    index: inout MaterializationIndex) {
        if var rule = anchor(ruleID: ruleID, in: index.rows(ruleID: ruleID))?.recurrenceRule, rule.continuation != nil {
            let activeCalendar = rule.continuation!.calendar
            let ledgerID = anchor(ruleID: ruleID, in: index.rows(ruleID: ruleID))?.ledgerID
            let horizonDay = max(horizon(referenceDate, calendar: activeCalendar),
                                 index.latestOneOffDay(ledgerID: ledgerID, calendar: activeCalendar))
            var more: Bool
            repeat {
                let rows = index.rows(ruleID: ruleID)
                let result = continueSeries(rule: rule, rows: rows,
                    referenceDate: referenceDate, horizonDay: horizonDay, allIDs: &index.allIDs, deletedIDs: deletedIDs)
                rule = result.rule; more = result.hasMore
                journal.transactions.append(contentsOf: result.additions)
                index.appended(result.additions, ruleID: ruleID, journalCount: journal.transactions.count)
            } while more
            for position in index.positions(ruleID: ruleID) {
                journal.transactions[position].recurrenceRule = rule
            }
            return
        }
        // Complete finite schedules in bounded allocation chunks. Replaying known
        // slots is necessary to preserve moved identities and deleted-slot counts.
        while materializeBatch(ruleID: ruleID, in: &journal, referenceDate: referenceDate, calendar: calendar, deletedIDs: deletedIDs,
                                index: &index) {}
    }

    private static func materializeBatch(ruleID: UUID, in journal: inout JournalData, referenceDate: Date, calendar: Calendar, deletedIDs: Set<UUID>,
                                         index: inout MaterializationIndex) -> Bool {
        let existing = index.rows(ruleID: ruleID)
        guard let first = anchor(ruleID: ruleID, in: existing), let rule = first.recurrenceRule,
              rule.frequency != .never, rule.frequency != .custom else { return false }
        let scheduleAnchor = rule.templateHistory?.scheduleAnchorDate ?? first.date
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let horizonDay = max(horizon(referenceDate, calendar: calendar),
                             index.latestOneOffDay(ledgerID: first.ledgerID, calendar: calendar))
        let existingIDs = Set(existing.map(\.id))
        let startCount = journal.transactions.count
        defer {
            index.appended(Array(journal.transactions[startCount...]), ruleID: ruleID, journalCount: journal.transactions.count)
        }
        var days = Set(existing.map { calendar.startOfDay(for: $0.date) })
        var count = existing.count + (calendar.startOfDay(for: scheduleAnchor) < calendar.startOfDay(for: first.date) ? 1 : 0)
        var latestFutureDay = days.filter { $0 >= referenceDay }.max()
        let limit = rule.occurrenceCount.map { max($0, 1) }
        let component: Calendar.Component
        switch rule.frequency {
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        case .never, .custom: return false
        }
        var occurrenceIndex = 1
        // Unlimited schedules omit elapsed slots and project from the current day.
        if limit == nil && rule.endDate == nil {
            let elapsed = calendar.dateComponents([component], from: scheduleAnchor, to: referenceDay).value(for: component) ?? 0
            occurrenceIndex = max(1, elapsed / max(rule.intervalValue, 1) - 2)
        }
        var appended = 0
        while true {
            if let limit { if count >= limit { break } }
            else if let latestFutureDay, latestFutureDay >= horizonDay { break }
            let (offset, overflow) = max(rule.intervalValue, 1).multipliedReportingOverflow(by: occurrenceIndex)
            guard !overflow, occurrenceIndex < Int.max,
                  var next = calendar.date(byAdding: component, value: offset, to: scheduleAnchor) else { break }
            occurrenceIndex += 1
            if rule.onWorkdays {
                while calendar.isDateInWeekend(next), let following = calendar.date(byAdding: .day, value: 1, to: next) { next = following }
            }
            let day = calendar.startOfDay(for: next)
            if let end = rule.endDate, day > calendar.startOfDay(for: end) { break }
            if limit == nil && rule.endDate == nil {
                if day < referenceDay { continue }
                if day > horizonDay { break }
            }
            // A slot whose day is taken is skipped before hashing its identity.
            if days.contains(day) { continue }
            let id = occurrenceID(ruleID: ruleID, day: day)
            if existingIDs.contains(id) { continue }
            if deletedIDs.contains(id) {
                days.insert(day); count += 1
                if day >= referenceDay { latestFutureDay = max(latestFutureDay ?? day, day) }
                continue
            }
            guard appended < 2400 else { return true }
            var row = first
            rule.templateHistory?.template(on: day).apply(to: &row)
            row.id = index.allIDs.contains(id) ? UUID() : id
            row.date = next; row.cleared = false; row.attachment = nil
            row.postings = row.postings.enumerated().map { index, posting in
                Posting(id: postingID(transactionID: row.id, index: index), accountID: posting.accountID,
                        commodityID: posting.commodityID, amount: posting.amount, listIndex: index)
            }
            journal.transactions.append(row)
            appended += 1
            index.allIDs.insert(row.id); days.insert(day); count += 1
            if day >= referenceDay { latestFutureDay = max(latestFutureDay ?? day, day) }
        }
        return false
    }

    static func occurrenceID(ruleID: UUID, day: Date) -> UUID {
        identifier(namespace: "recurring-occurrence", parts: [ruleID.uuidString, String(Int64(day.timeIntervalSince1970.rounded()))])
    }
    static func postingID(transactionID: UUID, index: Int) -> UUID {
        identifier(namespace: "recurring-posting", parts: [transactionID.uuidString, String(index)])
    }
    /// The UUID's bytes are the digest's first 16 bytes, in order (what
    /// formatting them as a UUID string and parsing it back produced, without
    /// sixteen `String(format:)` calls per identity).
    private static func identifier(namespace: String, parts: [String]) -> UUID {
        let digest = Array(SHA256.hash(data: Data(([namespace] + parts).joined(separator: "\u{1f}").utf8)))
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }
    private static func horizon(_ referenceDate: Date, calendar: Calendar) -> Date {
        let day = calendar.startOfDay(for: referenceDate)
        return calendar.date(byAdding: .year, value: horizonYears, to: day) ?? day
    }
    private static func scheduleMatches(_ lhs: RecurrenceRule?, _ rhs: RecurrenceRule?) -> Bool {
        guard let lhs, let rhs else { return lhs == nil && rhs == nil }
        return lhs.id == rhs.id && lhs.frequency == rhs.frequency && max(lhs.intervalValue, 1) == max(rhs.intervalValue, 1) &&
            lhs.occurrenceCount == rhs.occurrenceCount && lhs.endDate == rhs.endDate && lhs.onWorkdays == rhs.onWorkdays
    }
    private static func precedes(_ lhs: LedgerTransaction, _ rhs: LedgerTransaction) -> Bool {
        lhs.date == rhs.date ? lhs.id.uuidString < rhs.id.uuidString : lhs.date < rhs.date
    }
}
