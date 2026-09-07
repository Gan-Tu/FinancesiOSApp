import Foundation

struct BankStatementImportResult: Equatable {
    var importedCount = 0
    var skippedCount = 0
}

enum BankStatementImportError: LocalizedError, Equatable {
    case emptyFile
    case missingAmountColumn
    case missingDateColumn
    case missingStatementAccount
    case missingCounterAccount
    case unreadableRow(Int)

    var errorDescription: String? {
        switch self {
        case .emptyFile:
            "The statement file is empty."
        case .missingAmountColumn:
            "The statement needs an Amount column, or Debit and Credit columns."
        case .missingDateColumn:
            "The statement needs a Date column."
        case .missingStatementAccount:
            "No asset account is available for imported bank rows."
        case .missingCounterAccount:
            "No income or expense account is available for imported bank rows."
        case .unreadableRow(let row):
            "Statement row \(row) could not be imported."
        }
    }
}

struct BankStatementImporter {
    let url: URL

    func rows() throws -> [BankStatementRow] {
        let payload = try String(contentsOf: url, encoding: .utf8)
        switch url.pathExtension.lowercased() {
        case "ofx", "qfx":
            return try OFXStatementParser(payload: payload).rows()
        case "qif":
            return try QIFStatementParser(payload: payload, sourceName: url.lastPathComponent).rows()
        default:
            return try csvRows(from: payload)
        }
    }

    private func csvRows(from payload: String) throws -> [BankStatementRow] {
        let delimiter: Character = url.pathExtension.lowercased() == "tsv" ? "\t" : ","
        let table = CSVTable.parse(payload, delimiter: delimiter)
        guard !table.isEmpty else { throw BankStatementImportError.emptyFile }
        let header = table[0].map { $0.normalizedHeader }
        guard !header.isEmpty else { throw BankStatementImportError.emptyFile }
        guard let dateIndex = BankStatementColumn.date.index(in: header) else {
            throw BankStatementImportError.missingDateColumn
        }
        let payeeIndex = BankStatementColumn.payee.index(in: header)
        let noteIndex = BankStatementColumn.note.index(in: header)
        let categoryIndex = BankStatementColumn.category.index(in: header)
        let numberIndex = BankStatementColumn.number.index(in: header)
        let amountIndex = BankStatementColumn.amount.index(in: header)
        let debitIndex = BankStatementColumn.debit.index(in: header)
        let creditIndex = BankStatementColumn.credit.index(in: header)
        guard amountIndex != nil || debitIndex != nil || creditIndex != nil else {
            throw BankStatementImportError.missingAmountColumn
        }

        var rows: [BankStatementRow] = []
        for (offset, fields) in table.dropFirst().enumerated() {
            let rowNumber = offset + 2
            guard fields.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
                continue
            }
            guard let dateText = fields[safe: dateIndex]?.trimmingCharacters(in: .whitespacesAndNewlines),
                  let date = BankStatementDateParser.date(from: dateText) else {
                throw BankStatementImportError.unreadableRow(rowNumber)
            }
            guard let amount = amount(from: fields, amountIndex: amountIndex, debitIndex: debitIndex, creditIndex: creditIndex) else {
                throw BankStatementImportError.unreadableRow(rowNumber)
            }
            guard amount != .zero else {
                continue
            }
            let payee = fields[safe: payeeIndex]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? "Imported Transaction"
            let note = fields[safe: noteIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let category = fields[safe: categoryIndex]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
            let number = fields[safe: numberIndex]?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            rows.append(BankStatementRow(
                date: date,
                payee: payee,
                note: note,
                number: number,
                category: category,
                amount: amount,
                externalID: number.nilIfEmpty,
                sourceAccountIdentifier: url.lastPathComponent,
                splits: []
            ))
        }
        return rows
    }

    private func amount(
        from fields: [String],
        amountIndex: Int?,
        debitIndex: Int?,
        creditIndex: Int?
    ) -> Decimal? {
        if let amountIndex, let amount = BankStatementDecimalParser.decimal(from: fields[safe: amountIndex]) {
            return amount
        }
        let debit = BankStatementDecimalParser.decimal(from: fields[safe: debitIndex]) ?? .zero
        let credit = BankStatementDecimalParser.decimal(from: fields[safe: creditIndex]) ?? .zero
        let amount = credit - debit
        return amount == .zero ? nil : amount
    }
}

