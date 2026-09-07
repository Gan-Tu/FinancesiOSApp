import Foundation

/// The cursor covers every scheduled slot already represented by a journal,
/// including gaps/deletions and moved occurrences. It is independent of row IDs,
/// so importing a journal under fresh identities does not reopen old slots.
struct RecurrenceContinuation: Codable, Hashable {
    var anchorDate: Date
    var calendar: Calendar
    var nextOccurrenceIndex: Int
    var consumedOccurrences: Int
    var lastScheduledDay: Date
    var allowsAutomaticExtension: Bool

    init(anchorDate: Date, calendar: Calendar, nextOccurrenceIndex: Int = 1,
         consumedOccurrences: Int = 1, lastScheduledDay: Date? = nil,
         allowsAutomaticExtension: Bool = true) {
        self.anchorDate = anchorDate
        self.calendar = calendar
        self.nextOccurrenceIndex = nextOccurrenceIndex
        self.consumedOccurrences = consumedOccurrences
        self.lastScheduledDay = lastScheduledDay ?? calendar.startOfDay(for: anchorDate)
        self.allowsAutomaticExtension = allowsAutomaticExtension
    }

    private enum CodingKeys: String, CodingKey {
        case anchorDate, calendar, nextOccurrenceIndex, consumedOccurrences, lastScheduledDay, allowsAutomaticExtension
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        anchorDate = try c.decode(Date.self, forKey: .anchorDate)
        calendar = try c.decode(Calendar.self, forKey: .calendar)
        nextOccurrenceIndex = try c.decode(Int.self, forKey: .nextOccurrenceIndex)
        consumedOccurrences = try c.decode(Int.self, forKey: .consumedOccurrences)
        lastScheduledDay = try c.decode(Date.self, forKey: .lastScheduledDay)
        allowsAutomaticExtension = try c.decode(Bool.self, forKey: .allowsAutomaticExtension)
        guard nextOccurrenceIndex >= 1, consumedOccurrences >= 1,
              anchorDate.timeIntervalSince1970.isFinite, lastScheduledDay.timeIntervalSince1970.isFinite,
              lastScheduledDay >= calendar.startOfDay(for: anchorDate) else {
            throw DecodingError.dataCorruptedError(forKey: .nextOccurrenceIndex, in: c, debugDescription: "Invalid recurrence continuation state")
        }
    }
}

extension RecurringJournalEditor {
    struct ContinuationResult {
        var rule: RecurrenceRule
        var additions: [LedgerTransaction]
        var hasMore: Bool
    }

    static func scheduledDate(index: Int, rule: RecurrenceRule, anchor: Date, calendar: Calendar) -> Date? {
        let component: Calendar.Component
        switch rule.frequency {
        case .daily: component = .day
        case .weekly: component = .weekOfYear
        case .monthly: component = .month
        case .yearly: component = .year
        case .never, .custom: return nil
        }
        let (offset, overflow) = index.multipliedReportingOverflow(by: max(1, rule.intervalValue))
        guard !overflow, var date = calendar.date(byAdding: component, value: offset, to: anchor) else { return nil }
        if rule.onWorkdays {
            while calendar.isDateInWeekend(date) {
                guard let next = calendar.date(byAdding: .day, value: 1, to: date) else { return nil }
                date = next
            }
        }
        return date
    }

    /// Compatibility for older backups: preserve the covered range, and resolve
    /// native moved/deleted identities before assigning that range a cursor.
    static func inferredContinuation(rule: RecurrenceRule, rows: [LedgerTransaction],
                                     referenceDate: Date = Date(), calendar: Calendar = .current,
                                     deletedIDs: Set<UUID> = [], allowsAutomaticExtension: Bool = true) -> RecurrenceContinuation? {
        if var state = rule.continuation {
            state.allowsAutomaticExtension = allowsAutomaticExtension
            return state
        }
        guard rule.frequency != .never, rule.frequency != .custom,
              let first = rows.min(by: { $0.date < $1.date }) else { return nil }
        let anchor = rule.templateHistory?.scheduleAnchorDate ?? first.date
        let anchorDay = calendar.startOfDay(for: anchor)
        let latest = rows.map(\.date).max() ?? anchor
        let scanEnd = max(latest, calendar.date(byAdding: .year, value: horizonYears, to: referenceDate) ?? latest)
        let ids = Set(rows.map(\.id))
        var originalDays: [UUID: Date] = [:]
        var deletedThrough = anchorDay
        var slots: [(index: Int, day: Date, count: Int)] = [(0, anchorDay, 1)]
        var previousDay = anchorDay
        var count = 1
        var index = 1
        while index < 1_000_000, let date = scheduledDate(index: index, rule: rule, anchor: anchor, calendar: calendar) {
            let day = calendar.startOfDay(for: date)
            if day > scanEnd { break }
            if let end = rule.endDate, day > calendar.startOfDay(for: end) { break }
            if let limit = rule.occurrenceCount, count >= max(1, limit) { break }
            if day != previousDay {
                count += 1; previousDay = day
                slots.append((index, day, count))
                let id = occurrenceID(ruleID: rule.id, day: day)
                if ids.contains(id) { originalDays[id] = day }
                if deletedIDs.contains(id) { deletedThrough = max(deletedThrough, day) }
            }
            index += 1
        }
        let covered = max(deletedThrough, rows.map { originalDays[$0.id] ?? calendar.startOfDay(for: $0.date) }.max() ?? anchorDay)
        guard let last = slots.last(where: { $0.day <= covered }) else { return nil }
        return RecurrenceContinuation(anchorDate: anchor, calendar: calendar,
            nextOccurrenceIndex: last.index + 1, consumedOccurrences: max(last.count, rows.count),
            lastScheduledDay: last.day, allowsAutomaticExtension: allowsAutomaticExtension)
    }

