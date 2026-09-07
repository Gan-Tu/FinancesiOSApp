import CloudKit
import Foundation

enum CloudKitPeerPushExecutionContext: String, Codable, Sendable {
    case foreground, background, inactive, headless, unknown
}

struct CloudKitPeerPushEnvelope: Sendable {
    var containerIdentifier: String?
    var zoneName: String?
    var subscriptionID: String?
    var isPrivateZone: Bool
    var executionContext: CloudKitPeerPushExecutionContext = .unknown
}

struct CloudKitPeerPushEvidence: Codable, Equatable, Sendable {
    var registrationSucceeded = false
    var registrationFailed = false
    var ready = false
    var matchingNotificationCount = 0
    var matchingDeliveryContexts: [CloudKitPeerPushExecutionContext] = []
}

enum CloudKitPeerPushError: Error { case invalidScope, alreadyArmed, inactive, registrationRequired }

/// One explicit peer QA attempt observes real delegate delivery. This relay does
/// not fetch records itself or claim that a particular hint caused convergence.
@MainActor
enum CloudKitPeerPushRelay {
    private struct Session {
        let id: UUID
        let container: String
        let zone: String
        let subscription: String
        let onNotification: @MainActor @Sendable () async -> CloudKitBackgroundRefreshOutcome
        var evidence = CloudKitPeerPushEvidence()
    }
    private static var session: Session?
    static var isArmed: Bool { session != nil }
    static var readySessionID: UUID? { session?.evidence.ready == true ? session?.id : nil }

    static func begin(request: CloudKitPeerVerification.Request, configuration: CloudKitSyncConfiguration,
                      onNotification: @escaping @MainActor @Sendable () async -> CloudKitBackgroundRefreshOutcome) throws -> UUID {
        guard request.phase == .awaitPush,
              configuration.containerIdentifier == "iCloud.dev.gan.FinanceApp", configuration.environment == "Development",
              configuration.zoneName == request.zoneName else { throw CloudKitPeerPushError.invalidScope }
        guard session == nil else { throw CloudKitPeerPushError.alreadyArmed }
        let id = UUID()
        session = Session(id: id, container: configuration.containerIdentifier, zone: request.zoneName,
                          subscription: "Finances-\(request.zoneName)-changes-v1", onNotification: onNotification)
        return id
    }

    static func registrationSucceeded() {
        guard session != nil else { return }
        session?.evidence.registrationSucceeded = true
        session?.evidence.registrationFailed = false
    }
    static func registrationFailed() {
        guard session?.evidence.registrationSucceeded != true else { return }
        session?.evidence.registrationFailed = true
    }
    static func markReady(sessionID: UUID) throws {
        guard session?.id == sessionID else { throw CloudKitPeerPushError.inactive }
        guard session?.evidence.registrationSucceeded == true else { throw CloudKitPeerPushError.registrationRequired }
        guard session?.evidence.ready != true else { return }
        session?.evidence.ready = true
        session?.evidence.matchingNotificationCount = 0
    }
    static func snapshot(sessionID: UUID) throws -> CloudKitPeerPushEvidence {
        guard let current = session, current.id == sessionID else { throw CloudKitPeerPushError.inactive }
        return current.evidence
    }
    static func end(sessionID: UUID) {
        guard session?.id == sessionID else { return }
        // Retire evidence/dispatch ownership before the caller stops its store.
        session = nil
    }
    static func receive(_ notification: CKNotification, executionContext: CloudKitPeerPushExecutionContext = .unknown, expectedSessionID: UUID? = nil) async -> CloudKitBackgroundRefreshOutcome? {
        guard let receivedSessionID = expectedSessionID ?? readySessionID else { return nil }
        let zone = notification as? CKRecordZoneNotification
        return await receive(CloudKitPeerPushEnvelope(containerIdentifier: notification.containerIdentifier,
            zoneName: zone?.recordZoneID?.zoneName, subscriptionID: notification.subscriptionID,
            isPrivateZone: zone?.databaseScope == .private, executionContext: executionContext), expectedSessionID: receivedSessionID)
    }
    /// Offline seam uses the same field checks as the native delegate path.
    static func receive(_ envelope: CloudKitPeerPushEnvelope, expectedSessionID: UUID? = nil) async -> CloudKitBackgroundRefreshOutcome? {
        guard let current = session, current.evidence.ready,
              expectedSessionID == nil || expectedSessionID == current.id,
              envelope.isPrivateZone, envelope.containerIdentifier == current.container,
              envelope.zoneName == current.zone, envelope.subscriptionID == current.subscription else { return nil }
        session?.evidence.matchingNotificationCount += 1
        if session?.evidence.matchingDeliveryContexts.contains(envelope.executionContext) != true {
            session?.evidence.matchingDeliveryContexts.append(envelope.executionContext)
        }
        let outcome = await current.onNotification()
        guard session?.id == current.id else { return .noData }
        return outcome
    }
}
