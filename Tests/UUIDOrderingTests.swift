import XCTest
@testable import FinancesClone

final class UUIDOrderingTests: XCTestCase {
    /// The canonical (date, id) ordering used by every register array was
    /// defined in terms of `uuidString`; the byte-wise comparison that replaced
    /// it on the hot paths must agree with the string form for every pair.
    func testCanonicallyPrecedesMatchesUUIDStringOrdering() {
        var ids = (0..<400).map { _ in UUID() }
        // Edge values: all-zero, all-0xFF, and ids that differ only in the
        // last byte or only in the first byte.
        ids.append(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        ids.append(UUID(uuid: (255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255, 255)))
        ids.append(UUID(uuid: (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 1)))
        ids.append(UUID(uuid: (1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        ids.append(UUID(uuid: (0x0A, 0xF0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))
        ids.append(UUID(uuid: (0x0F, 0xA0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)))

        for lhs in ids.prefix(120) {
            for rhs in ids {
                XCTAssertEqual(
                    lhs.canonicallyPrecedes(rhs),
                    lhs.uuidString < rhs.uuidString,
                    "\(lhs.uuidString) vs \(rhs.uuidString)"
                )
            }
        }

        let byBytes = ids.sorted { $0.canonicallyPrecedes($1) }
        let byString = ids.sorted { $0.uuidString < $1.uuidString }
        XCTAssertEqual(byBytes, byString)
    }

    func testCanonicallyPrecedesIsIrreflexiveAndAsymmetric() {
        let id = UUID()
        XCTAssertFalse(id.canonicallyPrecedes(id))
        let other = UUID()
        XCTAssertNotEqual(id.canonicallyPrecedes(other), other.canonicallyPrecedes(id))
    }
}
