import Foundation
import UserNotifications

@MainActor
struct MobileAppIconBadgeDependencies {
    enum Authorization { case notDetermined, enabled, disabled }
    var authorization: () async -> Authorization
    var requestPermission: () async throws -> Bool
    var setCount: (Int) async throws -> Void

    static var live: Self {
        Self(authorization: {
            let settings = await UNUserNotificationCenter.current().notificationSettings()
            if settings.authorizationStatus == .notDetermined { return .notDetermined }
            return settings.badgeSetting == .enabled ? .enabled : .disabled
        }, requestPermission: {
            try await UNUserNotificationCenter.current().requestAuthorization(options: [.badge])
        }, setCount: { count in
            try await UNUserNotificationCenter.current().setBadgeCount(count)
        })
    }
}

/// An immutable, value-only snapshot. Counting never reads the live store or
/// receipt bytes, and runs away from the main actor for large journals.
struct MobileAppIconBadgeSnapshot: @unchecked Sendable {
    let transactions: [LedgerTransaction]
    let ledgerIDs: Set<UUID>

    init(_ data: JournalData) {
        transactions = data.transactions
        ledgerIDs = Set(data.ledgers.map(\.id))
    }

    func count(now: Date, calendar: Calendar) -> Int {
        guard let tomorrow = calendar.dateInterval(of: .day, for: now)?.end else { return 0 }
        return transactions.reduce(0) { count, row in
            count + (!row.cleared && row.date < tomorrow && ledgerIDs.contains(row.ledgerID) ? 1 : 0)
        }
    }
}

@MainActor
final class MobileAppIconBadge {
    private let dependencies: MobileAppIconBadgeDependencies
    private let now: () -> Date
    private let calendar: () -> Calendar
    private var snapshot: MobileAppIconBadgeSnapshot?
    private var revision: UInt = 0
    private var isActive = false
    private var lastWrittenCount: Int?
    private var worker: Task<Void, Never>?

    init(dependencies: MobileAppIconBadgeDependencies = .live,
         now: @escaping () -> Date = Date.init,
         calendar: @escaping () -> Calendar = { .current }) {
        self.dependencies = dependencies
        self.now = now
        self.calendar = calendar
    }

    func update(_ data: JournalData) {
        snapshot = MobileAppIconBadgeSnapshot(data)
        refresh()
    }

    func setActive(_ active: Bool) {
        isActive = active
        if active {
            // Settings may have changed while the app was away, even when the
            // transaction count is identical to the previous foreground session.
            lastWrittenCount = nil
            refresh()
        }
    }

    func refresh() {
        revision &+= 1
        guard worker == nil, snapshot != nil else { return }
        worker = Task { [weak self] in await self?.writeLatestCount() }
    }

    func waitUntilIdle() async { await worker?.value }

    /// APNs completion must not wait for a permission dialog or a stalled OS
    /// response. Racing unstructured waiters leaves the shared writer intact.
    func waitForBackgroundRefresh(maximumWait: Duration = .milliseconds(500)) async {
        guard let pending = worker else { return }
        let completion = BackgroundCompletion()
        await withCheckedContinuation { continuation in
            completion.continuation = continuation
            completion.observer = Task {
                await pending.value
                completion.finish()
            }
            completion.timeout = Task {
                do { try await Task.sleep(for: maximumWait) }
                catch { return }
                completion.finish()
            }
        }
    }

    @MainActor
    private final class BackgroundCompletion {
        var continuation: CheckedContinuation<Void, Never>?
        var observer: Task<Void, Never>?
        var timeout: Task<Void, Never>?
        func finish() {
            guard let continuation else { return }
            self.continuation = nil
            observer?.cancel()
            timeout?.cancel()
            observer = nil
            timeout = nil
            continuation.resume()
        }
    }

    private func writeLatestCount() async {
        defer { worker = nil }
        while let snapshot {
            let currentRevision = revision
            let date = now(), currentCalendar = calendar()
            let count = await Task.detached(priority: .utility) {
                snapshot.count(now: date, calendar: currentCalendar)
            }.value
            guard currentRevision == revision else { continue }
            var authorization = await dependencies.authorization()
            guard currentRevision == revision else { continue }
            if authorization == .notDetermined && isActive && count > 0 {
                do {
                    _ = try await dependencies.requestPermission()
                    authorization = await dependencies.authorization()
                } catch {
                    if currentRevision != revision { continue }
                    return
                }
            }
            guard currentRevision == revision else { continue }
            if authorization == .enabled && count != lastWrittenCount {
                do {
                    // One writer serializes OS requests. A change arriving
                    // during this await is written next and can never be lost.
                    try await dependencies.setCount(count)
                    lastWrittenCount = count
                } catch {
                    if currentRevision != revision { continue }
                    return
                }
            }
            if currentRevision == revision { return }
        }
    }
}
