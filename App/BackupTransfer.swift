import SwiftUI
import UIKit
import BackgroundTasks
import OSLog

struct SharedBackupFile: Identifiable {
    let url: URL
    var id: URL { url }
}

/// Owns preparation independently of the Backup screen's presentation lifetime.
@MainActor
final class MobileBackupController: ObservableObject {
    static let shared = MobileBackupController()
    private static let logger = Logger(subsystem: "dev.gan.FinancesApp.iOS", category: "Backup")
    @Published private(set) var isRunning = false
    @Published private(set) var fraction = 0.0
    @Published private(set) var title = ""
    @Published private(set) var canCancel = true
    @Published private(set) var readyFile: SharedBackupFile?
    @Published var statusMessage: String?
    var shouldPresentShare = false

    private enum Outcome { case file(URL), message(String) }
    private var pending: ((Progress) async throws -> Outcome)?
    private var worker: Task<Void, Never>?
    private var monitor: Task<Void, Never>?
    private var progress = Progress(totalUnitCount: 1)
    private var jobID: UUID?
    private var nativeTask: BGTask?
    private var legacyTask: UIBackgroundTaskIdentifier = .invalid

    func export(using store: MobileLedgerStore) {
        store.validationError = nil
        start(title: "Exporting Backup") { progress in
            .file(try await store.exportBackupFileAsync(progress: progress))
        }
    }

    func restore(from url: URL, using store: MobileLedgerStore) {
        store.validationError = nil
        start(title: "Importing Backup") { progress in
            try await store.importBackupAsync(from: url, progress: progress)
            return .message("Backup imported. iCloud Sync is off until you enable it again.")
        }
    }

    func importOriginal(from url: URL, using store: MobileLedgerStore) {
        store.validationError = nil
        start(title: "Importing Database", canCancel: false) { progress in
            guard let result = await store.importOriginalFinancesDatabaseAsync(at: url) else {
                let error = store.validationError ?? ValidationError(message: "The database could not be imported.")
                store.validationError = nil
                throw error
            }
            progress.completedUnitCount = progress.totalUnitCount
            return .message("Imported \(result.ledgerCount) journals and \(result.transactionCount) transactions. \(result.attachmentSummary.copiedAttachments) attachments copied; \(result.attachmentSummary.missingAttachments) missing. iCloud Sync is off until you enable it again.")
        }
    }

    func loadPreparedBackup(using store: MobileLedgerStore) {
        if readyFile == nil, let url = store.latestExportedBackup() { readyFile = SharedBackupFile(url: url) }
    }

    func cancel() { if canCancel { progress.cancel() } }

    private func start(title: String, canCancel: Bool = true, operation: @escaping (Progress) async throws -> Outcome) {
        guard !isRunning else { return }
        let id = UUID()
        jobID = id; isRunning = true; fraction = 0; self.title = title
        self.canCancel = canCancel
        statusMessage = nil; shouldPresentShare = false
        progress = Progress(totalUnitCount: 1)
        pending = operation
        if #available(iOS 26.0, *), canCancel {
            let identifier = (Bundle.main.bundleIdentifier ?? "dev.gan.FinancesApp.iOS") + ".backup." + id.uuidString
            // Continued-processing tasks support registration at user initiation.
            // A unique identifier keeps late callbacks separate from a later job.
            let registered = BGTaskScheduler.shared.register(forTaskWithIdentifier: identifier, using: .main) { [weak self] task in
                MainActor.assumeIsolated {
                    guard let self, self.jobID == id, self.isRunning,
                          let continued = task as? BGContinuedProcessingTask else {
                        task.setTaskCompleted(success: false)
                        return
                    }
                    self.nativeTask = continued
                    Self.logger.info("Starting continued backup processing")
                    continued.progress.totalUnitCount = 1000
                    let progress = self.progress
                    continued.expirationHandler = { progress.cancel() }
                    self.run(id)
                }
            }
            if registered {
                let request = BGContinuedProcessingTaskRequest(identifier: identifier, title: title, subtitle: "Preparing your Finances data")
                request.strategy = .fail
                do { try BGTaskScheduler.shared.submit(request); return }
                catch { /* Older devices/Simulator can use the finite task lease. */ }
            }
        }
        let progress = progress
        Self.logger.info("Starting backup with a finite background lease")
        legacyTask = UIApplication.shared.beginBackgroundTask(withName: title) { progress.cancel() }
        run(id)
    }

    private func run(_ id: UUID) {
        guard worker == nil, let operation = pending, jobID == id else { return }
        pending = nil
        let progress = progress
        monitor = Task { [weak self] in
            var reportedBackgroundProgress = false
            while !Task.isCancelled {
                guard let self, self.jobID == id else { return }
                self.fraction = min(0.99, max(0, progress.fractionCompleted))
                if !reportedBackgroundProgress, UIApplication.shared.applicationState == .background {
                    reportedBackgroundProgress = true
                    Self.logger.info("Backup is continuing in the background at \(self.fraction, privacy: .public)")
                }
                if #available(iOS 26.0, *), let continued = self.nativeTask as? BGContinuedProcessingTask {
                    continued.progress.completedUnitCount = Int64(self.fraction * 1000)
                }
                do { try await Task.sleep(for: .milliseconds(200)) } catch { return }
            }
        }
        worker = Task { [self] in
            var success = false
            do {
                let outcome = try await operation(progress)
                switch outcome {
                case .file(let url):
                    readyFile = SharedBackupFile(url: url)
                    shouldPresentShare = true
                case .message(let message): statusMessage = message
                }
                fraction = 1; success = true
            } catch {
                statusMessage = progress.isCancelled || error is CancellationError
                    ? "Backup preparation was stopped. Your journal is unchanged. You can try again when the app is active."
                    : "Backup failed: \(error.localizedDescription)"
            }
            monitor?.cancel(); monitor = nil
            if #available(iOS 26.0, *), let continued = nativeTask as? BGContinuedProcessingTask, success {
                continued.progress.completedUnitCount = continued.progress.totalUnitCount
            }
            nativeTask?.setTaskCompleted(success: success); nativeTask = nil
            Self.logger.info("Backup operation finished, success: \(success)")
            if legacyTask != .invalid { UIApplication.shared.endBackgroundTask(legacyTask); legacyTask = .invalid }
            pending = nil; worker = nil; jobID = nil; isRunning = false
        }
    }
}

struct BackupShareSheet: UIViewControllerRepresentable {
    let url: URL
    let completion: @MainActor (Bool, Error?) -> Void

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        controller.view.accessibilityIdentifier = "backup-share-sheet"
        if let popover = controller.popoverPresentationController {
            popover.sourceView = controller.view
            popover.sourceRect = CGRect(x: 0, y: 0, width: 1, height: 1)
            popover.permittedArrowDirections = []
        }
        controller.completionWithItemsHandler = { _, completed, _, error in
            Task { @MainActor in completion(completed, error) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
