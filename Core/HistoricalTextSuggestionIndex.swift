import Foundation

enum HistoricalTextSuggestionField: String, CaseIterable, Hashable, Sendable {
    case note
    case payee
}

struct HistoricalTextSuggestion: Equatable, Sendable {
    let text: String
    let frequency: Int
    let lastUsedAt: Date
}

/// Immutable index of complete historical note/payee values. Prefix lookups
/// visit logarithmic key ranges and rank-tree nodes, never the transaction list.
struct HistoricalTextSuggestionIndex: Sendable {
    private static let foldingLocale = Locale(identifier: "en_US_POSIX")
    let timeBoostEnabled: Bool
    let asOf: Date
    /// The next instant at which a nonblank historical value becomes eligible.
    let nextFutureTransactionDate: Date?
    private let buckets: [BucketKey: Bucket]

    var distinctValueCount: Int { buckets.values.reduce(0) { $0 + $1.entries.count } }
    var rankTreeSlotCount: Int { buckets.values.reduce(0) { $0 + $1.tree.count } }

    init(transactions: [LedgerTransaction], asOf: Date, timeBoost: Bool = false, calendar: Calendar = .current) {
        self.init(transactions: transactions, asOf: asOf, timeBoost: timeBoost, calendar: calendar, checkCancellation: {})
    }

    init(transactions: [LedgerTransaction], asOf: Date, timeBoost: Bool = false, calendar: Calendar = .current, checkCancellation: () throws -> Void) rethrows {
        try checkCancellation()
        self.timeBoostEnabled = timeBoost
        func minuteOfWeek(_ date: Date) -> Double {
            let c = calendar.dateComponents([.weekday, .hour, .minute, .second], from: date)
            return Double((c.weekday! - 1) * 1440 + c.hour! * 60 + c.minute!) + Double(c.second!) / 60
        }
        let context = minuteOfWeek(asOf)
        func bonus(_ date: Date) -> Double {
            guard timeBoost else { return 0 }
            let delta = abs(minuteOfWeek(date) - context)
            let hours = min(delta, 10080 - delta) / 60
            return exp(-0.5 * hours * hours)
        }
        var grouped: [BucketKey: [String: Aggregate]] = [:]
        var nextFuture: Date?

        func add(_ raw: String, field: HistoricalTextSuggestionField, ledgerID: UUID, accountID: UUID?, date: Date) {
            let key = Self.normalizedStoredKey(raw)
            guard !key.isEmpty else { return }
            let display = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            let bucket = BucketKey(ledgerID: ledgerID, field: field, accountID: accountID)
            // Nested default subscripts mutate in place: copying the inner
            // dictionary per transaction would make index construction quadratic.
            grouped[bucket, default: [:]][key, default: Aggregate(text: display, frequency: 0, lastUsedAt: date)]
                .include(display, at: date, bonus: bonus(date))
        }

        for (offset, row) in transactions.enumerated() {
            if offset.isMultiple(of: 128) { try checkCancellation() }
            guard row.date.timeIntervalSinceReferenceDate.isFinite else { continue }
            guard row.date <= asOf else {
                if (!row.note.allSatisfy(\.isWhitespace) || !row.payee.allSatisfy(\.isWhitespace)),
                   nextFuture == nil || row.date < nextFuture! { nextFuture = row.date }
                continue
            }
            // Build account buckets once on the worker, never scan history per query.
            let scopes: [UUID?] = [nil] + Set(row.postings.map(\.accountID)).map { Optional($0) }
            for accountID in scopes {
                add(row.note, field: .note, ledgerID: row.ledgerID, accountID: accountID, date: row.date)
                add(row.payee, field: .payee, ledgerID: row.ledgerID, accountID: accountID, date: row.date)
            }
        }
        try checkCancellation()
        var built: [BucketKey: Bucket] = [:]
        built.reserveCapacity(grouped.count)
        for (key, values) in grouped {
            built[key] = try Bucket(values, checkCancellation: checkCancellation)
        }
        self.asOf = asOf
        nextFutureTransactionDate = nextFuture
        buckets = built
    }

    func suggestions(for field: HistoricalTextSuggestionField, in ledgerID: UUID, matching query: String, limit: Int = 5, accountID: UUID? = nil) -> [HistoricalTextSuggestion] {
        guard limit > 0, let bucket = buckets[BucketKey(ledgerID: ledgerID, field: field, accountID: accountID)] else { return [] }
        let limit = min(limit, bucket.entries.count)
        let exact = Self.normalizedStoredKey(query)
        let prefix = !exact.isEmpty && query.last?.isWhitespace == true ? exact + " " : exact
        return bucket.suggestions(prefix: prefix, excludingExact: exact, limit: limit)
    }

