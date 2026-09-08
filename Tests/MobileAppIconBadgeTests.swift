import XCTest
@testable import FinancesClone

@MainActor
final class MobileAppIconBadgeTests: XCTestCase {
    @MainActor
    private final class Center {
        var authorization = MobileAppIconBadgeDependencies.Authorization.enabled
        var requests = 0
        var counts: [Int] = []
        var onWrite: ((Int) async throws -> Void)?
        var dependencies: MobileAppIconBadgeDependencies {
            .init(authorization: { self.authorization }, requestPermission: {
                self.requests += 1
                self.authorization = .enabled
                return true
            }, setCount: { value in
                self.counts.append(value)
                try await self.onWrite?(value)
            })
        }
    }

    private func fixture() -> JournalData {
        var data = DemoData.fixture()
        data.transactions = Array(data.transactions.prefix(2))
        for index in data.transactions.indices {
            data.transactions[index].date = .distantPast
            data.transactions[index].cleared = false
            data.transactions[index].recurrenceRule = nil
        }
        return data
    }

    func testCountAcrossJournalsMatchesTodayAndEarlierIncludingDST() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(TimeZone(identifier: "America/Los_Angeles"))
        let now = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 0, minute: 30)))
        let lateToday = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 1, hour: 23, minute: 30)))
        let tomorrow = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: 2)))
        var data = fixture()
        data.transactions[1].ledgerID = data.ledgers[1].id
        data.transactions[1].date = lateToday
        var future = data.transactions[0]
        future.id = UUID(); future.date = tomorrow
        var cleared = data.transactions[0]
        cleared.id = UUID(); cleared.cleared = true
        var orphan = data.transactions[0]
        orphan.id = UUID(); orphan.ledgerID = UUID()
        data.transactions += [future, cleared, orphan]
        let snapshot = MobileAppIconBadgeSnapshot(data)
        XCTAssertEqual(snapshot.count(now: now, calendar: calendar), 2)
        XCTAssertEqual(snapshot.count(now: tomorrow, calendar: calendar), 3)
    }

    func testStoreMutationsRefreshBadgeAndClearingLastEntryRemovesIt() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let data = fixture()
        let store = MobileLedgerStore(supportDirectory: directory, initialData: data)
        let center = Center()
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        store.enableAppIconBadges(using: badge)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts.last, 2)
        store.setTransactionCleared(data.transactions[0].id, cleared: true)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts.last, 1)
        store.deleteTransaction(data.transactions[1].id)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts.last, 0)
        XCTAssertEqual(center.requests, 0)
        try store.flushLocalChanges()
    }

    func testPermissionRequestedOnlyWhenActiveAndUnclearedEntriesExist() async {
        let center = Center()
        center.authorization = .notDetermined
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        badge.update(fixture())
        await badge.waitUntilIdle()
        XCTAssertEqual(center.requests, 0)
        XCTAssertTrue(center.counts.isEmpty)
        badge.setActive(true)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(center.counts, [2])
        badge.refresh()
        await badge.waitUntilIdle()
        XCTAssertEqual(center.requests, 1)
        XCTAssertEqual(center.counts, [2])
    }

    func testEmptyStoreDoesNotAskForPermissionAndDisabledBadgesAreRespected() async {
        let center = Center()
        center.authorization = .notDetermined
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        badge.update(JournalData())
        badge.setActive(true)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.requests, 0)
        center.authorization = .disabled
        badge.update(fixture())
        await badge.waitUntilIdle()
        XCTAssertTrue(center.counts.isEmpty)
        XCTAssertEqual(center.requests, 0)
        center.authorization = .enabled
        badge.setActive(true)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [2])
    }

    func testNewSnapshotDuringOSWriteWinsAndWritesRemainOrdered() async {
        let center = Center()
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        let started = expectation(description: "First badge request")
        var releaseWrite: CheckedContinuation<Void, Never>?
        center.onWrite = { count in
            if count == 2 {
                await withCheckedContinuation { continuation in
                    releaseWrite = continuation
                    started.fulfill()
                }
            }
        }
        badge.update(fixture())
        await fulfillment(of: [started], timeout: 5)
        badge.update(JournalData())
        releaseWrite?.resume()
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [2, 0])
    }

    func testFailedWriteDoesNotStrandNewerSnapshotOrRetryForever() async {
        let center = Center()
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        let started = expectation(description: "Badge write that fails")
        var releaseWrite: CheckedContinuation<Void, Never>?
        center.onWrite = { count in
            if count == 2 {
                await withCheckedContinuation { continuation in
                    releaseWrite = continuation
                    started.fulfill()
                }
                throw CocoaError(.fileWriteUnknown)
            }
        }
        badge.update(fixture())
        await fulfillment(of: [started], timeout: 5)
        badge.update(JournalData())
        releaseWrite?.resume()
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [2, 0])
        center.onWrite = { _ in throw CocoaError(.fileWriteUnknown) }
        badge.update(fixture())
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [2, 0, 2])
    }

    func testBackgroundWaitDoesNotWaitForPermissionOrCancelWriter() async {
        let started = expectation(description: "Permission pending")
        let returned = expectation(description: "Background refresh can finish")
        var answer: CheckedContinuation<Bool, Never>?
        var authorized = false
        var counts: [Int] = []
        let badge = MobileAppIconBadge(dependencies: .init(authorization: {
            authorized ? .enabled : .notDetermined
        }, requestPermission: {
            let allowed = await withCheckedContinuation { continuation in
                answer = continuation
                started.fulfill()
            }
            authorized = allowed
            return allowed
        }, setCount: { counts.append($0) }))
        badge.update(fixture())
        badge.setActive(true)
        await fulfillment(of: [started], timeout: 5)
        let background = Task {
            await badge.waitForBackgroundRefresh(maximumWait: .milliseconds(10))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        XCTAssertTrue(counts.isEmpty)
        answer?.resume(returning: true)
        await background.value
        await badge.waitUntilIdle()
        XCTAssertEqual(counts, [2])
    }

    func testBackgroundWaitIsBoundedDuringStalledOSWrite() async {
        let center = Center()
        let badge = MobileAppIconBadge(dependencies: center.dependencies)
        let started = expectation(description: "OS write pending")
        let returned = expectation(description: "Background wait expired")
        var finishWrite: CheckedContinuation<Void, Never>?
        center.onWrite = { _ in
            await withCheckedContinuation { continuation in
                finishWrite = continuation
                started.fulfill()
            }
        }
        badge.update(fixture())
        await fulfillment(of: [started], timeout: 5)
        let background = Task {
            await badge.waitForBackgroundRefresh(maximumWait: .milliseconds(10))
            returned.fulfill()
        }
        await fulfillment(of: [returned], timeout: 2)
        finishWrite?.resume()
        await background.value
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [2])
    }

    func testForegroundAndDayChangeRefreshUnchangedSnapshot() async throws {
        let center = Center()
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        let day = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 9, day: 7)))
        var now = day
        var data = fixture()
        data.transactions[1].date = day.addingTimeInterval(86400)
        let badge = MobileAppIconBadge(dependencies: center.dependencies, now: { now }, calendar: { calendar })
        badge.update(data)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [1])
        now = day.addingTimeInterval(86400)
        badge.refresh()
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [1, 2])
        badge.setActive(true)
        await badge.waitUntilIdle()
        XCTAssertEqual(center.counts, [1, 2, 2])
    }
}
