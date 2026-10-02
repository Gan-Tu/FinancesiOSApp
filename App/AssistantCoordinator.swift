import Foundation
import Combine
import CloudKit
import UIKit
import os

final class AssistantNotificationTokens {
    var values: [NSObjectProtocol] = []
    deinit { values.forEach(NotificationCenter.default.removeObserver) }
}

/// The composer's text lives apart from the coordinator. A keystroke then
/// re-renders only the input row, not the Markdown transcript above it or the
/// navigation shell behind the sheet.
@MainActor
final class AssistantComposerDraft: ObservableObject {
    @Published var text = ""
}

/// Best-effort execution after the scene leaves the foreground. iOS grants a
/// short lease; when it ends, the conversation checkpoints and pauses, and the
/// user resumes it on return.
@MainActor
protocol AssistantBackgroundLeasing: AnyObject {
    /// Returns false when the system refuses background time.
    func begin(onExpiration: @escaping @MainActor @Sendable () -> Void) -> Bool
    func end()
}

@MainActor
final class AssistantSystemBackgroundLease: AssistantBackgroundLeasing {
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    func begin(onExpiration: @escaping @MainActor @Sendable () -> Void) -> Bool {
        guard identifier == .invalid else { return true }
        identifier = UIApplication.shared.beginBackgroundTask(withName: "Ask Finances") { [weak self] in
            // UIKit calls this on the main thread shortly before the allowance
            // ends. Checkpoint first, then give the lease back before returning.
            MainActor.assumeIsolated {
                guard let self, self.identifier != .invalid else { return }
                onExpiration()
                self.end()
            }
        }
        return identifier != .invalid
    }
    func end() {
        guard identifier != .invalid else { return }
        let current = identifier
        identifier = .invalid
        UIApplication.shared.endBackgroundTask(current)
    }
}

@MainActor
final class AssistantCoordinator: ObservableObject {
    @Published var conversation = AssistantConversation()
    @Published var history: [AssistantConversation] = []
    @Published var isRunning = false
    @Published var isConnecting = false
    @Published var connected = false
    @Published var error: String?
    @Published var activity = ""
    @Published var streamingText = ""
    @Published var approval: AssistantToolCall?
    @Published var approvalText = ""
    private var approvalFingerprint = ""
    @Published var filePurpose: String?
    @Published var artifact: URL?
    @Published var navigationRequest: AssistantJSON?
    @Published var uploadedFiles: [AssistantJSON] = []
    @Published private(set) var awaitingAttachmentActivation = false
    private var pendingAttachment: (AssistantAttachmentContext, @MainActor () async throws -> [AssistantAttachmentInput])?
    @Published var needsAttachmentRecovery = false
    @Published var modelChoices: [AssistantModelChoice] = []
    @Published var consented: Bool
    let store: MobileLedgerStore
    let gateway: any AssistantGatewayProtocol
    let contract: AssistantContract
    let dictation: AssistantDictation
    let draft = AssistantComposerDraft()
    /// Compatibility accessor; views bind to `draft` directly so typing never
    /// publishes through this object.
    var draftText: String {
        get { draft.text }
        set { draft.text = newValue }
    }
    private var dictationObservation: AnyCancellable?
    private var dictationStateObservation: AnyCancellable?
    let preferences: AssistantPreferencesStore?
    private(set) var identity = ""
    private(set) var tools: AssistantTools?
    private var foreground = false
    private var presented = false
    /// System background time or an inactive scene (notification shade,
    /// permission prompt) keeps in-flight work running on a best-effort basis.
    var backgroundLease: any AssistantBackgroundLeasing = AssistantSystemBackgroundLease()
    private var continuesWhileAway = false
    private var holdsBackgroundLease = false
    /// One serial writer for conversation checkpoints. The run loop awaits its
    /// writes so the main actor stays free; immediate user actions join the
    /// same queue so no write lands behind an older one.
    private static let historyQueue = DispatchQueue(label: "FinancesMobile.Assistant.history", qos: .userInitiated)
    /// Streamed tokens are published in small batches rather than one by one.
    private var pendingStreamingText = ""
    private var streamingFlushTask: Task<Void, Never>?
    private var restoreRecentOnConnect = false
    private let now: () -> Date
    private var task: Task<Void, Never>?
    // New work waits for a cancelled worker to finish before reconciling its
    // action receipts. Cancellation alone does not prove a save rolled back.
    private var retiringTask: Task<Void, Never>?
    private var generation = UUID()
    private let observations = AssistantNotificationTokens()
    private var fileContinuation: CheckedContinuation<[URL], Error>?
    private let logger = Logger(subsystem: "dev.gan.FinancesApp.iOS", category: "Assistant")