    /// Fixed folding locale keeps the index independent of device language;
    /// NFC makes canonically equivalent Unicode spellings share one key.
    static func normalizedStoredKey(_ value: String) -> String {
        // Most merchant names and short notes are ASCII. Folding those bytes
        // directly avoids Foundation Unicode transformations for every row.
        // Any non-ASCII byte falls back to the complete Unicode contract.
        var bytes: [UInt8] = []
        bytes.reserveCapacity(value.utf8.count)
        var pendingSpace = false
        for byte in value.utf8 {
            guard byte < 128 else { return normalizedUnicodeKey(value) }
            if byte == 32 || (9...13).contains(byte) {
                pendingSpace = !bytes.isEmpty
            } else {
                if pendingSpace { bytes.append(32); pendingSpace = false }
                bytes.append((65...90).contains(byte) ? byte + 32 : byte)
            }
        }
        return String(decoding: bytes, as: UTF8.self)
    }

    private static func normalizedUnicodeKey(_ value: String) -> String {
        value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: foldingLocale)
            .precomposedStringWithCanonicalMapping
    }

    private struct BucketKey: Hashable, Sendable {
        let ledgerID: UUID
        let field: HistoricalTextSuggestionField
        let accountID: UUID?
    }

    private struct Aggregate {
        var text: String
        var frequency: Int
        var timeBonus: Double = 0
        var lastUsedAt: Date

        mutating func include(_ value: String, at date: Date, bonus: Double) {
            frequency += 1
            timeBonus += bonus
            if date > lastUsedAt || (date == lastUsedAt && value.utf8.lexicographicallyPrecedes(text.utf8)) {
                text = value
                lastUsedAt = date
            }
        }
    }

    private struct Entry: Sendable {
        let key: String
        let score: Double
        let suggestion: HistoricalTextSuggestion
    }

    private struct RankedRange {
        let lower: Int
        let upper: Int
        let winner: Int
    }

    private struct Bucket: Sendable {
        let entries: [Entry]
        let leafBase: Int
        /// Less than four slots per distinct value; size is independent of the
        /// number of characters shared by long notes, unlike a character trie.
        let tree: [Int]

        init(_ values: [String: Aggregate], checkCancellation: () throws -> Void) rethrows {
            var entries: [Entry] = []
            entries.reserveCapacity(values.count)
            for (offset, pair) in values.enumerated() {
                if offset.isMultiple(of: 128) { try checkCancellation() }
                entries.append(Entry(key: pair.key, score: Double(pair.value.frequency) + pair.value.timeBonus, suggestion: HistoricalTextSuggestion(
                    text: pair.value.text, frequency: pair.value.frequency, lastUsedAt: pair.value.lastUsedAt)))
            }
            var comparisons = 0
            try entries.sort { left, right in
                comparisons += 1
                if comparisons.isMultiple(of: 256) { try checkCancellation() }
                return left.key.utf8.lexicographicallyPrecedes(right.key.utf8)
            }
            try checkCancellation()
            var base = 1
            while base < entries.count { base *= 2 }
            var tree = Array(repeating: -1, count: base * 2)
            for index in entries.indices {
                if index.isMultiple(of: 256) { try checkCancellation() }
                tree[base + index] = index
            }
            if base > 1 {
                for index in stride(from: base - 1, through: 1, by: -1) {
                    if index.isMultiple(of: 256) { try checkCancellation() }
                    tree[index] = Self.better(tree[index * 2], tree[index * 2 + 1], entries: entries)
                }
            }
            self.entries = entries
            leafBase = base
            self.tree = tree
        }

        private static func better(_ left: Int, _ right: Int, entries: [Entry]) -> Int {
            if left < 0 { return right }
            if right < 0 { return left }
            if entries[left].score != entries[right].score { return entries[left].score > entries[right].score ? left : right }
            let lhs = entries[left].suggestion, rhs = entries[right].suggestion
            if lhs.frequency != rhs.frequency { return lhs.frequency > rhs.frequency ? left : right }
            if lhs.lastUsedAt != rhs.lastUsedAt { return lhs.lastUsedAt > rhs.lastUsedAt ? left : right }
            // Entries already follow deterministic normalized UTF-8 lexical order.
            return min(left, right)
        }

        private func winner(in lower: Int, _ upper: Int) -> Int {
            var lower = lower + leafBase, upper = upper + leafBase, best = -1
            while lower < upper {
                if !lower.isMultiple(of: 2) { best = Self.better(best, tree[lower], entries: entries); lower += 1 }
                if !upper.isMultiple(of: 2) { upper -= 1; best = Self.better(best, tree[upper], entries: entries) }
                lower /= 2; upper /= 2
            }
            return best
        }

        func suggestions(prefix: String, excludingExact exact: String, limit: Int) -> [HistoricalTextSuggestion] {
            var lower = 0, upper = entries.count
            if !prefix.isEmpty {
                while lower < upper {
                    let middle = lower + (upper - lower) / 2
                    if entries[middle].key.utf8.lexicographicallyPrecedes(prefix.utf8) { lower = middle + 1 }
                    else { upper = middle }
                }
                var end = entries.count
                upper = lower
                while upper < end {
                    let middle = upper + (end - upper) / 2
                    if entries[middle].key.utf8.starts(with: prefix.utf8) { upper = middle + 1 }
                    else { end = middle }
                }
            }
            // A distinct exact value can only be the first key in this range.
            if lower < upper, entries[lower].key == exact { lower += 1 }
            guard lower < upper else { return [] }
            let limit = min(limit, upper - lower)

            var heap: [RankedRange] = []
            heap.reserveCapacity(limit)
            func ranksBefore(_ left: RankedRange, _ right: RankedRange) -> Bool {
                Self.better(left.winner, right.winner, entries: entries) == left.winner
            }
            func push(_ value: RankedRange) {
                heap.append(value)
                var index = heap.count - 1
                while index > 0 {
                    let parent = (index - 1) / 2
                    guard ranksBefore(heap[index], heap[parent]) else { break }
                    heap.swapAt(index, parent); index = parent
                }
            }
            func pop() -> RankedRange {
                let result = heap[0]
                let last = heap.removeLast()
                if !heap.isEmpty {
                    heap[0] = last
                    var index = 0
                    while index * 2 + 1 < heap.count {
                        var child = index * 2 + 1
                        if child + 1 < heap.count, ranksBefore(heap[child + 1], heap[child]) { child += 1 }
                        guard ranksBefore(heap[child], heap[index]) else { break }
                        heap.swapAt(index, child); index = child
                    }
                }
                return result
            }
            push(RankedRange(lower: lower, upper: upper, winner: winner(in: lower, upper)))
            var result: [HistoricalTextSuggestion] = []
            result.reserveCapacity(limit)
            while result.count < limit, !heap.isEmpty {
                let best = pop()
                result.append(entries[best.winner].suggestion)
                if best.lower < best.winner {
                    push(RankedRange(lower: best.lower, upper: best.winner, winner: winner(in: best.lower, best.winner)))
                }
                if best.winner + 1 < best.upper {
                    push(RankedRange(lower: best.winner + 1, upper: best.upper, winner: winner(in: best.winner + 1, best.upper)))
                }
            }
            return result
        }
    }
}