struct BankStatementRow: Equatable {
    var date: Date
    var payee: String
    var note: String
    var number: String
    var category: String?
    var amount: Decimal
    var externalID: String?
    var sourceAccountIdentifier: String?
    var splits: [BankStatementSplit] = []
}

struct BankStatementSplit: Equatable {
    var category: String?
    var memo: String?
    var amount: Decimal
}

private struct OFXStatementParser {
    let payload: String

    func rows() throws -> [BankStatementRow] {
        let blocks = transactionBlocks()
        guard !blocks.isEmpty else { throw BankStatementImportError.emptyFile }
        let sourceAccountIdentifier = accountIdentifier()
        var rows: [BankStatementRow] = []
        for (index, block) in blocks.enumerated() {
            let rowNumber = index + 1
            guard let dateText = tag("DTPOSTED", in: block)?.nilIfEmpty ?? tag("DTUSER", in: block)?.nilIfEmpty,
                  let date = BankStatementDateParser.ofxDate(from: dateText),
                  let amountText = tag("TRNAMT", in: block),
                  let amount = BankStatementDecimalParser.decimal(from: amountText),
                  amount != .zero else {
                throw BankStatementImportError.unreadableRow(rowNumber)
            }
            let name = tag("NAME", in: block)?.nilIfEmpty ?? tag("PAYEE", in: block)?.nilIfEmpty ?? "Imported Transaction"
            let memo = tag("MEMO", in: block) ?? ""
            let checkNumber = tag("CHECKNUM", in: block) ?? tag("REFNUM", in: block) ?? ""
            let fitID = tag("FITID", in: block)?.nilIfEmpty
            rows.append(BankStatementRow(
                date: date,
                payee: name,
                note: memo,
                number: checkNumber,
                category: nil,
                amount: amount,
                externalID: fitID,
                sourceAccountIdentifier: sourceAccountIdentifier,
                splits: []
            ))
        }
        return rows
    }

    private func transactionBlocks() -> [String] {
        var blocks: [String] = []
        var searchStart = payload.startIndex
        while let startRange = nextTransactionStart(from: searchStart) {
            guard let openEnd = payload[startRange.upperBound...].firstIndex(of: ">") else { break }
            let contentStart = payload.index(after: openEnd)
            let closingRange = payload.range(of: "</STMTTRN>", range: contentStart..<payload.endIndex)
            let nextRange = nextTransactionStart(from: contentStart)
            let bankEndRange = payload.range(of: "</BANKTRANLIST>", range: contentStart..<payload.endIndex)
            let contentEnd = closingRange?.lowerBound ??
                nextRange?.lowerBound ??
                bankEndRange?.lowerBound ??
                payload.endIndex
            blocks.append(String(payload[contentStart..<contentEnd]))
            searchStart = closingRange?.upperBound ?? contentEnd
            if searchStart >= payload.endIndex { break }
        }
        return blocks
    }

    private func nextTransactionStart(from index: String.Index) -> Range<String.Index>? {
        var cursor = index
        while let range = payload.range(of: "<STMTTRN", range: cursor..<payload.endIndex) {
            let tagEnd = range.upperBound
            guard tagEnd < payload.endIndex else { return nil }
            let next = payload[tagEnd]
            if next == ">" || next == " " || next == "\n" || next == "\t" {
                return range
            }
            cursor = tagEnd
        }
        return nil
    }

    private func accountIdentifier() -> String? {
        let bankID = tag("BANKID", in: payload)?.nilIfEmpty
        let accountID = tag("ACCTID", in: payload)?.nilIfEmpty
        switch (bankID, accountID) {
        case (.some(let bankID), .some(let accountID)):
            return "\(bankID):\(accountID)"
        case (.none, .some(let accountID)):
            return accountID
        case (.some(let bankID), .none):
            return bankID
        case (.none, .none):
            return nil
        }
    }

