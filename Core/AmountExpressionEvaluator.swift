import Foundation

/// Evaluates arithmetic expressions typed into amount fields, mirroring the
/// original Finances app's DDMathParser-backed entry ("12.50*3+7", "1/3",
/// "(20-5)*0.0825").
///
/// All arithmetic is performed in `Decimal` (never `Double`). Division rounds
/// its result to 10 fractional digits (`NSDecimalRound`, plain) so repeating
/// decimals terminate deterministically.
///
/// Grammar (recursive descent):
///
///     expression := term (("+" | "-") term)*
///     term       := factor (("*" | "/") factor)*
///     factor     := "-" factor | primary
///     primary    := number ["%"] | "(" expression ")"
///
/// A trailing `%` applies only to the immediately preceding numeric literal and
/// divides it by 100 exactly ("10%" == 0.1, "100+10%" == 100.1).
///
/// Comma disambiguation for numeric literals:
/// - Contains both "," and ".": commas are grouping separators and are
///   stripped ("1,234.56" == 1234.56). Commas after the "." are invalid.
/// - Contains only commas: if the literal forms valid 3-digit grouping
///   (head of 1-3 digits with no leading zero, every later group exactly 3
///   digits) the commas are grouping ("1,234" == 1234, "1,234,567" ==
///   1234567). Otherwise a single comma is a decimal separator ("3,5" == 3.5,
///   "1234,567" == 1234.567, "0,123" == 0.123) and multiple non-grouping
///   commas are invalid ("1,23,4" == nil, "0,123,456" == nil).
enum AmountExpressionEvaluator {

    /// Evaluates an arithmetic expression to a `Decimal` suitable for money
    /// entry. Returns `nil` if the string is not a valid expression (empty
    /// input, letters or unknown symbols, unbalanced parentheses, malformed
    /// operator sequences such as "1++2", division by zero, or overflow).
    /// A lone number (with optional grouping commas) is a valid expression.
    static func evaluate(_ expression: String) -> Decimal? {
        guard let tokens = tokenize(expression), !tokens.isEmpty else { return nil }
        var parser = Parser(tokens: tokens)
        guard let value = parser.parseExpression(), parser.isAtEnd else { return nil }
        return value
    }

    // MARK: - Tokenizer

    private enum Token: Equatable {
        case number(Decimal)
        case plus
        case minus
        case star
        case slash
        case percent
        case leftParen
        case rightParen
    }

    private static func isASCIIDigit(_ character: Character) -> Bool {
        character.isASCII && character.isNumber
    }

