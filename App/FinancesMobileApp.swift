import SwiftUI
import UIKit
import CloudKit

@main
@MainActor
struct FinancesMobileApp: App {
    @UIApplicationDelegateAdaptor(FinancesMobileAppDelegate.self) private var appDelegate
    @StateObject private var launchState: FinancesMobileLaunchState

    init() {
        let state = FinancesMobileLaunchState(liveVerification: CloudKitLiveVerification.isRequested)
        _launchState = StateObject(wrappedValue: state)
        appDelegate.store = state.store
    }

    var body: some Scene {
        WindowGroup {
            if launchState.liveVerification {
                CloudKitLiveVerificationScene()
            } else if let store = launchState.store {
                FinancesMobileNormalContent(store: store)
            }
        }
    }
}

/// QA selection is resolved before any normal storage path is opened.
@MainActor
private final class FinancesMobileLaunchState: ObservableObject {
    let liveVerification: Bool
    let store: MobileLedgerStore?
    init(liveVerification: Bool) {
        self.liveVerification = liveVerification
        #if DEBUG
        if CommandLine.arguments.contains("--demo") { store = DemoData.makeStore() }
        else { store = liveVerification ? nil : MobileLedgerStore() }
        #else
        store = liveVerification ? nil : MobileLedgerStore()
        #endif
        // Register before scene rendering so a cold silent-push launch can
        // refresh the badge too. Permission is requested only in an active scene.
        if !CommandLine.arguments.contains("--demo"),
           ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            store?.enableAppIconBadges()
        }
    }
}

@MainActor
private struct FinancesMobileNormalContent: View {
    @ObservedObject var store: MobileLedgerStore
    var body: some View {
        AppShellView()
            .environmentObject(store)
            .preferredColorScheme(store.data.appearance.colorScheme)
            .task { await store.prepareAfterInitialRender() }
            .onReceive(NotificationCenter.default.publisher(for: .NSCalendarDayChanged)) { _ in
                store.refreshAppIconBadge()
            }
            .onReceive(NotificationCenter.default.publisher(for: UIApplication.significantTimeChangeNotification)) { _ in
                store.refreshAppIconBadge()
            }
    }
}

@MainActor
final class FinancesMobileAppDelegate: NSObject, UIApplicationDelegate {
    weak var store: MobileLedgerStore?

    func application(_ application: UIApplication, didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data) {
        // QA records only callback success; device tokens never enter its evidence.
        if CloudKitLiveVerification.isRequested { CloudKitPeerPushRelay.registrationSucceeded() }
    }

    func application(_ application: UIApplication, didFailToRegisterForRemoteNotificationsWithError error: Error) {
        if CloudKitLiveVerification.isRequested { CloudKitPeerPushRelay.registrationFailed() }
    }

    func application(
        _ application: UIApplication,
        didReceiveRemoteNotification userInfo: [AnyHashable: Any]
    ) async -> UIBackgroundFetchResult {
        // Explicit QA has no normal store. The armed relay binds only its
        // isolated Development run and rejects unrelated or late notifications.
        if CloudKitLiveVerification.isRequested {
            guard let payload = userInfo as? [String: Any],
                  let notification = CKNotification(fromRemoteNotificationDictionary: payload),
                  let session = CloudKitPeerPushRelay.readySessionID,
                  let outcome = await CloudKitPeerPushRelay.receive(notification, executionContext: .currentIOS, expectedSessionID: session) else { return .noData }
            switch outcome {
            case .newData: return .newData
            case .noData: return .noData
            case .failed: return .failed
            }
        }
        guard let store, store.data.syncEnabled,
              let configuration = CloudKitSyncConfiguration.availableConfiguration(),
              let payload = userInfo as? [String: Any],
              let notification = CKNotification(fromRemoteNotificationDictionary: payload),
              notification.containerIdentifier == configuration.containerIdentifier else { return .noData }
        switch await store.synchronizeFromNotification(isForeground: application.applicationState == .active) {
        case .newData: return .newData
        case .noData: return .noData
        case .failed: return .failed
        }
    }
}