    private func tag(_ name: String, in block: String) -> String? {
        guard let startRange = block.range(of: "<\(name)", options: [.caseInsensitive]) else { return nil }
        guard let openEnd = block[startRange.upperBound...].firstIndex(of: ">") else { return nil }
        let valueStart = block.index(after: openEnd)
        guard valueStart < block.endIndex else { return "" }
        let closeRange = block.range(of: "</\(name)>", options: [.caseInsensitive], range: valueStart..<block.endIndex)
        let nextTag = block[valueStart...].firstIndex(of: "<")
        let valueEnd = closeRange?.lowerBound ?? nextTag ?? block.endIndex
        return String(block[valueStart..<valueEnd])
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .decodedOFXEntities
    }
}

private struct QIFStatementParser {
    let payload: String
    let sourceName: String

    func rows() throws -> [BankStatementRow] {
        let lines = payload
            .components(separatedBy: .newlines)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        var rows: [BankStatementRow] = []
        var record = QIFRecord()
        var sawSupportedType = false
        var currentSplit = QIFSplitDraft()

        func finishSplitIfNeeded() {
            if currentSplit.hasContent {
                record.splits.append(currentSplit)
                currentSplit = QIFSplitDraft()
            }
        }

        func finishRecord(rowNumber: Int) throws {
            finishSplitIfNeeded()
            guard record.hasContent else { return }
            guard let dateText = record.date,
                  let date = BankStatementDateParser.date(from: dateText),
                  let amount = record.amount,
                  amount != .zero else {
                throw BankStatementImportError.unreadableRow(rowNumber)
            }
            let splits = try record.splits.map { split -> BankStatementSplit in
                guard let amount = split.amount, amount != .zero else {
                    throw BankStatementImportError.unreadableRow(rowNumber)
                }
                return BankStatementSplit(
                    category: split.category?.qifCategoryName,
                    memo: split.memo ?? "",
                    amount: amount
                )
            }
            if !splits.isEmpty {
                let splitTotal = splits.reduce(Decimal.zero) { $0 + $1.amount }
                guard splitTotal == amount else {
                    throw BankStatementImportError.unreadableRow(rowNumber)
                }
            }
            rows.append(BankStatementRow(
                date: date,
                payee: record.payee?.nilIfEmpty ?? "Imported Transaction",
                note: record.memo ?? "",
                number: record.number ?? "",
                category: record.category?.qifCategoryName,
                amount: amount,
                externalID: record.number?.nilIfEmpty,
                sourceAccountIdentifier: sourceName,
                splits: splits
            ))
            record = QIFRecord()
        }

        for (offset, line) in lines.enumerated() {
            guard !line.isEmpty else { continue }
            if line.hasPrefix("!") {
                let uppercased = line.uppercased()
                if uppercased.hasPrefix("!TYPE:BANK") ||
                    uppercased.hasPrefix("!TYPE:CCARD") ||
                    uppercased.hasPrefix("!TYPE:CASH") {
                    sawSupportedType = true
                    continue
                }
                if uppercased.hasPrefix("!TYPE:") {
                    throw BankStatementImportError.unreadableRow(offset + 1)
                }
                continue
            }
            guard sawSupportedType else { throw BankStatementImportError.unreadableRow(offset + 1) }
            if line == "^" {
                try finishRecord(rowNumber: offset + 1)
                continue
            }
            guard let key = line.first else { continue }
            let value = String(line.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            switch key {
            case "D":
                record.date = value
            case "T", "U":
                record.amount = BankStatementDecimalParser.decimal(from: value)
            case "P":
                record.payee = value
            case "M":
                record.memo = value
            case "N":
                record.number = value
            case "L":
                record.category = value
            case "S":
                finishSplitIfNeeded()
                currentSplit.category = value
            case "E":
                currentSplit.memo = value
            case "$":
                currentSplit.amount = BankStatementDecimalParser.decimal(from: value)
            default:
                continue
            }
        }
        try finishRecord(rowNumber: max(lines.count, 1))
        guard !rows.isEmpty else { throw BankStatementImportError.emptyFile }
        return rows
    }
}

private struct QIFRecord {
    var date: String?
    var amount: Decimal?
    var payee: String?
    var memo: String?
    var number: String?
    var category: String?
    var splits: [QIFSplitDraft] = []

    var hasContent: Bool {
        date != nil || amount != nil || payee != nil || memo != nil || number != nil || category != nil || !splits.isEmpty
    }
}

private struct QIFSplitDraft {
    var category: String?
    var memo: String?
    var amount: Decimal?

