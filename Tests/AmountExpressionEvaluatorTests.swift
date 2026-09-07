import XCTest
@testable import FinancesClone

final class AmountExpressionEvaluatorTests: XCTestCase {

    private func assertEvaluates(
        _ expression: String,
        to expected: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let expectedValue = Decimal(string: expected, locale: Locale(identifier: "en_US_POSIX")) else {
            XCTFail("Bad expected literal \(expected)", file: file, line: line)
            return
        }
        let result = AmountExpressionEvaluator.evaluate(expression)
        XCTAssertEqual(result, expectedValue, "\(expression) evaluated to \(String(describing: result))", file: file, line: line)
    }

    private func assertRejects(
        _ expression: String,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertNil(
            AmountExpressionEvaluator.evaluate(expression),
            "\(expression) should be rejected",
            file: file,
            line: line
        )
    }

    // MARK: - Required cases

    func testBasicArithmetic() {
        assertEvaluates("12.50*3+7", to: "44.5")
        assertEvaluates("(20-5)*2", to: "30")
        assertEvaluates("2*(3+4)", to: "14")
        assertEvaluates("-5+3", to: "-2")
    }

    func testDivisionRoundsToTenFractionalDigits() {
        assertEvaluates("1/3", to: "0.3333333333")
        assertEvaluates("2/3", to: "0.6666666667")
        // Each division rounds independently, so 1/3*3 keeps the rounded third.
        assertEvaluates("1/3*3", to: "0.9999999999")
        assertEvaluates("10/4", to: "2.5")
        assertEvaluates("1/8", to: "0.125")
    }

    func testGroupingCommas() {
        assertEvaluates("1,234.56", to: "1234.56")
        assertEvaluates("1,234", to: "1234")
        assertEvaluates("1,234,567", to: "1234567")
        assertEvaluates("12,345,678.90", to: "12345678.90")
        assertEvaluates("1,234+1", to: "1235")
    }

    func testEuropeanDecimalComma() {
        assertEvaluates("3,5", to: "3.5")
        assertEvaluates("3,50", to: "3.50")
        // Single comma that cannot be 3-digit grouping is a decimal separator.
        assertEvaluates("1,2345", to: "1.2345")
        assertEvaluates("1234,567", to: "1234.567")
    }

    func testInvalidCommaPatternsAreRejected() {
        assertRejects("1,23,4")
        assertRejects("1,234,56")
        assertRejects("1.2,3")
    }

    func testZeroLedHeadIsDecimalCommaNotGrouping() {
        // A real thousands head never starts with 0: these read as European
        // decimal commas, not as grouped 123/500.
        assertEvaluates("0,123", to: "0.123")
        assertEvaluates("0,500", to: "0.5")
        // The zero-led head falls through to the single-decimal-comma branch:
        // "00,123" normalizes to "00.123" and parses as 0.123.
        assertEvaluates("00,123", to: "0.123")
        // Multiple commas with a zero-led head cannot be grouping or a single
        // decimal comma, so they are invalid.
        assertRejects("0,123,456")
        // Real grouping is unaffected.
        assertEvaluates("1,234", to: "1234")
        assertEvaluates("10,123", to: "10123")
    }

    func testPercentAppliesToPrecedingLiteral() {
        assertEvaluates("10%", to: "0.1")
        assertEvaluates("100+10%", to: "100.1")
        assertEvaluates("20%*300", to: "60")
        assertEvaluates("(20-5)*8.25%", to: "1.2375")
        assertEvaluates("-10%", to: "-0.1")
    }

    func testRejectionCases() {
        assertRejects("")
        assertRejects("   ")
        assertRejects("abc")
        assertRejects("12abc")
        assertRejects("$5")
        assertRejects("1++2")
        assertRejects("1/0")
        assertRejects("1/(2-2)")
        assertRejects("(1+2")
        assertRejects("1+2)")
        assertRejects("()")
        assertRejects("%")
        assertRejects("1 2")
        assertRejects("2(3)")
        assertRejects("1.2.3")
        assertRejects("+5")
        assertRejects("1*")
        assertRejects("*1")
        assertRejects("(20-5)%")
    }

    func testWhitespaceHandling() {
        assertEvaluates("  42  ", to: "42")
        assertEvaluates("12.50 * 3 + 7", to: "44.5")
        assertEvaluates("\t1 +\n2", to: "3")
    }

    // MARK: - Additional coverage

    func testLoneNumbers() {
        assertEvaluates("42", to: "42")
        assertEvaluates("0", to: "0")
        assertEvaluates(".5", to: "0.5")
        assertEvaluates("5.", to: "5")
        assertEvaluates("0.0825", to: "0.0825")
    }

    func testUnaryMinus() {
        assertEvaluates("-5", to: "-5")
        assertEvaluates("--5", to: "5")
        assertEvaluates("2*-3", to: "-6")
        assertEvaluates("1+-2", to: "-1")
        assertEvaluates("-(3+4)", to: "-7")
    }

    func testOperatorPrecedence() {
        assertEvaluates("2+3*4", to: "14")
        assertEvaluates("20-6/2", to: "17")
        assertEvaluates("(20-5)*0.0825", to: "1.2375")
    }

    func testBigValuesStayExactInDecimal() {
        assertEvaluates("123456789012345*1000", to: "123456789012345000")
        assertEvaluates("999999999999999.99+0.01", to: "1000000000000000")
        assertEvaluates("9,999,999,999.99*2", to: "19999999999.98")
    }

    func testDecimalPrecisionBeatsDouble() {
        // 0.1 + 0.2 must be exactly 0.3 (Double would give 0.30000000000000004).
        assertEvaluates("0.1+0.2", to: "0.3")
        // A total split in thirds and re-summed keeps Decimal semantics.
        assertEvaluates("10.00/3", to: "3.3333333333")
    }

    func testUnicodeOperatorAliases() {
        assertEvaluates("6\u{00D7}7", to: "42")       // multiplication sign
        assertEvaluates("10\u{00F7}4", to: "2.5")     // division sign
        assertEvaluates("\u{2212}5+3", to: "-2")      // unicode minus
    }
}
