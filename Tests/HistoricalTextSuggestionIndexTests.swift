import Foundation
import XCTest
@testable import FinancesClone

final class HistoricalTextSuggestionIndexTests: XCTestCase {
    private let journal = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let otherJournal = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    func testEligibilityUsesExactInstantAndNextNonblankFutureValue() {
        let rows = [
            row("Past", seconds: -1), row("Now", seconds: 0),
            row(" \n", payee: "\t", seconds: 0.001),
            row("", payee: "Future payee", seconds: 0.002),
            row("Future note", seconds: 1)
        ]
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "").map(\.text), ["Now", "Past"])
        XCTAssertTrue(index.suggestions(for: .payee, in: journal, matching: "").isEmpty)
        XCTAssertEqual(index.nextFutureTransactionDate, now.addingTimeInterval(0.002))
        let advanced = HistoricalTextSuggestionIndex(transactions: rows, asOf: now.addingTimeInterval(0.002))
        XCTAssertEqual(advanced.suggestions(for: .payee, in: journal, matching: "").map(\.text), ["Future payee"])
        XCTAssertEqual(advanced.nextFutureTransactionDate, now.addingTimeInterval(1))
    }

    func testSameJournalAndFieldIsolationAndNoTokenSubstringMatch() {
        let rows = [row("Morning Coffee", payee: "Coffee shop"),
                    row("Other journal", payee: "Other merchant", ledgerID: otherJournal)]
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "morning").map(\.text), ["Morning Coffee"])
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "coffee").isEmpty)
        XCTAssertEqual(index.suggestions(for: .payee, in: journal, matching: "coffee").map(\.text), ["Coffee shop"])
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "other").isEmpty)
        XCTAssertEqual(index.suggestions(for: .note, in: otherJournal, matching: "").map(\.text), ["Other journal"])
    }

    func testRankingUsesFrequencyThenRecencyThenDeterministicLexicalOrder() {
        var rows: [LedgerTransaction] = []
        for seconds in [-30.0, -20, -10] { rows.append(row("Common Frequent", seconds: seconds)) }
        for seconds in [-9.0, -1] { rows.append(row("Common Latest", seconds: seconds)) }
        for name in ["Common Beta", "Common Alpha"] {
            for seconds in [-8.0, -2] { rows.append(row(name, seconds: seconds)) }
        }
        rows += [row("Common Single", seconds: 0), row("Common Older", seconds: -100)]
        let values = HistoricalTextSuggestionIndex(transactions: Array(rows.reversed()), asOf: now)
            .suggestions(for: .note, in: journal, matching: "COMMON")
        XCTAssertEqual(values.map(\.text), ["Common Frequent", "Common Latest", "Common Alpha", "Common Beta", "Common Single"])
        XCTAssertEqual(values.map(\.frequency), [3, 2, 2, 2, 1])
        XCTAssertEqual(values.map(\.lastUsedAt), [-10.0, -1, -2, -2, 0].map(now.addingTimeInterval))
    }

    func testCanonicalDedupUsesNewestOriginalFormattingAndStableSpellingTie() {
        let rows = [row("  Café   Nord  ", seconds: -4),
                    row("CAFE\u{301}   NORD\n", seconds: -3),
                    row("cafe\tNord", seconds: -1), row(" CAFÉ  NORD\n", seconds: -1)]
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        let reversed = HistoricalTextSuggestionIndex(transactions: Array(rows.reversed()), asOf: now)
        let expected = [HistoricalTextSuggestion(text: "CAFÉ  NORD", frequency: 4, lastUsedAt: now.addingTimeInterval(-1))]
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "cafe"), expected)
        XCTAssertEqual(reversed.suggestions(for: .note, in: journal, matching: "café"), expected)
        XCTAssertEqual(index.distinctValueCount, 1)
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: " cafe\n\tNORD ").isEmpty,
                      "The current complete value is excluded even when spelling and whitespace differ")
    }

    func testTrailingWhitespaceRetainsWordBoundaryAndExactCurrentValueIsExcluded() {
        let rows = [row("Uber"), row("UberX"), row("Uber Eats"), row("Uber Freight"), row("Uber\tXL")]
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "uber").map(\.text),
                       ["Uber Eats", "Uber Freight", "Uber\tXL", "UberX"])
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "  UBER \n\t").map(\.text),
                       ["Uber Eats", "Uber Freight", "Uber\tXL"])
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "Uber EATS").isEmpty)
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "Eats").isEmpty)
    }

    func testLimitsEmptyQueriesAndEmptyIndexes() {
        let rows = (0..<12).map { row("Value \($0)") }
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        let expected = ["Value 0", "Value 1", "Value 10", "Value 11", "Value 2"]
        let allValues = expected + ["Value 3", "Value 4", "Value 5", "Value 6", "Value 7", "Value 8", "Value 9"]
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "", limit: 100).map(\.text), allValues)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "", limit: Int.max).map(\.text), allValues)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "", limit: 7).map(\.text), Array(allValues.prefix(7)))
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "").map(\.text), expected)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: " \n\t").map(\.text), expected)
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "Value 1").map(\.text), ["Value 10", "Value 11"])
        XCTAssertEqual(index.suggestions(for: .note, in: journal, matching: "", limit: 1).map(\.text), ["Value 0"])
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "", limit: 0).isEmpty)
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "", limit: -1).isEmpty)
        XCTAssertTrue(index.suggestions(for: .note, in: journal, matching: "", limit: Int.min).isEmpty)
        let empty = HistoricalTextSuggestionIndex(transactions: [], asOf: now)
        XCTAssertTrue(empty.suggestions(for: .note, in: journal, matching: "").isEmpty)
        XCTAssertNil(empty.nextFutureTransactionDate)
        XCTAssertEqual(empty.rankTreeSlotCount, 0)
        XCTAssertLessThan(index.rankTreeSlotCount, 4 * index.distinctValueCount)
    }

    func testCancellationPropagatesBeforeAndDuringConstruction() {
        enum Stopped: Error { case requested }
        let rows = (0..<1_024).map { row("Value \($0)", payee: "Merchant \($0)") }
        XCTAssertThrowsError(try HistoricalTextSuggestionIndex(transactions: rows, asOf: now) { throw Stopped.requested }) {
            XCTAssertTrue($0 is Stopped)
        }
        var calls = 0
        XCTAssertThrowsError(try HistoricalTextSuggestionIndex(transactions: rows, asOf: now) {
            calls += 1
            if calls == 12 { throw Stopped.requested }
        }) { XCTAssertTrue($0 is Stopped) }
        XCTAssertEqual(calls, 12)
    }

    func testASCIIFastPathAndMixedUnicodeMatchOriginalFoundationNormalization() {
        func original(_ value: String) -> String {
            value.split(whereSeparator: \.isWhitespace).joined(separator: " ")
                .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
        }
        // Check every ASCII scalar, including controls that must NOT become
        // whitespace, plus each scalar adjacent to letters and whitespace.
        for byte in UInt8(0)...UInt8(127) {
            let character = String(UnicodeScalar(byte))
            for input in [character, "  A\(character)Z  ", "\t\(character)\r\n\(character)\u{0b}\u{0c}"] {
                XCTAssertEqual(HistoricalTextSuggestionIndex.normalizedStoredKey(input), original(input), input.debugDescription)
            }
        }
        let whitespace = [" ", "\t", "\n", "\r", "\u{0b}", "\u{0c}", "\r\n"]
        for leading in whitespace {
            for trailing in whitespace {
                let input = leading + "UPPER" + leading + trailing + "MiXeD" + trailing
                XCTAssertEqual(HistoricalTextSuggestionIndex.normalizedStoredKey(input), "upper mixed")
            }
        }
        // Non-ASCII can appear anywhere, including after a long ASCII prefix;
        // combining marks, Unicode spaces and locale-sensitive letters must
        // always retain the original Foundation folding behavior.
        let unicode = ["Café", "CAFE\u{301}", "İstanbul", "Straße", "ÅLAND", "\u{00a0}", "\u{2003}", "酒店", "🚌", "ＡＢＣ", "Σίσυφος"]
        for value in unicode {
            for input in [value, " \tASCII  \(value) \nEND ", value + " \tUPPER ", "LONG_ASCII_PREFIX_" + value] {
                XCTAssertEqual(HistoricalTextSuggestionIndex.normalizedStoredKey(input), original(input), input.debugDescription)
            }
        }
        // Deterministic combinations stress transitions between whitespace,
        // punctuation, case and preserved control characters.
        for seed in 0..<256 {
            let bytes = (0..<48).map { UInt8((seed * 37 + $0 * 19) % 128) }
            let input = String(decoding: bytes, as: UTF8.self)
            XCTAssertEqual(HistoricalTextSuggestionIndex.normalizedStoredKey(input), original(input), input.debugDescription)
        }
    }

    func testPrefixTreeMatchesIndependentFullScanOracleAcrossBroadAndNarrowQueries() {
        let phrases = ["Uber", "UberX", "Uber Eats", " Uber\tFreight ", "CAFÉ Nord", "cafe\u{301}  nord",
                       "Breakfast at Cafe", "酒店", "酒店 住宿", "上海 酒店", "Åland", "Aland", "\n", "", "🚌 Travel"]
        let rows = (0..<1_037).map { i in
            row(phrases[(i * 13) % phrases.count], payee: phrases[(i * 7 + 3) % phrases.count],
                seconds: Double((i * 17) % 31 - 25), ledgerID: i.isMultiple(of: 4) ? otherJournal : journal)
        }
        let index = HistoricalTextSuggestionIndex(transactions: rows, asOf: now)
        let queries = ["", " \n", "u", " Uber", "uber ", "uber e", "Uber Eats", "x", "CAFÉ", "cafe nord", "at Cafe",
                       "酒店", "酒店 ", "上海", "å", "Aland", "🚌", "🚌 ", "zzzz"]
        for ledgerID in [journal, otherJournal] {
            for field in HistoricalTextSuggestionField.allCases {
                for query in queries {
                    for limit in [1, 3, 5, 9] {
                        XCTAssertEqual(index.suggestions(for: field, in: ledgerID, matching: query, limit: limit),
                                       oracle(rows, field: field, ledgerID: ledgerID, query: query, limit: limit),
                                       "journal=\(ledgerID) field=\(field) query=\(query.debugDescription) limit=\(limit)")
                    }
                }
            }
        }
    }

    private func row(_ note: String, payee: String = "", seconds: TimeInterval = 0, ledgerID: UUID? = nil) -> LedgerTransaction {
        LedgerTransaction(ledgerID: ledgerID ?? journal, date: now.addingTimeInterval(seconds), payee: payee, note: note,
                          number: "", cleared: true, postings: [], recurrenceRule: nil, attachment: nil)
    }

    /// Deliberately scans and fully sorts candidate groups instead of using the
    /// production range/tree implementation. This is small fixture-only work.
    private func oracle(_ rows: [LedgerTransaction], field: HistoricalTextSuggestionField, ledgerID: UUID,
                        query: String, limit: Int) -> [HistoricalTextSuggestion] {
        func key(_ text: String) -> String {
            text.trimmingCharacters(in: .whitespacesAndNewlines)
                .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
                .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
                .precomposedStringWithCanonicalMapping
        }
        let exact = key(query)
        let prefix = exact.isEmpty ? exact : exact + (query.last?.isWhitespace == true ? " " : "")
        let groups = Dictionary(grouping: rows.filter { $0.ledgerID == ledgerID && $0.date <= now }) {
            key(field == .note ? $0.note : $0.payee)
        }
        let ranked = groups.compactMap { normalized, transactions -> (String, HistoricalTextSuggestion)? in
            guard !normalized.isEmpty, normalized != exact, normalized.utf8.starts(with: prefix.utf8) else { return nil }
            let displayRow = transactions.sorted { left, right in
                if left.date != right.date { return left.date > right.date }
                let lhs = (field == .note ? left.note : left.payee).trimmingCharacters(in: .whitespacesAndNewlines)
                let rhs = (field == .note ? right.note : right.payee).trimmingCharacters(in: .whitespacesAndNewlines)
                return lhs.utf8.lexicographicallyPrecedes(rhs.utf8)
            }[0]
            let display = (field == .note ? displayRow.note : displayRow.payee).trimmingCharacters(in: .whitespacesAndNewlines)
            return (normalized, HistoricalTextSuggestion(text: display, frequency: transactions.count, lastUsedAt: displayRow.date))
        }.sorted { left, right in
            if left.1.frequency != right.1.frequency { return left.1.frequency > right.1.frequency }
            if left.1.lastUsedAt != right.1.lastUsedAt { return left.1.lastUsedAt > right.1.lastUsedAt }
            return left.0.utf8.lexicographicallyPrecedes(right.0.utf8)
        }
        return ranked.prefix(max(0, limit)).map(\.1)
    }
}