    var hasContent: Bool {
        category != nil || memo != nil || amount != nil
    }
}

private enum BankStatementColumn {
    case date
    case payee
    case note
    case category
    case number
    case amount
    case debit
    case credit

    var aliases: Set<String> {
        switch self {
        case .date:
            ["date", "posteddate", "postingdate", "transactiondate"]
        case .payee:
            ["payee", "description", "name", "merchant"]
        case .note:
            ["note", "notes", "memo", "details"]
        case .category:
            ["category", "account", "financesaccount"]
        case .number:
            ["number", "checknumber", "check", "ref", "reference"]
        case .amount:
            ["amount", "transactionamount"]
        case .debit:
            ["debit", "withdrawal", "withdrawals", "outflow"]
        case .credit:
            ["credit", "deposit", "deposits", "inflow"]
        }
    }

    func index(in headers: [String]) -> Int? {
        headers.firstIndex { aliases.contains($0) }
    }
}

private enum BankStatementDateParser {
    private static let formats = [
        "yyyy-MM-dd",
        "yyyy/MM/dd",
        "MM/dd/yyyy",
        "M/d/yyyy",
        "MM-dd-yyyy",
        "M-d-yyyy",
        "MMM d, yyyy",
        "MMMM d, yyyy"
    ]

    static func date(from value: String) -> Date? {
        for format in formats {
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.dateFormat = format
            if let date = formatter.date(from: value) {
                return date
            }
        }
        return nil
    }

    static func ofxDate(from value: String) -> Date? {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits = String(trimmed.prefix { $0.isNumber })
        guard digits.count >= 8 else { return nil }
        let datePortion = String(digits.prefix(8))
        let timePortion = digits.count >= 14 ? String(digits.dropFirst(8).prefix(6)) : "000000"
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyyMMddHHmmss"
        return formatter.date(from: datePortion + timePortion)
    }
}

private enum BankStatementDecimalParser {
    static func decimal(from value: String?) -> Decimal? {
        guard var value = value?.trimmingCharacters(in: .whitespacesAndNewlines), !value.isEmpty else {
            return nil
        }
        var isParenthesized = false
        if value.hasPrefix("("), value.hasSuffix(")") {
            isParenthesized = true
            value.removeFirst()
            value.removeLast()
        }
        value = value
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard var decimal = Decimal(string: value, locale: Locale(identifier: "en_US_POSIX")) else {
            return nil
        }
        if isParenthesized {
            decimal *= -1
        }
        return decimal
    }
}

private enum CSVTable {
    static func parse(_ payload: String, delimiter: Character) -> [[String]] {
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var iterator = payload.makeIterator()
        var inQuotes = false

        while let character = iterator.next() {
            if inQuotes {
                if character == "\"" {
                    if let next = iterator.next() {
                        if next == "\"" {
                            field.append("\"")
                        } else {
                            inQuotes = false
                            consume(next, delimiter: delimiter, row: &row, field: &field, rows: &rows)
                        }
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(character)
                }
            } else if character == "\"" {
                inQuotes = true
            } else {
                consume(character, delimiter: delimiter, row: &row, field: &field, rows: &rows)
            }
        }

        row.append(field)
        if row.contains(where: { !$0.isEmpty }) {
            rows.append(row)
        }
        return rows
    }

    private static func consume(
        _ character: Character,
        delimiter: Character,
        row: inout [String],
        field: inout String,
        rows: inout [[String]]
    ) {
        if character == delimiter {
            row.append(field)
            field = ""
        } else if character == "\n" {
            row.append(field)
            field = ""
            rows.append(row)
            row = []
        } else if character != "\r" {
            field.append(character)
        }
    }
}

private extension Array {
    subscript(safe index: Int?) -> Element? {
        guard let index, indices.contains(index) else { return nil }
        return self[index]
    }
}

private extension String {
    var normalizedHeader: String {
        lowercased().filter { $0.isLetter || $0.isNumber }
    }

    var nilIfEmpty: String? {
        isEmpty ? nil : self
    }

    var qifCategoryName: String {
        var value = self
        if value.hasPrefix("["), value.hasSuffix("]") {
            value.removeFirst()
            value.removeLast()
        }
        return value
    }

    var decodedOFXEntities: String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&apos;", with: "'")
    }
}
