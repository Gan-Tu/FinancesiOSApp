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