/// Local-only patterns, precomputed for the 168 weekday/hour slots off the main thread.
enum FrequentTransactionTemplate {
    static func slot(at date: Date, calendar: Calendar = .current) -> Int {
        (calendar.component(.weekday, from: date) - 1) * 24 + calendar.component(.hour, from: date)
    }

    static func catalogue(transactions: [LedgerTransaction], ledgerID: UUID?, now: Date = Date(),
                          calendar: Calendar = .current) -> [Int: TransactionTemplate] {
        guard let ledgerID else { return [:] }
        let cutoff = now.addingTimeInterval(-60 * 24 * 3600)
        struct Key: Hashable { let slot: Int; let note: String; let payee: String; let accounts: [UUID] }
        struct Usage { var row: LedgerTransaction; var count: Int }
        var groups: [Key: Usage] = [:]
        for (index, row) in transactions.enumerated() {
            if index.isMultiple(of: 128), Task.isCancelled { return [:] }
            guard row.ledgerID == ledgerID && row.date >= cutoff && row.date <= now else { continue }
            let note = row.note.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !note.isEmpty, row.postings.count >= 2 else { continue }
            let key = Key(slot: slot(at: row.date, calendar: calendar), note: note,
                          payee: row.payee.trimmingCharacters(in: .whitespacesAndNewlines),
                          accounts: row.postings.map(\.accountID).sorted { $0.uuidString < $1.uuidString })
            if var usage = groups[key] {
                usage.count += 1
                if row.date > usage.row.date { usage.row = row }
                groups[key] = usage
            } else { groups[key] = Usage(row: row, count: 1) }
        }
        func better(_ a: Usage, than b: Usage) -> Bool {
            if a.count != b.count { return a.count > b.count }
            if a.row.date != b.row.date { return a.row.date > b.row.date }
            return a.row.id.uuidString < b.row.id.uuidString
        }
        var winners: [Int: Usage] = [:]
        for (key, usage) in groups where usage.count >= 5 {
            if let old = winners[key.slot], !better(usage, than: old) { continue }
            winners[key.slot] = usage
        }
        return winners.mapValues { usage in
            let row = usage.row
            return TransactionTemplate(id: row.id, ledgerID: ledgerID,
                name: row.note.trimmingCharacters(in: .whitespacesAndNewlines), note: row.note, payee: row.payee,
                cleared: false, postings: row.postings.sorted { $0.listIndex < $1.listIndex }.enumerated().map {
                    PostingTemplate(accountID: $0.element.accountID, listIndex: $0.offset)
                })
        }
    }

    static func suggestion(transactions: [LedgerTransaction], ledgerID: UUID?, now: Date = Date(),
                           calendar: Calendar = .current) -> TransactionTemplate? {
        catalogue(transactions: transactions, ledgerID: ledgerID, now: now, calendar: calendar)[slot(at: now, calendar: calendar)]
    }
}