    init(store: MobileLedgerStore, gateway: (any AssistantGatewayProtocol)? = nil, contract: AssistantContract? = nil, preferences: AssistantPreferencesStore? = nil, recorder: (any AssistantAudioRecording)? = nil, now: @escaping () -> Date = Date.init) {
        self.store = store
        self.now = now
        self.preferences = preferences
        self.gateway = gateway ?? (AIInferencePolicy.blocksNetwork ? AssistantMockGateway() : AssistantGateway())
        self.contract = contract ?? (try? AssistantContract.load()) ?? AssistantContract(version: 1, tools: [])
        dictation = AssistantDictation(recorder: recorder ?? (AIInferencePolicy.usesIsolatedSample ? AssistantMockAudioRecorder() : AssistantAudioRecorder()))
        consented = UserDefaults.standard.bool(forKey: "assistant.cloudConsent.v1")
        observations.values.append(NotificationCenter.default.addObserver(forName: .CKAccountChanged, object: nil, queue: .main) { [weak self] _ in
            Task { @MainActor in self?.invalidateIdentity() }
        })
        dictation.onTranscript = { [weak self] text in
            guard let self else { return }
            let separator = self.draftText.isEmpty || self.draftText.last?.isWhitespace == true ? "" : " "
            self.draftText += separator + text
        }
        dictationObservation = dictation.objectWillChange.sink { [weak self] in self?.objectWillChange.send() }
        // A transcription that finishes while the scene is away returns its lease.
        dictationStateObservation = dictation.$state.sink { [weak self] state in
            guard let self, state == .idle || state == .failed, !self.isRunning, !self.isConnecting else { return }
            self.finishAwayWork()
        }
    }