    private static func tokenize(_ input: String) -> [Token]? {
        var tokens: [Token] = []
        let characters = Array(input)
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character.isWhitespace {
                index += 1
                continue
            }
            switch character {
            case "+":
                tokens.append(.plus)
                index += 1
            case "-", "\u{2212}": // ASCII hyphen-minus or Unicode minus sign
                tokens.append(.minus)
                index += 1
            case "*", "\u{00D7}": // asterisk or multiplication sign
                tokens.append(.star)
                index += 1
            case "/", "\u{00F7}": // slash or division sign
                tokens.append(.slash)
                index += 1
            case "%":
                tokens.append(.percent)
                index += 1
            case "(":
                tokens.append(.leftParen)
                index += 1
            case ")":
                tokens.append(.rightParen)
                index += 1
            default:
                guard isASCIIDigit(character) || character == "." || character == "," else {
                    return nil
                }
                var literal = ""
                while index < characters.count {
                    let candidate = characters[index]
                    guard isASCIIDigit(candidate) || candidate == "." || candidate == "," else { break }
                    literal.append(candidate)
                    index += 1
                }
                guard let value = decimalFromLiteral(literal) else { return nil }
                tokens.append(.number(value))
            }
        }
        return tokens
    }

    // MARK: - Numeric literals

    private static let posixLocale = Locale(identifier: "en_US_POSIX")

    /// Normalizes comma usage per the rules documented on the enum, then parses
    /// the literal with a POSIX locale so "." is always the decimal separator.
    private static func decimalFromLiteral(_ literal: String) -> Decimal? {
        guard literal.contains(where: isASCIIDigit) else { return nil }

        let commaCount = literal.reduce(into: 0) { count, character in
            if character == "," { count += 1 }
        }
        var normalized = literal
        if commaCount > 0 {
            if let dotIndex = literal.firstIndex(of: ".") {
                // Mixed separators: commas are grouping, but only before the dot.
                guard literal[dotIndex...].contains(",") == false else { return nil }
                normalized = literal.replacingOccurrences(of: ",", with: "")
            } else if hasValidCommaGrouping(literal) {
                normalized = literal.replacingOccurrences(of: ",", with: "")
            } else if commaCount == 1 {
                // European-style decimal comma ("3,5" -> 3.5).
                normalized = literal.replacingOccurrences(of: ",", with: ".")
            } else {
                return nil
            }
        }

        var digitCount = 0
        var dotCount = 0
        for character in normalized {
            if isASCIIDigit(character) {
                digitCount += 1
            } else if character == "." {
                dotCount += 1
            } else {
                return nil
            }
        }
        guard digitCount > 0, dotCount <= 1 else { return nil }
        return Decimal(string: normalized, locale: posixLocale)
    }

    /// True when a commas-only literal reads as standard thousands grouping:
    /// a head of 1-3 digits with no leading zero followed by groups of exactly
    /// 3 digits. A zero-led head ("0,123", "00,123") is never thousands
    /// grouping — those literals read as decimal commas instead.
    private static func hasValidCommaGrouping(_ literal: String) -> Bool {
        let groups = literal.split(separator: ",", omittingEmptySubsequences: false)
        guard groups.count >= 2 else { return false }
        let head = groups[0]
        guard (1...3).contains(head.count), head.allSatisfy(isASCIIDigit) else { return false }
        guard head.first != "0" else { return false }
        for group in groups.dropFirst() {
            guard group.count == 3, group.allSatisfy(isASCIIDigit) else { return false }
        }
        return true
    }

    // MARK: - Parser

    private struct Parser {
        let tokens: [Token]
        private(set) var position = 0

        var isAtEnd: Bool { position >= tokens.count }

        private var current: Token? {
            position < tokens.count ? tokens[position] : nil
        }

        private mutating func advance() -> Token? {
            guard position < tokens.count else { return nil }
            defer { position += 1 }
            return tokens[position]
        }

        private mutating func match(_ token: Token) -> Bool {
            guard current == token else { return false }
            position += 1
            return true
        }

        mutating func parseExpression() -> Decimal? {
            guard var value = parseTerm() else { return nil }
            while true {
                if match(.plus) {
                    guard let rhs = parseTerm(), let sum = value.checkedAdding(rhs) else { return nil }
                    value = sum
                } else if match(.minus) {
                    guard let rhs = parseTerm(), let difference = value.checkedSubtracting(rhs) else { return nil }
                    value = difference
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parseTerm() -> Decimal? {
            guard var value = parseFactor() else { return nil }
            while true {
                if match(.star) {
                    guard let rhs = parseFactor(), let product = value.checkedMultiplying(by: rhs) else { return nil }
                    value = product
                } else if match(.slash) {
                    guard let rhs = parseFactor(), let quotient = value.checkedDividing(by: rhs) else { return nil }
                    value = quotient
                } else {
                    break
                }
            }
            return value
        }

        private mutating func parseFactor() -> Decimal? {
            if match(.minus) {
                guard let value = parseFactor() else { return nil }
                return -value
            }
            return parsePrimary()
        }

        private mutating func parsePrimary() -> Decimal? {
            guard let token = advance() else { return nil }
            switch token {
            case .number(let value):
                if match(.percent) {
                    return value.percentLiteralValue()
                }
                return value
            case .leftParen:
                guard let value = parseExpression(), match(.rightParen) else { return nil }
                return value
            default:
                return nil
            }
        }
    }
}

// MARK: - Checked Decimal arithmetic

private extension NSDecimalNumber.CalculationError {
    /// Loss of precision is acceptable for money math; every other error
    /// (overflow, underflow, divide by zero) invalidates the expression.
    var isAcceptableForAmountEntry: Bool {
        self == .noError || self == .lossOfPrecision
    }
}

private extension Decimal {
    func checkedAdding(_ other: Decimal) -> Decimal? {
        var result = Decimal()
        var lhs = self
        var rhs = other
        let status = NSDecimalAdd(&result, &lhs, &rhs, .plain)
        return status.isAcceptableForAmountEntry ? result : nil
    }

    func checkedSubtracting(_ other: Decimal) -> Decimal? {
        var result = Decimal()
        var lhs = self
        var rhs = other
        let status = NSDecimalSubtract(&result, &lhs, &rhs, .plain)
        return status.isAcceptableForAmountEntry ? result : nil
    }

    func checkedMultiplying(by other: Decimal) -> Decimal? {
        var result = Decimal()
        var lhs = self
        var rhs = other
        let status = NSDecimalMultiply(&result, &lhs, &rhs, .plain)
        return status.isAcceptableForAmountEntry ? result : nil
    }

    /// Division rounds to 10 fractional digits (plain) so repeating decimals
    /// like 1/3 terminate. Division by zero returns nil.
    func checkedDividing(by other: Decimal) -> Decimal? {
        guard other != .zero else { return nil }
        var result = Decimal()
        var lhs = self
        var rhs = other
        let status = NSDecimalDivide(&result, &lhs, &rhs, .plain)
        guard status.isAcceptableForAmountEntry else { return nil }
        var rounded = Decimal()
        NSDecimalRound(&rounded, &result, 10, .plain)
        return rounded
    }

    /// Exact divide-by-100 for a trailing percent on a literal ("10%" == 0.1).
    func percentLiteralValue() -> Decimal? {
        var result = Decimal()
        var value = self
        let status = NSDecimalMultiplyByPowerOf10(&result, &value, -2, .plain)
        return status.isAcceptableForAmountEntry ? result : nil
    }
}
