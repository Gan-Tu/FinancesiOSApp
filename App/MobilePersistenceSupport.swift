import Foundation
import UIKit

/// Only not-yet-started, non-barrier saves can absorb a newer snapshot. The
/// serial writer takes one immutable value before starting validation or I/O.
final class MobileDeferredPersistenceBatch: @unchecked Sendable {
    struct Request {
        var snapshot: JournalData
        var sequence: UInt64
        var trackSyncChanges: Bool
        var validateSnapshot: Bool
        var scheduleCloudAfterSuccess: Bool
        var refreshCloudStateAfterSuccess: Bool
    }

    private let lock = NSLock()
    private var acceptingUpdates = true
    private var request: Request

    init(_ request: Request) { self.request = request }

    func replacePending(with newer: Request) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard acceptingUpdates, request.trackSyncChanges == newer.trackSyncChanges else { return false }
        request.snapshot = newer.snapshot
        request.sequence = newer.sequence
        request.validateSnapshot = request.validateSnapshot || newer.validateSnapshot
        request.scheduleCloudAfterSuccess = request.scheduleCloudAfterSuccess || newer.scheduleCloudAfterSuccess
        request.refreshCloudStateAfterSuccess = request.refreshCloudStateAfterSuccess || newer.refreshCloudStateAfterSuccess
        return true
    }

    func seal() {
        lock.lock(); defer { lock.unlock() }
        acceptingUpdates = false
    }

    func take() -> Request {
        lock.lock(); defer { lock.unlock() }
        acceptingUpdates = false
        return request
    }
}

/// Completion delivery can resume MainActor tasks in a different order from
/// their writer queue. An older failure must not replace a newer success.
struct MobilePersistenceOutcomeState {
    private(set) var sequence: UInt64 = 0
    private(set) var error: ValidationError?

    @discardableResult
    mutating func record(sequence: UInt64, error: ValidationError?) -> Bool {
        guard sequence >= self.sequence else { return false }
        self.sequence = sequence
        self.error = error
        return true
    }
}

/// A save belongs to the store, not to the editor sheet. A finite system lease
/// lets queued disk work finish when the user backgrounds or dismisses the UI.
/// Expiry ends the lease; it never cancels a partially committed SQLite write.
@MainActor
final class MobilePersistenceBackgroundLease {
    private var identifier: UIBackgroundTaskIdentifier = .invalid

    init() {
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Saving Finances") { [weak self] in
            Task { @MainActor in self?.end() }
        }
    }

    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}
