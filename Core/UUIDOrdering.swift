import Foundation

extension UUID {
    /// Byte-wise "less than" that orders exactly like comparing `uuidString`
    /// values, without formatting two strings per comparison.
    ///
    /// `uuidString` is the uppercase hex of the 16 bytes in order, with dashes
    /// at fixed positions, so lexicographic string order equals unsigned byte
    /// order. Same-date register ties sort by this key everywhere (the canonical
    /// (date, id) ordering), and the string form made the launch sort and the
    /// derived-cache rebuild allocate two strings per comparison.
    @inline(__always)
    func canonicallyPrecedes(_ other: UUID) -> Bool {
        withUnsafeBytes(of: uuid) { lhs in
            withUnsafeBytes(of: other.uuid) { rhs in
                memcmp(lhs.baseAddress!, rhs.baseAddress!, 16) < 0
            }
        }
    }
}
