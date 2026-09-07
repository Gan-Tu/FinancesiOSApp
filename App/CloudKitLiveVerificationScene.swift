import Foundation
import SwiftUI
import UIKit

/// An explicitly selected QA scene. It never creates the normal mobile store.
@MainActor
struct CloudKitLiveVerificationScene: View {
    @State private var started = false
    @State private var phase = "Preparing isolated verification"
    @State private var resultStatus: String?
    @State private var reportJSON = ""
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var pushLifecycle = MobilePushVerificationLifecycle()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text(CloudKitPeerVerification.isRequested ? "CloudKit Peer Verification" : "CloudKit Live Verification").font(.title2.bold())
                    Text(CloudKitPeerVerification.isRequested
                         ? "Synthetic Development data only. Peer phases retain the shared QA zone until the producer explicitly cleans it up."
                         : "Synthetic data only. This run uses a fresh Development QA zone and three temporary journals, then removes the QA cloud resources.")
                        .foregroundStyle(.secondary)
                    if let resultStatus {
                        Label(resultStatus, systemImage: resultStatus == "PASS" ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.headline)
                            .foregroundStyle(resultStatus == "PASS" ? Color.green : Color.red)
                        Text(reportJSON).font(.system(.caption, design: .monospaced)).textSelection(.enabled)
                    } else {
                        ProgressView(phase)
                    }
                    Text("Physical multi-device and push delivery checks are reported separately.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding()
            }
            .task {
                guard !started else { return }
                started = true
                #if targetEnvironment(simulator)
                let platform = "iOS Simulator"
                #else
                let platform = "iOS device"
                #endif
                let lifecycle = pushLifecycle
                let makeStore: CloudKitLiveVerification.StoreFactory = { url, initial, dependencies in
                    MobileLiveVerificationStore(MobileLedgerStore(
                        supportDirectory: url.deletingLastPathComponent(), initialData: initial,
                        cloudKitSyncDependencies: dependencies
                    ), pushLifecycle: lifecycle)
                }
                let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
                if CloudKitPeerVerification.isRequested {
                    let result = await CloudKitPeerVerification.run(platform: platform, makeStore: makeStore, onScenario: { name in
                        phase = name.replacingOccurrences(of: "-", with: " ")
                    })
                    reportJSON = (try? encoder.encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"status\":\"FAIL\"}"
                    resultStatus = result.status
                } else {
                    let result = await CloudKitLiveVerification.run(platform: platform, makeStore: makeStore, onScenario: { name in
                        phase = name.replacingOccurrences(of: "-", with: " ")
                    })
                    reportJSON = (try? encoder.encode(result)).map { String(decoding: $0, as: UTF8.self) } ?? "{\"status\":\"FAIL\"}"
                    resultStatus = result.status
                }
                print(reportJSON)
            }
            .onChange(of: scenePhase, initial: true) {
                pushLifecycle.setActive(scenePhase == .active)
            }
            .onDisappear { pushLifecycle.setActive(false) }
        }
    }
}

@MainActor
private final class MobileLiveVerificationStore: CloudKitLiveVerificationStore {
    private let store: MobileLedgerStore
    private weak var pushLifecycle: MobilePushVerificationLifecycle?
    private let automaticSceneID = UUID()
    init(_ store: MobileLedgerStore, pushLifecycle: MobilePushVerificationLifecycle) {
        self.store = store
        self.pushLifecycle = pushLifecycle
    }
    var automaticPushExecutionContext: CloudKitPeerPushExecutionContext { .currentIOS }
    func startAutomaticPushVerification() throws {
        guard let pushLifecycle else { throw CloudKitSyncError.unavailable("The isolated QA scene is no longer available.") }
        pushLifecycle.attach(self)
        UIApplication.shared.registerForRemoteNotifications()
    }
    func handleAutomaticPushNotification() async -> CloudKitBackgroundRefreshOutcome {
        await store.synchronizeFromNotification(isForeground: UIApplication.shared.applicationState == .active)
    }
    func stopAutomaticPushVerification() {
        store.setSceneActive(false, sceneID: automaticSceneID)
        store.setSyncEnabled(false)
        pushLifecycle?.detach(self)
    }
    func setAutomaticSceneActive(_ active: Bool) {
        store.setSceneActive(active, sceneID: automaticSceneID)
    }
    var data: JournalData { store.data }
    var validationError: ValidationError? { get { store.validationError } set { store.validationError = newValue } }
    var requiresJournalRecovery: Bool { store.requiresJournalRecovery }
    var cloudSyncProgress: CloudSyncProgress { store.cloudSyncProgress }
    var cloudKitSQLiteStore: SQLiteJournalStore { store.cloudKitSQLiteStore }
    func setSyncEnabled(_ enabled: Bool) { store.setSyncEnabled(enabled) }
    func requestCloudKitSync(reportProgress: Bool, requireFollowUpIfBusy: Bool) { store.requestCloudKitSync(reportProgress: reportProgress, requireFollowUpIfBusy: requireFollowUpIfBusy) }
    func waitForCloudKitSyncIdle() async { await store.waitForCloudKitSyncIdle() }
    func cloudKitSyncConflicts() -> [CloudKitSyncConflict] { store.cloudKitSyncConflicts() }
    func resolveCloudKitSyncConflict(id: String, keepLocal: Bool) { store.resolveCloudKitSyncConflict(id: id, keepLocal: keepLocal) }
    func balance(for accountID: UUID) -> Decimal { store.balanceRows(for: accountID).reduce(.zero) { $0 + $1.amount } }
    func draft(for transaction: LedgerTransaction) -> TransactionDraft { store.draft(for: transaction) }
    func saveTransaction(_ draft: TransactionDraft) { store.saveTransactionAndFlush(draft) }
    func saveTransactionForFutureOccurrences(_ draft: TransactionDraft) { store.saveTransactionAndFlush(draft, scope: .future) }
    func deleteTransaction(_ id: UUID) { store.deleteTransaction(id) }
    func importAttachment(from url: URL) throws -> AttachmentAsset { try store.importAttachment(from: url) }
    func cloudKitAttachmentURL(for asset: AttachmentAsset) throws -> URL { try store.cloudKitAttachmentURL(for: asset) }
    func liveIntegrityIsValid() -> Bool {
        do {
            try store.cloudKitValidate(store.data)
            for asset in store.data.transactions.flatMap({ $0.attachment?.assets ?? [] }) {
                guard FileManager.default.fileExists(atPath: try store.cloudKitAttachmentURL(for: asset).path) else { return false }
            }
            return true
        } catch { return false }
    }
}

/// Only the explicit QA scene owns this lifecycle; the normal app store is never attached.
@MainActor
private final class MobilePushVerificationLifecycle: ObservableObject {
    private weak var adapter: MobileLiveVerificationStore?
    private var isActive = false
    func attach(_ adapter: MobileLiveVerificationStore) {
        self.adapter = adapter
        adapter.setAutomaticSceneActive(isActive)
    }
    func detach(_ adapter: MobileLiveVerificationStore) {
        if self.adapter === adapter { self.adapter = nil }
    }
    func setActive(_ active: Bool) {
        isActive = active
        adapter?.setAutomaticSceneActive(active)
    }
}

@MainActor
extension CloudKitPeerPushExecutionContext {
    static var currentIOS: Self {
        switch UIApplication.shared.applicationState {
        case .active: return .foreground
        case .background: return .background
        case .inactive: return .inactive
        @unknown default: return .unknown
        }
    }
}
