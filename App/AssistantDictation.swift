import Foundation
import AVFAudio
import Combine

@MainActor
protocol AssistantAudioRecording: AnyObject {
    var onFinish: ((Error?) -> Void)? { get set }
    func requestPermission() async -> Bool
    func start() throws
    func finish() throws -> URL
    func cancel()
}

/// One bounded recording, then one transcription. A transcript never sends a chat turn.
@MainActor
final class AssistantDictation: ObservableObject {
    enum State { case idle, preparing, recording, transcribing, failed }
    @Published private(set) var state: State = .idle
    @Published private(set) var error: String?
    @Published private(set) var startedAt: Date?
    var onTranscript: ((String) -> Void)?
    var isBusy: Bool { state != .idle && state != .failed }
    var canRetry: Bool { state == .failed && recordingURL != nil }
    private let recorder: any AssistantAudioRecording
    private var recordingURL: URL?
    private var task: Task<Void, Never>?
    private var generation = UUID()
    private var gateway: (any AssistantGatewayProtocol)?
    private var requireActive: (@MainActor () throws -> Void)?
    private var permissionGranted = false
    private let observers = AssistantNotificationTokens()

    init(recorder: any AssistantAudioRecording) {
        self.recorder = recorder
        recorder.onFinish = { [weak self] error in
            guard let self, self.state == .recording else { return }
            if let error { self.cancel(); self.error = error.localizedDescription }
            else { self.finish() }
        }
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.values.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in self?.interruptRecording() }
            })
        }
        observers.values.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let disconnected = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if disconnected { Task { @MainActor in self?.interruptRecording() } }
        })
    }
    private func interruptRecording() {
        guard state == .recording else { return }
        cancel(); error = "Dictation was interrupted. Tap the microphone to try again."
    }
    func start(gateway: any AssistantGatewayProtocol, requireActive: @escaping @MainActor () throws -> Void) {
        guard !isBusy else { return }
        cancel()
        self.gateway = gateway; self.requireActive = requireActive
        let stamp = generation
        state = .preparing
        task = Task { [weak self] in
            guard let self else { return }
            do {
                let allowed = await recorder.requestPermission()
                try Task.checkCancellation()
                guard generation == stamp else { return }
                guard allowed else { throw AssistantFailure("microphone_denied", "Enable microphone access for Finances in Settings, or continue typing.") }
                permissionGranted = true; task = nil
                activateIfPermitted()
            } catch {
                guard generation == stamp else { return }
                cancel()
                if !(error is CancellationError) { self.error = error.localizedDescription }
            }
        }
    }
    /// Permission alerts temporarily inactivate the scene. Start only after it
    /// becomes active again; a real background transition cancels the request.
    func activateIfPermitted() {
        guard state == .preparing, permissionGranted, let requireActive else { return }
        do { try requireActive() } catch { return }
        do {
            try recorder.start()
            startedAt = Date(); state = .recording
        } catch { cancel(); self.error = error.localizedDescription }
    }
    func finish() {
        guard state == .recording else { return }
        do {
            try requireActive?()
            recordingURL = try recorder.finish()
            transcribe()
        } catch {
            cancel()
            if !(error is CancellationError) { self.error = error.localizedDescription }
        }
    }
    func retry() { if canRetry { transcribe() } }
    private func transcribe() {
        guard let url = recordingURL, let gateway, let requireActive else { return }
        state = .transcribing; error = nil; startedAt = nil
        let stamp = generation
        task = Task { [weak self] in
            guard let self else { return }
            do {
                try requireActive(); try Task.checkCancellation()
                let text = try await gateway.transcribe(url: url).trimmingCharacters(in: .whitespacesAndNewlines)
                try Task.checkCancellation(); try requireActive()
                guard generation == stamp else { return }
                guard !text.isEmpty else { throw AssistantFailure("empty_transcript", "No speech was detected. Please dictate again.") }
                cancel()
                onTranscript?(text)
            } catch {
                guard generation == stamp else { return }
                if error is CancellationError { cancel(); return }
                self.error = error.localizedDescription; state = .failed; task = nil
            }
        }
    }
    func cancel() {
        generation = UUID(); task?.cancel(); task = nil
        recorder.cancel(); recordingURL = nil; startedAt = nil
        gateway = nil; requireActive = nil; permissionGranted = false; state = .idle; error = nil
    }
}

@MainActor
final class AssistantAudioRecorder: NSObject, AssistantAudioRecording, AVAudioRecorderDelegate {
    var onFinish: ((Error?) -> Void)?
    private var recorder: AVAudioRecorder?
    private var url: URL?
    private var ownsAudioSession = false
    func requestPermission() async -> Bool { await AVAudioApplication.requestRecordPermission() }
    func start() throws {
        cancel()
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.record, mode: .default, options: [.allowBluetoothHFP])
            try session.setActive(true); ownsAudioSession = true
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("dictation-\(UUID().uuidString).m4a")
            self.url = url
            let recorder = try AVAudioRecorder(url: url, settings: [
                AVFormatIDKey: kAudioFormatMPEG4AAC, AVSampleRateKey: 24_000,
                AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 32_000,
                AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue,
            ])
            self.recorder = recorder; recorder.delegate = self
            guard recorder.record(forDuration: 300) else { throw AssistantFailure("recording_failed", "Could not start dictation. Please try again.") }
        } catch { cancel(); throw error }
    }
    func finish() throws -> URL {
        guard let recorder, let url else { throw AssistantFailure("recording_missing", "Please dictate your message again.") }
        recorder.delegate = nil; recorder.stop(); self.recorder = nil
        releaseAudioSession()
        return url
    }
    func cancel() {
        recorder?.delegate = nil; recorder?.stop(); recorder = nil
        releaseAudioSession()
        if let url { try? FileManager.default.removeItem(at: url) }; url = nil
    }
    private func releaseAudioSession() {
        guard ownsAudioSession else { return }
        ownsAudioSession = false
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
    nonisolated func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == id else { return }
            self.onFinish?(flag ? nil : AssistantFailure("recording_failed", "Dictation could not finish. Please try again."))
        }
    }
    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        let id = ObjectIdentifier(recorder)
        Task { @MainActor [weak self] in
            guard let self, self.recorder.map(ObjectIdentifier.init) == id else { return }
            self.onFinish?(AssistantFailure("recording_failed", "Your dictation could not be saved. Please try again."))
        }
    }
}

/// Isolated sample UI uses synthetic audio and never opens the microphone.
@MainActor
final class AssistantMockAudioRecorder: AssistantAudioRecording {
    var onFinish: ((Error?) -> Void)?
    private var url: URL?
    func requestPermission() async -> Bool { true }
    func start() throws {
        cancel()
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("mock-dictation-\(UUID().uuidString).m4a")
        self.url = url
        try Data("mock-audio".utf8).write(to: url)
    }
    func finish() throws -> URL {
        guard let url else { throw AssistantFailure("recording_missing", "No mock recording.") }
        return url
    }
    func cancel() { if let url { try? FileManager.default.removeItem(at: url) }; url = nil }
}