    static func preparingRecurrencesForBackup(_ journal: JournalData, referenceDate: Date = Date(),
                                              calendar: Calendar = .current, deletedIDs: Set<UUID> = []) -> JournalData {
        var result = journal
        let groups = Dictionary(grouping: journal.transactions.filter { $0.recurrenceRule != nil }, by: { $0.recurrenceRule!.id })
        var rules: [UUID: RecurrenceRule] = [:]
        for (id, rows) in groups {
            guard let first = anchor(ruleID: id, in: rows), var rule = first.recurrenceRule else { continue }
            if rule.templateHistory == nil { rule.templateHistory = RecurrenceTemplateHistory(baseTemplate: RecurrenceTransactionTemplate(transaction: first)) }
            let anchorDate = rule.templateHistory?.scheduleAnchorDate ?? first.date
            rule.templateHistory?.scheduleAnchorDate = anchorDate
            rule.continuation = inferredContinuation(rule: rule, rows: rows, referenceDate: referenceDate,
                calendar: calendar, deletedIDs: deletedIDs,
                allowsAutomaticExtension: rule.continuation?.allowsAutomaticExtension ?? !journal.preservesRecurringMaterializations(for: first))
            rules[id] = rule
        }
        for index in result.transactions.indices {
            if let id = result.transactions[index].recurrenceRule?.id { result.transactions[index].recurrenceRule = rules[id] }
        }
        return result
    }

    static func resumingRecurrencesFromBackup(_ journal: JournalData, referenceDate: Date = Date(),
                                              calendar: Calendar = .current) -> JournalData {
        var result = preparingRecurrencesForBackup(journal, referenceDate: referenceDate, calendar: calendar)
        for index in result.transactions.indices where result.transactions[index].recurrenceRule != nil {
            // Older clients retain the authoritative snapshot. Updated clients
            // use the cursor to extend it, without deduplicating imported rows.
            result.transactions[index].recurrenceRule?.preservesImportedMaterializations = true
            result.transactions[index].recurrenceRule?.continuation?.allowsAutomaticExtension = true
        }
        return result
    }

    static func continueSeries(rule original: RecurrenceRule, rows: [LedgerTransaction], referenceDate: Date,
                               horizonDay: Date, allIDs: inout Set<UUID>, deletedIDs: Set<UUID> = []) -> ContinuationResult {
        guard let first = anchor(ruleID: original.id, in: rows), var state = original.continuation,
              state.allowsAutomaticExtension, original.frequency != .never, original.frequency != .custom else {
            return ContinuationResult(rule: original, additions: [], hasMore: false)
        }
        var rule = original
        let calendar = state.calendar
        let referenceDay = calendar.startOfDay(for: referenceDate)
        let existingIDs = Set(rows.map(\.id))
        var existingDays = Set(rows.map { calendar.startOfDay(for: $0.date) })
        var additions: [LedgerTransaction] = []
        while true {
            if let count = rule.occurrenceCount, state.consumedOccurrences >= max(1, count) { break }
            guard let date = scheduledDate(index: state.nextOccurrenceIndex, rule: rule, anchor: state.anchorDate, calendar: calendar) else { break }
            let day = calendar.startOfDay(for: date)
            if let end = rule.endDate, day > calendar.startOfDay(for: end) { break }
            if rule.occurrenceCount == nil && rule.endDate == nil && day > calendar.startOfDay(for: horizonDay) { break }
            if additions.count >= 2400 { rule.continuation = state; return ContinuationResult(rule: rule, additions: additions, hasMore: true) }
            guard state.nextOccurrenceIndex < Int.max else { break }
            state.nextOccurrenceIndex += 1
            if day <= state.lastScheduledDay { continue }
            state.lastScheduledDay = day
            guard state.consumedOccurrences < Int.max else { break }
            state.consumedOccurrences += 1
            if rule.occurrenceCount == nil && rule.endDate == nil && day < referenceDay { continue }
            let id = occurrenceID(ruleID: rule.id, day: day)
            if existingDays.contains(day) || existingIDs.contains(id) || deletedIDs.contains(id) { continue }
            var row = first
            rule.templateHistory?.template(on: day).apply(to: &row)
            row.id = allIDs.contains(id) ? UUID() : id
            row.date = date; row.cleared = false; row.attachment = nil
            row.postings = row.postings.enumerated().map { index, posting in
                Posting(id: postingID(transactionID: row.id, index: index), accountID: posting.accountID,
                        commodityID: posting.commodityID, amount: posting.amount, listIndex: index)
            }
            additions.append(row); allIDs.insert(row.id); existingDays.insert(day)
        }
        rule.continuation = state
        return ContinuationResult(rule: rule, additions: additions, hasMore: false)
    }
}