    func setForeground(_ active: Bool, isBackground: Bool = true) {
        if foreground && !active && presented { conversation.lastActiveAt = now() }
        foreground = active
        if active {
            releaseBackgroundLease()
            continuesWhileAway = false
            dictation.activateIfPermitted()
            finishPendingAttachment()
            if let preferences { Task { await preferences.refresh() } }
            return
        }
        // Away from the foreground. Finish in-flight work on a best-effort
        // basis instead of pausing at once: an inactive scene (notification
        // shade, system prompt) keeps full execution, and the background runs
        // on a system lease that checkpoints the conversation when it ends.
        // The microphone cannot keep recording in the background.
        if isBackground, dictation.state == .recording { dictation.cancel() }
        let busy = isRunning || isConnecting || dictation.state == .transcribing
        guard busy, presented, !store.requiresUnlock else {
            if isBackground { pause() }
            return
        }
        continuesWhileAway = true
        guard isBackground, !holdsBackgroundLease else { return }
        holdsBackgroundLease = backgroundLease.begin { [weak self] in self?.backgroundLeaseExpired() }
        if !holdsBackgroundLease { continuesWhileAway = false; pause() }
    }
    private func backgroundLeaseExpired() {
        guard holdsBackgroundLease else { return }
        holdsBackgroundLease = false
        continuesWhileAway = false
        pause()
    }
    private func releaseBackgroundLease() {
        guard holdsBackgroundLease else { return }
        holdsBackgroundLease = false
        backgroundLease.end()
    }
    /// Work that finishes while the scene is away gives its lease back at once.
    private func finishAwayWork() {
        guard !foreground else { return }
        continuesWhileAway = false
        releaseBackgroundLease()
    }
    func lockChanged() { if store.requiresUnlock { pause() } else { finishPendingAttachment() } }
    private func finishPendingAttachment() {
        guard foreground, !store.requiresUnlock, let (context, load) = pendingAttachment else { return }
        pendingAttachment = nil; awaitingAttachmentActivation = false
        attach(context: context, load: load)
    }
    func acceptConsent() {
        consented = true; UserDefaults.standard.set(true, forKey: "assistant.cloudConsent.v1")
        prepare()
    }
    func present() {
        presented = true
        if tools != nil { tools?.context = conversation.context }
        if consented { prepare() }
    }
    func dismiss() {
        if presented && foreground { conversation.lastActiveAt = now() }
        presented = false; pendingAttachment = nil; awaitingAttachmentActivation = false; pause()
    }
    func requireActive() throws {
        guard foreground || continuesWhileAway, presented, !store.requiresUnlock else { throw CancellationError() }
        try store.assistantRequireAccess()
    }
    func invalidateIdentity() {
        pause(); tools?.clearPreviews(); connected = false; identity = ""; tools = nil
        pendingAttachment = nil; awaitingAttachmentActivation = false
        history = []; conversation = AssistantConversation(); draftText = ""; uploadedFiles = []; artifact = nil; restoreRecentOnConnect = false
        error = "Your iCloud account changed. Reopen the assistant after Finances refreshes its account."
    }
    private func verifyIdentity(_ subject: String) throws {
        if AIInferencePolicy.blocksNetwork, subject == "local-developer", AIInferencePolicy.usesIsolatedSample { return }
        guard let binding = try store.assistantDatabase.assistantBoundIdentity() else { throw AssistantFailure("unbound_journal", "Finish the initial iCloud connection before using the assistant.") }
        let fields = binding.context.split(separator: "|")
        guard fields.count >= 2, subject == "cloudkit:\(fields[0]):\(fields[1].lowercased()):\(binding.account)" else { throw AssistantFailure("identity_mismatch", "The signed-in account does not own this local journal. Existing data is preserved.") }
    }
    // Opening chat uses the journal's local account binding. Network identity
    // verification remains mandatory at the start of every submitted operation.
    func prepare() {
        guard consented, !isConnecting, !isRunning else { return }
        error = nil
        do {
            try requireActive()
            let subject: String
            if AIInferencePolicy.blocksNetwork && AIInferencePolicy.usesIsolatedSample {
                subject = "local-developer"
            } else {
                guard let binding = try store.assistantDatabase.assistantBoundIdentity() else {
                    throw AssistantFailure("unbound_journal", "Finish the initial iCloud connection before using the assistant.")
                }
                let fields = binding.context.split(separator: "|")
                guard fields.count >= 2 else { throw AssistantFailure("unbound_journal", "The journal account binding is invalid.") }
                subject = "cloudkit:\(fields[0]):\(fields[1].lowercased()):\(binding.account)"
            }
            try installIdentity(subject)
            modelChoices = contract.models ?? AssistantSettings.models
            connected = true
        } catch { self.error = error.localizedDescription; connected = false }
    }
    private func validateServerOptions() async throws {
        guard contract.tools.count == 45 else { throw AssistantFailure("contract_missing", "This build is missing the finance tool contract.") }
        let options = try await gateway.options()
        guard options["version"].int == contract.version else { throw AssistantFailure("contract_version", "Update Finances to match the assistant service.") }
        modelChoices = try JSONDecoder().decode([AssistantModelChoice].self, from: options["models"].encoded())
    }
    private func installIdentity(_ subject: String) throws {
        try verifyIdentity(subject)
        guard identity != subject else { return }
        tools?.clearPreviews()
        let saved = try store.assistantDatabase.assistantHistory(scope: subject)
        let loaded = try saved.map { try JSONDecoder().decode(AssistantConversation.self, from: $0) }
        identity = subject; history = loaded
        conversation.settings = preferences?.settings(for: subject) ?? history.first?.settings ?? AssistantSettings()
        if let preferences { Task { await preferences.refresh() } }
        tools = AssistantTools(store: store, scope: subject, context: conversation.context, contract: contract)
        tools?.receiptPreferences = { (PaymentMetadataStore.shared.metadata, ReceiptPreferencesStore.shared.settings.instructions) }
        configureTools()
        if restoreRecentOnConnect {
            restoreRecentOnConnect = false
            if let recent = history.max(by: { ($0.lastActiveAt ?? $0.updated) < ($1.lastActiveAt ?? $1.updated) }), isRecent(recent) {
                restoreConversation(recent)
            }
        }
    }
    private func configureTools() {
        tools?.requireActive = { [weak self] in guard let self else { throw CancellationError() }; try self.requireActive() }
        tools?.conversationTitle = { [weak self] in
            guard let self else { throw CancellationError() }
            try self.requireActive()
            return .object(["conversation_id": .string(self.conversation.id.uuidString), "title": .string(self.conversation.title)])
        }
        tools?.renameConversation = { [weak self] call, title in
            guard let self else { throw CancellationError() }
            return try self.renameConversation(self.conversation.id, title: title, action: call)
        }
        tools?.selectFiles = { [weak self] purpose in
            guard let self else { throw CancellationError() }
            return try await withCheckedThrowingContinuation { continuation in fileContinuation = continuation; filePurpose = purpose }
        }
        tools?.showArtifact = { [weak self] url in self?.artifact = url }
        tools?.openView = { [weak self] destination in self?.navigationRequest = destination }
        tools?.readForModel = { [weak self] _, _, url in
            guard let self, let tools else { throw CancellationError() }
            let staged = try tools.stage(url), fileID = try staged.required("file_id")
            let uploaded = try await gateway.upload(url: tools.stagedFile(fileID), fileID: fileID)
            return .object(["chat_attachment_id": uploaded["id"], "file_id": .string(fileID), "filename": uploaded["filename"]])
        }
    }
    func persist() throws {
        try persist(conversation)
    }
    private func persist(_ value: AssistantConversation) throws {
        guard !identity.isEmpty else { throw AssistantFailure("not_connected", "Connect before saving assistant history.") }
        var saved = value; saved.updated = now()
        if presented && foreground { saved.lastActiveAt = saved.updated }
        let database = store.assistantDatabase, scope = identity, snapshot = saved
        try Self.historyQueue.sync {
            try database.saveAssistantHistory(scope: scope, id: snapshot.id.uuidString, payload: JSONEncoder().encode(snapshot), now: snapshot.updated)
        }
        conversation = saved
        history.removeAll { $0.id == saved.id }; history.insert(saved, at: 0)
    }
    /// The run loop's durable checkpoint. State publishes at once so the
    /// transcript updates; encoding and the SQLite write run on the serial
    /// writer while the user keeps typing. The loop awaits the write before
    /// its next action, which keeps the durability order unchanged.
    private func persistAsync(_ value: AssistantConversation? = nil) async throws {
        guard !identity.isEmpty else { throw AssistantFailure("not_connected", "Connect before saving assistant history.") }
        var saved = value ?? conversation; saved.updated = now()
        if presented && foreground { saved.lastActiveAt = saved.updated }
        conversation = saved
        history.removeAll { $0.id == saved.id }; history.insert(saved, at: 0)
        let database = store.assistantDatabase, scope = identity, snapshot = saved
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            Self.historyQueue.async {
                do {
                    try database.saveAssistantHistory(scope: scope, id: snapshot.id.uuidString, payload: JSONEncoder().encode(snapshot), now: snapshot.updated)
                    continuation.resume()
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
    private func setActivity(_ value: String) {
        if activity != value { activity = value }
    }
    private func appendStreamingText(_ text: String) {
        pendingStreamingText += text
        guard streamingFlushTask == nil else { return }
        streamingFlushTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(60))
            self?.flushStreamingText()
        }
    }
    private func flushStreamingText() {
        streamingFlushTask?.cancel(); streamingFlushTask = nil
        guard !pendingStreamingText.isEmpty else { return }
        streamingText += pendingStreamingText
        pendingStreamingText = ""
    }
    private func clearStreamingText() {
        streamingFlushTask?.cancel(); streamingFlushTask = nil
        pendingStreamingText = ""
        if !streamingText.isEmpty { streamingText = "" }
    }
    private func isRecent(_ value: AssistantConversation) -> Bool {
        let elapsed = now().timeIntervalSince(value.lastActiveAt ?? value.updated)
        return elapsed >= 0 && elapsed <= 10 * 60
    }
    /// Only the launcher checks expiry; auxiliary sheets must never reset chat.
    func openConversation(context: AssistantContext) throws {
        if !identity.isEmpty && isRecent(conversation) && history.contains(where: { $0.id == conversation.id }) {
            tools?.context = conversation.context
            return
        }
        try beginFreshConversation(context: context)
        restoreRecentOnConnect = identity.isEmpty
    }
    func beginFreshConversation(context: AssistantContext) throws {
        try pauseAndCheckpoint()
        restoreRecentOnConnect = false
        let settings = preferences?.settings(for: identity) ?? conversation.settings
        tools?.clearPreviews()
        conversation = AssistantConversation(context: context, settings: settings)
        clearConversationPresentation()
        tools?.context = context
    }
    func newConversation() {
        do {
            try beginFreshConversation(context: conversation.context)
            // Explicit New Chat creates a history entry that can be named.
            if !identity.isEmpty { try persist() }
            if consented { prepare() }
        } catch { self.error = "Could not start a new conversation: \(error.localizedDescription)" }
    }
    private func clearConversationPresentation() {
        pendingAttachment = nil; awaitingAttachmentActivation = false
        uploadedFiles = []; error = nil; clearStreamingText(); artifact = nil
        approval = nil; approvalText = ""; approvalFingerprint = ""
        needsAttachmentRecovery = false; navigationRequest = nil; draftText = ""
    }
    func selectConversation(_ value: AssistantConversation) {
        pause(); tools?.clearPreviews()
        pendingAttachment = nil; awaitingAttachmentActivation = false
        restoreConversation(value)
    }
    private func restoreConversation(_ value: AssistantConversation) {
        conversation = value
        conversation.paused = value.hasPendingInference || !value.calls.isEmpty
        conversation.lastActiveAt = now()
        tools?.context = value.context; uploadedFiles = []; error = nil
        do {
            let database = store.assistantDatabase, scope = identity, snapshot = conversation
            try Self.historyQueue.sync {
                try database.saveAssistantHistory(scope: scope, id: value.id.uuidString, payload: JSONEncoder().encode(snapshot), now: value.updated)
            }
            if let index = history.firstIndex(where: { $0.id == value.id }) { history[index] = conversation }
        } catch { self.error = "Could not save the active conversation: \(error.localizedDescription)" }
    }
    func deleteConversation(_ id: UUID) {
        do {
            if conversation.id == id { cancelRemaining(); conversation = AssistantConversation(context: conversation.context) }
            let database = store.assistantDatabase, scope = identity
            try Self.historyQueue.sync { try database.deleteAssistantHistory(scope: scope, id: id.uuidString) }
            history.removeAll { $0.id == id }
        } catch { self.error = error.localizedDescription }
    }
    @discardableResult
    func renameConversation(_ id: UUID, title: String, action: AssistantToolCall? = nil) throws -> AssistantJSON {
        try requireActive()
        if let action, let replay = try store.assistantDatabase.assistantAction(scope: identity, id: action.operationID, digest: action.digest) {
            return try JSONDecoder().decode(AssistantJSON.self, from: Data(replay.utf8))
        }
        let name = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, name.count <= 80 else { throw AssistantFailure("invalid_title", "Use a conversation name between 1 and 80 characters.") }
        guard !identity.isEmpty, let index = history.firstIndex(where: { $0.id == id }) else {
            throw AssistantFailure("conversation_missing", "This conversation is no longer available.")
        }
        // Use the live checkpoint for the current conversation. Renaming must
        // never replace pending tool state with an older history-list snapshot.
        var updated = conversation.id == id ? conversation : history[index]
        updated.title = name
        updated.customTitle = true
        let result = AssistantJSON.object(["ok": .bool(true), "result": .object([
            "conversation_id": .string(id.uuidString), "title": .string(name), "status": .string("saved_on_device")
        ])])
        let database = store.assistantDatabase, scope = identity, snapshot = updated
        let receipt = action.map { (id: $0.operationID, digest: $0.digest, result: result.jsonString) }
        try Self.historyQueue.sync {
            try database.saveAssistantHistory(scope: scope, id: id.uuidString, payload: JSONEncoder().encode(snapshot), now: snapshot.updated, action: receipt)
        }
        if conversation.id == id { conversation.title = name; conversation.customTitle = true }
        history[index] = updated
        return result
    }
    @discardableResult
    func send(_ text: String) -> Bool {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !dictation.isBusy, canAcceptMessage, !trimmed.isEmpty || !uploadedFiles.isEmpty else { return false }
        let text = trimmed.isEmpty ? "Please review these attachments." : trimmed
        do {
            try requireActive()
            let steering = isRunning || conversation.canResume
            // Steering retains the current run's settings and journal scope.
            let settings = steering ? conversation.settings : try settingsForNewRequest()
            if steering { interruptExecution() }
            var next = conversation
            next.settings = settings
            let visible = text
            if next.messages.isEmpty && next.customTitle != true { next.title = String(visible.prefix(70)) }
            next.messages.append(AssistantMessage(role: "user", text: visible, attachments: uploadedFiles.isEmpty ? nil : uploadedFiles.map {
                AssistantMessageAttachment(id: $0["id"].string ?? UUID().uuidString, filename: $0["filename"].string ?? "Attachment")
            }))
            var item: AssistantJSON = .object(["type": .string("message"), "role": .string("user"), "text": .string(text)])
            if !uploadedFiles.isEmpty { item = item.setting("attachments", .array(uploadedFiles.map { $0["id"] })) }
            if steering { next.pendingSteering = (next.pendingSteering ?? []) + [item] }
            else { next.items.append(item); next.turnSteps = 0 }
            next.hasPendingInference = true; next.paused = true
            try persist(next)
            uploadedFiles = []; dictation.cancel()
            resume(); return true
        } catch { self.error = error.localizedDescription; return false }
    }
    var canAcceptMessage: Bool {
        connected && consented && !isConnecting && !awaitingAttachmentActivation && !needsAttachmentRecovery
            && (!isRunning || conversation.hasPendingInference || !conversation.calls.isEmpty || conversation.hasPendingSteering)
    }
    func resume() {
        guard !isRunning, !isConnecting, conversation.canResume else { return }
        error = nil; approval = nil
        let stamp = UUID(); generation = stamp
        isRunning = true; conversation.paused = false
        if conversation.hasPendingSteering { setActivity("Updating request…") }
        let previousTask = retiringTask; retiringTask = nil
        task = Task { [weak self] in
            guard let self else { return }
            defer { if generation == stamp { isRunning = false; isConnecting = false; setActivity(""); task = nil; finishAwayWork() } }
            do {
                await previousTask?.value
                guard generation == stamp else { return }
                isConnecting = true
                let subject = try await gateway.connect()
                try requireActive(); guard generation == stamp else { return }
                try verifyIdentity(subject)
                guard subject == identity, let tools else { throw AssistantFailure("identity_mismatch", "Reconnect with the account that owns this conversation.") }
                try await validateServerOptions()
                try requireActive(); guard generation == stamp else { return }
                isConnecting = false
                tools.context = conversation.context
                while generation == stamp {
                    // Let a follow-up arrive between local actions, even when
                    // an entire batch consists of synchronous SQLite saves.
                    await Task.yield()
                    guard generation == stamp else { return }
                    try requireActive()
                    try await applyPendingSteering(using: tools)
                    guard generation == stamp else { return }
                    if let call = conversation.calls.first {
                        let definition = try tools.definition(call.name)
                        let replay = try store.assistantDatabase.assistantAction(scope: identity, id: call.operationID, digest: call.digest)
                        if definition.needsApproval && replay == nil {
                            do {
                                let preview = try tools.approvalPreview(call)
                                if call.approvedDigest != preview.fingerprint {
                                    approval = call; approvalText = preview.text; approvalFingerprint = preview.fingerprint
                                    conversation.paused = true; try await persistAsync(); return
                                }
                            } catch {
                                finishCall(call, result: tools.failure(error)); try await persistAsync(); continue
                            }
                        }
                        setActivity("Thinking…")
                        // The in-memory call may come from a failed checkpoint
                        // write. No new action starts until its intent is durable.
                        try await persistAsync()
                        guard generation == stamp else { return }
                        let started = ContinuousClock.now
                        let output: AssistantJSON
                        if let replay { output = try JSONDecoder().decode(AssistantJSON.self, from: Data(replay.utf8)) }
                        else {
                            do { output = try await tools.execute(call) }
                            catch is CancellationError { throw CancellationError() }
                            catch { output = tools.failure(error) }
                        }
                        guard generation == stamp else { return }
                        // A committed operation may outlive a transport. Its
                        // receipt is already durable before publishing success.
                        finishCall(call, result: output)
                        try await persistAsync()
                        logger.info("tool_finished duration=\(String(describing: started.duration(to: .now)), privacy: .public)")
                        continue
                    }
                    guard conversation.hasPendingInference else { break }
                    guard conversation.turnSteps < 30 else { throw AssistantFailure("turn_limit", "This request reached its step limit. Start a new request to continue.") }
                    conversation.turnSteps += 1; try await persistAsync()
                    guard generation == stamp else { return }
                    setActivity("Thinking…"); clearStreamingText()
                    var completed = false
                    var context = [AssistantTimeContext.message(now: now())]
                    let instructions = tools.receiptPreferences().instructions.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !instructions.isEmpty {
                        // Refresh saved receipt preferences per step without adding them to history.
                        context.append(.object(["type": .string("message"), "role": .string("user"), "text": .string("My saved receipt suggestion instructions (also apply to relevant finance chat requests):\n\(instructions)")]))
                    }
                    try await gateway.step(items: context + conversation.items, settings: conversation.settings) { [weak self] event in
                        guard let self, self.generation == stamp else { throw CancellationError() }
                        try self.requireActive()
                        if event.type == "text_delta" { self.appendStreamingText(event.text ?? "") }
                        if event.type == "step_completed" {
                            guard !completed, let continuation = event.continuation else { throw AssistantFailure("invalid_response", "Missing assistant continuation.") }
                            completed = true
                            let calls = event.calls ?? []
                            guard Set(calls.map(\.id)).count == calls.count else { throw AssistantFailure("invalid_response", "Duplicate tool call identifiers.") }
                            self.flushStreamingText()
                            self.conversation.items.append(.object(["type": .string("continuation"), "value": .string(continuation)]))
                            self.conversation.calls = calls
                            let text = event.text ?? self.streamingText
                            if !text.isEmpty { self.conversation.messages.append(AssistantMessage(role: "assistant", text: text)) }
                            self.clearStreamingText()
                            self.conversation.hasPendingInference = !calls.isEmpty || event.needsFollowUp == true
                        }
                    }
                    guard generation == stamp else { return }
                    guard completed else { throw AssistantFailure("interrupted", "The reply was interrupted.") }
                    // The accepted continuation is durable before the next action.
                    try await persistAsync()
                }
                guard generation == stamp else { return }
                conversation.paused = false; try await persistAsync()
            } catch is CancellationError {
                if generation == stamp { conversation.paused = true; try? persist() }
            } catch {
                if generation == stamp {
                    self.error = error.localizedDescription; conversation.paused = true
                    needsAttachmentRecovery = (error as? AssistantFailure)?.code == "attachments_expired"
                    do { try persist() } catch { self.error = "Could not save assistant progress. \(error.localizedDescription)" }
                }
            }
        }
    }
    private func applyPendingSteering(using tools: AssistantTools) async throws {
        guard let updates = conversation.pendingSteering, !updates.isEmpty else { return }
        var next = conversation
        for call in next.calls {
            let result: AssistantJSON
            if let committed = try store.assistantDatabase.assistantAction(scope: identity, id: call.operationID, digest: call.digest) {
                result = try JSONDecoder().decode(AssistantJSON.self, from: Data(committed.utf8))
            } else {
                result = tools.failure(AssistantFailure("superseded", "A newer user message interrupted this call. Re-read current data and replan using the update. Previously committed actions remain saved."))
            }
            Self.finishCall(call, result: result, in: &next)
        }
        next.items.append(contentsOf: updates)
        next.pendingSteering = nil; next.turnSteps = 0
        next.hasPendingInference = true; next.paused = false
        // Publish the reconciled calls and consume the updates in one checkpoint.
        try await persistAsync(next)
    }
    private func finishCall(_ call: AssistantToolCall, result: AssistantJSON) {
        Self.finishCall(call, result: result, in: &conversation)
    }
    private static func finishCall(_ call: AssistantToolCall, result: AssistantJSON, in conversation: inout AssistantConversation) {
        var completed = call; completed.result = result.jsonString
        conversation.activity.append(completed)
        conversation.calls.removeAll { $0.id == call.id }
        conversation.items.append(.object(["type": .string("tool_result"), "call_id": .string(call.id), "name": .string(call.name), "output": .string(result.jsonString)]))
        conversation.hasPendingInference = true
    }
    func approve(_ accepted: Bool) {
        guard let approval, let index = conversation.calls.firstIndex(where: { $0.id == approval.id }), let tools else { return }
        do {
            try requireActive()
            if accepted {
                let latest = try tools.approvalPreview(approval)
                guard latest.fingerprint == approvalFingerprint else {
                    approvalText = latest.text; approvalFingerprint = latest.fingerprint
                    error = "The record changed. Review the updated preview before confirming."; return
                }
                conversation.calls[index].approvedDigest = latest.fingerprint
            }
            else { finishCall(approval, result: tools.failure(AssistantFailure("user_rejected", "The user declined this action. Do not attempt it another way."))) }
            self.approval = nil; conversation.paused = true; try persist(); resume()
        } catch { self.error = error.localizedDescription }
    }
    func pause() {
        do { try pauseAndCheckpoint() }
        catch { self.error = "Could not save paused progress: \(error.localizedDescription)" }
    }
    private func pauseAndCheckpoint() throws {
        interruptExecution()
        // Merely opening and closing the welcome screen should not fill History.
        let hasHistory = history.contains { $0.id == conversation.id }
        let hasContent = !conversation.messages.isEmpty || !conversation.items.isEmpty
            || !conversation.calls.isEmpty || !conversation.activity.isEmpty
            || conversation.hasPendingInference || conversation.hasPendingSteering || conversation.customTitle == true
        if !identity.isEmpty && (hasHistory || hasContent) { try persist() }
    }
    private func interruptExecution() {
        generation = UUID()
        if let task { task.cancel(); retiringTask = task }
        task = nil; isRunning = false; isConnecting = false
        store.assistantCancelConflictResolution()
        approval = nil; setActivity(""); clearStreamingText()
        if conversation.hasPendingInference || !conversation.calls.isEmpty || conversation.hasPendingSteering { conversation.paused = true }
        fileContinuation?.resume(throwing: CancellationError()); fileContinuation = nil; filePurpose = nil
        dictation.cancel()
        finishAwayWork()
    }
    func cancelRemaining() {
        pause()
        if let tools {
            do {
                for call in conversation.calls {
                    let result: AssistantJSON
                    if let committed = try store.assistantDatabase.assistantAction(scope: identity, id: call.operationID, digest: call.digest) {
                        result = try JSONDecoder().decode(AssistantJSON.self, from: Data(committed.utf8))
                    } else {
                        result = tools.failure(AssistantFailure("cancelled", "The user cancelled the remaining work. Completed actions remain saved."))
                    }
                    finishCall(call, result: result)
                }
            } catch {
                self.error = "Could not verify saved actions. The conversation remains paused. \(error.localizedDescription)"
                return
            }
        }
        // Keep accepted follow-ups in history even when the user cancels their
        // remaining execution, so a later turn retains the updated intent.
        conversation.items.append(contentsOf: conversation.pendingSteering ?? [])
        conversation.pendingSteering = nil
        conversation.calls = []; conversation.hasPendingInference = false; conversation.paused = false; approval = nil
        if !identity.isEmpty { do { try persist() } catch { self.error = error.localizedDescription } }
    }
    func selectFilesResult(_ result: Result<[URL], Error>) {
        let continuation = fileContinuation; fileContinuation = nil; filePurpose = nil
        continuation?.resume(with: result)
    }
    func continueWithoutExpiredUploads() {
        pause()
        conversation.items = conversation.items.map { item in
            guard item["type"].string == "message" else { return item }
            var fields = item.object; fields.removeValue(forKey: "attachments"); return .object(fields)
        }
        conversation.items.append(.object(["type": .string("message"), "role": .string("user"), "text": .string("Temporary chat uploads expired. Continue using saved records and already completed actions. Ask me to reattach a document if it is still needed. Do not repeat saved actions.")]))
        needsAttachmentRecovery = false; conversation.hasPendingInference = true; conversation.paused = true
        do { try persist(); resume() } catch { self.error = error.localizedDescription }
    }
    var canAttachFiles: Bool { connected && !awaitingAttachmentActivation && !isRunning && !isConnecting && !conversation.canResume && uploadedFiles.count < 10 }
    var attachmentContext: AssistantAttachmentContext { .init(conversationID: conversation.id, identity: identity) }
    func isCurrentAttachmentContext(_ context: AssistantAttachmentContext) -> Bool {
        context == attachmentContext && (try? requireActive()) != nil
    }
    func beginAttachmentSelection() -> AssistantAttachmentContext? {
        guard canAttachFiles, isCurrentAttachmentContext(attachmentContext) else { return nil }
        dictation.cancel()
        error = nil
        return attachmentContext
    }
    func attach(_ urls: [URL], context: AssistantAttachmentContext? = nil) {
        attach(context: context ?? attachmentContext) { urls.map { .file($0) } }
    }
    func attach(context: AssistantAttachmentContext, load: @escaping @MainActor () async throws -> [AssistantAttachmentInput]) {
        // A system picker can deliver its result before scenePhase returns to
        // active. Keep the selection until activation instead of dropping it.
        guard context == attachmentContext, presented, consented, canAttachFiles else { return }
        if !foreground || store.requiresUnlock {
            pendingAttachment = (context, load); awaitingAttachmentActivation = true
            return
        }
        guard isCurrentAttachmentContext(context), let tools else { return }
        isRunning = true; let stamp = generation
        task = Task {
            defer { if generation == stamp { isRunning = false; isConnecting = false; task = nil; setActivity(""); finishAwayWork() } }
            do {
                setActivity("Connecting…")
                isConnecting = true
                let subject = try await gateway.connect()
                try requireActive(); guard generation == stamp else { return }
                try verifyIdentity(subject)
                guard subject == identity else { throw AssistantFailure("identity_mismatch", "Reconnect with the account that owns this conversation.") }
                isConnecting = false
                setActivity("Preparing attachment…")
                let inputs = try await load()
                try Task.checkCancellation()
                guard generation == stamp, isCurrentAttachmentContext(context) else { throw CancellationError() }
                guard uploadedFiles.count + inputs.count <= 10 else { throw AssistantFailure("attachment_limit", "Attach up to 10 files per message. Scan to PDF to combine multiple pages.") }
                for input in inputs {
                    try Task.checkCancellation(); try requireActive()
                    let file: AssistantJSON
                    switch input {
                    case .file(let url): file = try tools.stage(url)
                    case .bytes(let bytes, let filename):
                        guard !bytes.isEmpty, bytes.count <= 15 * 1024 * 1024 else { throw AssistantFailure("attachment_limit", "Each chat attachment must be at most 15 MiB. Try fewer scanned pages.") }
                        let temporary = try await ReceiptImportIO.shared.stage(bytes, filename: filename)
                        do {
                            try Task.checkCancellation(); try requireActive()
                            guard generation == stamp, isCurrentAttachmentContext(context) else { throw CancellationError() }
                            file = try tools.stage(temporary.url)
                            await ReceiptImportIO.shared.remove(temporary)
                        } catch { await ReceiptImportIO.shared.remove(temporary); throw error }
                    }
                    let id = try file.required("file_id")
                    let total = uploadedFiles.reduce(0) { $0 + ($1["size_bytes"].int ?? 0) } + (file["size_bytes"].int ?? 0)
                    guard total <= 40_000_000 else { throw AssistantFailure("attachment_limit", "One message can include at most 40 MB of attachments.") }
                    try Task.checkCancellation()
                    guard generation == stamp, isCurrentAttachmentContext(context) else { throw CancellationError() }
                    let uploaded = try await gateway.upload(url: tools.stagedFile(id), fileID: id)
                    try requireActive(); guard generation == stamp, isCurrentAttachmentContext(context) else { return }; uploadedFiles.append(uploaded)
                }
            } catch is CancellationError { } catch { if generation == stamp { self.error = error.localizedDescription } }
        }
    }
    func startDictation() {
        guard canAcceptMessage, !isRunning, !dictation.isBusy else { return }
        dictation.start(gateway: gateway) { [weak self] in
            guard let self else { throw CancellationError() }
            try self.requireActive()
        }
    }
    private func settingsForNewRequest() throws -> AssistantSettings {
        if gateway is AssistantMockGateway { return preferences?.settings(for: identity) ?? conversation.settings }
        guard let preferences else { return conversation.settings }
        guard let settings = preferences.settings(for: identity) else {
            Task { await preferences.refresh() }
            throw AssistantFailure("settings_loading", preferences.error.isEmpty
                ? "Your Ask AI settings are still loading. Try again shortly."
                : "Ask AI settings could not load. Open Assistant Settings to reconnect to iCloud.")
        }
        guard preferences.conflicts.isEmpty else {
            throw AssistantFailure("settings_conflict", "Open Assistant Settings to choose which settings to keep.")
        }
        return settings
    }
}
