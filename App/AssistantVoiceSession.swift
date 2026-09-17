import Foundation
import AVFAudio
import Combine
import OSLog
@preconcurrency import WebRTC

/// Realtime transcript/generation events can arrive after playback was cleared.
/// Only the WebRTC output-buffer events describe what is actually playing.
struct AssistantRealtimeAudioActivity {
    struct Update {
        let status: String
        let beganUserSpeech: Bool
    }
    private var playbackResponseID: String?
    private var speechItemID: String?

    mutating func receive(_ event: AssistantJSON) -> Update? {
        var beganUserSpeech = false
        switch event["type"].string {
        case "output_audio_buffer.started":
            guard let id = event["response_id"].string else { return nil }
            playbackResponseID = id
        case "output_audio_buffer.stopped", "output_audio_buffer.cleared":
            guard let id = event["response_id"].string, id == playbackResponseID else { return nil }
            playbackResponseID = nil
        case "input_audio_buffer.speech_started":
            guard let id = event["item_id"].string, id != speechItemID else { return nil }
            speechItemID = id
            beganUserSpeech = true
        case "input_audio_buffer.speech_stopped":
            guard let id = event["item_id"].string, id == speechItemID else { return nil }
            speechItemID = nil
        default: return nil
        }
        return Update(status: playbackResponseID == nil ? "Listening" : "Speaking", beganUserSpeech: beganUserSpeech)
    }
}

/// Native WebRTC owns media; the app owns every delegated finance operation.
@MainActor
final class AssistantVoiceSession: NSObject, ObservableObject {
    @Published private(set) var active = false
    @Published private(set) var connecting = false
    @Published private(set) var muted = false
    @Published private(set) var status = ""
    var onRequest: ((String, String, String) -> Void)?
    var onCorrection: (() -> Void)?
    private var factory: RTCPeerConnectionFactory?
    private var peer: RTCPeerConnection?
    private var channel: RTCDataChannel?
    private var audioTrack: RTCAudioTrack?
    private var receivingTracks: [RTCAudioTrack] = []
    private var ownsAudioSession = false
    private var provider = "live"
    private var generation = UUID()
    private var delegationID: String?
    private var transcript: [AssistantJSON] = []
    private var acceptingEvents = false
    private var closeTask: Task<Void, Never>?
    private var context = ""
    private let observers = AssistantNotificationTokens()
    private var seenDelegations = Set<String>()
    private var pendingDelegation: (id: String, offset: Int)?
    private var deliveredTranscriptEnd = -1
    private var realtimeUserText = ""
    private var realtimeAudioActivity = AssistantRealtimeAudioActivity()
    private let audioLog = Logger(subsystem: "dev.gan.FinancesApp.iOS", category: "AssistantVoice")

    override init() {
        super.init()
        for name in [AVAudioSession.interruptionNotification, AVAudioSession.mediaServicesWereResetNotification] {
            observers.values.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                Task { @MainActor in
                    guard let self, self.active || self.connecting else { return }
                    self.onCorrection?(); self.stop(); self.status = "Voice interrupted. Tap Voice to reconnect."
                }
            })
        }
        observers.values.append(NotificationCenter.default.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
            let disconnected = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? UInt) == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue
            if disconnected { Task { @MainActor in
                guard let self, self.active || self.connecting else { return }
                self.onCorrection?(); self.stop(); self.status = "Audio device disconnected."
            } }
        })
    }

    func start(gateway: any AssistantGatewayProtocol, context: String, requireActive: @escaping @MainActor () throws -> Void) async throws {
        guard !active, !connecting else { return }
        closeTask?.cancel(); release()
        let stamp = UUID(); generation = stamp
        connecting = true; status = "Connecting…"; muted = false
        self.context = context; transcript = []; seenDelegations = []; acceptingEvents = true
        pendingDelegation = nil; deliveredTranscriptEnd = -1
        realtimeUserText = ""
        realtimeAudioActivity = AssistantRealtimeAudioActivity()
        do {
            let allowed = await withCheckedContinuation { continuation in AVAudioApplication.requestRecordPermission { continuation.resume(returning: $0) } }
            guard allowed else { throw AssistantFailure("microphone_denied", "Enable microphone access for Finances in Settings, or continue typing.") }
            try requireActive(); guard generation == stamp else { throw CancellationError() }
            try activateAudioSession()
            provider = "live"
            try await connectPeer(gateway: gateway, stamp: stamp, requireActive: requireActive)
        } catch {
            if generation == stamp { release(); connecting = false; active = false; status = error.localizedDescription }
            throw error
        }
    }
    func activateAudioSession() throws {
        guard !ownsAudioSession else { return }
        let audio = RTCAudioSession.sharedInstance()
        audio.lockForConfiguration()
        defer { audio.unlockForConfiguration() }
        // WebRTC reapplies this configuration when its audio unit starts. Setting
        // AVAudioSession alone loses the speaker preference at that point.
        let configuration = RTCAudioSessionConfiguration()
        configuration.categoryOptions.insert(.defaultToSpeaker)
        RTCAudioSessionConfiguration.setWebRTC(configuration)
        // Keep WebRTC's voice processing and Bluetooth defaults. Unlike a forced
        // speaker override, defaultToSpeaker still respects connected headsets.
        try audio.setCategory(AVAudioSession.Category(rawValue: configuration.category),
                              mode: AVAudioSession.Mode(rawValue: configuration.mode),
                              options: configuration.categoryOptions)
        try audio.setActive(true)
        ownsAudioSession = true
    }
    private func connectPeer(gateway: any AssistantGatewayProtocol, stamp: UUID, requireActive: @escaping @MainActor () throws -> Void) async throws {
        RTCInitializeSSL()
        let factory = RTCPeerConnectionFactory()
        self.factory = factory
        let config = RTCConfiguration(); config.sdpSemantics = .unifiedPlan
        let constraints = RTCMediaConstraints(mandatoryConstraints: nil, optionalConstraints: nil)
        guard let peer = factory.peerConnection(with: config, constraints: constraints, delegate: self) else { throw AssistantFailure("voice_unavailable", "Could not initialize audio transport.") }
        self.peer = peer
        let source = factory.audioSource(with: constraints)
        let track = factory.audioTrack(with: source, trackId: "finances-audio")
        audioTrack = track; peer.add(track, streamIds: ["finances-voice"])
        let dataConfig = RTCDataChannelConfiguration(); dataConfig.isOrdered = true
        channel = peer.dataChannel(forLabel: "oai-events", configuration: dataConfig); channel?.delegate = self
        let offer: RTCSessionDescription = try await withCheckedThrowingContinuation { continuation in
            peer.offer(for: RTCMediaConstraints(mandatoryConstraints: ["OfferToReceiveAudio": "true"], optionalConstraints: nil)) { description, error in
                if let description { continuation.resume(returning: description) } else { continuation.resume(throwing: error ?? AssistantFailure("voice_offer", "Could not prepare audio connection.")) }
            }
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setLocalDescription(offer) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while peer.iceGatheringState != .complete, ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(50)); try requireActive()
            guard generation == stamp else { throw CancellationError() }
        }
        let result = try await gateway.voice(sdp: peer.localDescription?.sdp ?? offer.sdp, provider: provider, context: context)
        try requireActive(); guard generation == stamp else { throw CancellationError() }
        if result["fallback"].string == "realtime", provider == "live" {
            peer.close(); channel?.close(); self.peer = nil; channel = nil
            provider = "realtime"
            try await connectPeer(gateway: gateway, stamp: stamp, requireActive: requireActive)
            return
        }
        guard let sdp = result["sdp"].string else { throw AssistantFailure("voice_answer", "The voice service returned no connection answer.") }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            peer.setRemoteDescription(RTCSessionDescription(type: .answer, sdp: sdp)) { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } }
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(15))
            if let self, self.generation == stamp, self.connecting { self.stop(); self.status = "Voice connection timed out. Tap Voice to retry." }
        }
    }
    func mute() { muted.toggle(); audioTrack?.isEnabled = !muted }
    func stop() {
        guard active || connecting || peer != nil || ownsAudioSession else { return }
        generation = UUID(); acceptingEvents = false
        audioTrack?.isEnabled = false; active = false; connecting = false
        for track in receivingTracks { track.isEnabled = false }
        peer?.receivers.compactMap { $0.track as? RTCAudioTrack }.forEach { $0.isEnabled = false }
        if channel?.readyState == .open, provider == "live" {
            send(.object(["type": .string("session.close")]))
            let stamp = generation
            closeTask = Task { [weak self] in try? await Task.sleep(for: .seconds(1)); if self?.generation == stamp { self?.release() } }
        } else { release() }
        status = "Voice ended"
    }
    private func release() {
        let usedAudio = ownsAudioSession
        ownsAudioSession = false
        audioTrack?.isEnabled = false; channel?.delegate = nil; channel?.close(); channel = nil
        peer?.delegate = nil; peer?.close(); peer = nil; audioTrack = nil; factory = nil
        receivingTracks = []; acceptingEvents = false
        realtimeAudioActivity = AssistantRealtimeAudioActivity()
        if usedAudio {
            let audio = RTCAudioSession.sharedInstance()
            audio.lockForConfiguration()
            defer { audio.unlockForConfiguration() }
            // Balance our activation without deactivating an audio unit that
            // WebRTC is still closing. Its final release notifies other apps.
            try? audio.setActive(false)
        }
    }
    private func send(_ event: AssistantJSON) {
        guard let data = try? event.encoded(), channel?.readyState == .open else { return }
        channel?.sendData(RTCDataBuffer(data: data, isBinary: false))
    }
    func returnResult(_ result: String, requestID: String?) {
        guard active, acceptingEvents, let requestID, let delegationID, requestID == delegationID else { return }
        if provider == "live" {
            appendLive("session.commentary.append", content: result, delegation: delegationID)
        } else {
            send(.object(["type": .string("conversation.item.create"), "item": .object(["type": .string("function_call_output"), "call_id": .string(delegationID), "output": .string(result)])]))
            send(.object(["type": .string("response.create")]))
        }
        self.delegationID = nil
    }
    private func handle(_ event: AssistantJSON) {
        if event["type"].string == "session.closed" { release(); active = false; connecting = false; return }
        guard acceptingEvents else { return }
        if provider == "realtime", active, let update = realtimeAudioActivity.receive(event) {
            status = update.status
            // Keep correction handling immediate, but don't let a transcript
            // fragment change the UI back to Speaking after the buffer cleared.
            if update.beganUserSpeech { onCorrection?() }
            if let type = event["type"].string { audioLog.debug("Realtime audio event: \(type, privacy: .public)") }
            return
        }
        switch event["type"].string {
        case "session.started", "session.created":
            active = true; connecting = false; status = "Listening"
            if provider == "live", !context.isEmpty { appendLive("session.thinking.append", content: context, delegation: nil) }
        case "session.closed": release(); active = false; connecting = false
        case "session.input_transcript.delta":
            guard active else { return }
            let delta = event["delta"].string ?? ""
            if !delta.isEmpty {
                transcript.append(.object(["role": .string("user"), "text": .string(delta), "start_ms": event["start_ms"], "end_ms": event["end_ms"]]))
                dispatchPendingDelegation()
            }
        case "session.output_transcript.delta":
            if active, provider == "live" {
                let delta = event["delta"].string ?? ""
                if !delta.isEmpty { transcript.append(.object(["role": .string("assistant"), "text": .string(delta), "start_ms": event["start_ms"], "end_ms": event["end_ms"]])) }
                status = "Speaking"
            }
        case "session.delegation.created":
            guard active, event["delegation"]["target"].string == "client", let id = event["delegation"]["id"].string, seenDelegations.insert(id).inserted else { return }
            delegationID = id
            pendingDelegation = (id, event["offset_ms"].int ?? 0)
            dispatchPendingDelegation()
        case "conversation.item.input_audio_transcription.completed":
            if let text = event["transcript"].string { realtimeUserText = text }
        case "response.done":
            guard active, provider == "realtime" else { return }
            if event["response"]["status_details"]["reason"].string == "turn_detected" {
                audioLog.notice("Realtime reply interrupted by input speech detection")
            }
            for call in Self.completedRealtimeRequests(in: event) {
                guard seenDelegations.insert(call.id).inserted else { continue }
                delegationID = call.id; status = "Working…"; onRequest?(call.request, call.id, realtimeUserText.isEmpty ? call.request : realtimeUserText)
            }
        case "error":
            status = "Voice could not continue. You can keep typing."; onCorrection?(); stop()
        default: break
        }
    }
    static func completedRealtimeRequests(in event: AssistantJSON) -> [(id: String, request: String)] {
        // VAD can cancel a response after function-call fragments have arrived.
        // A response.done event alone is not permission to execute that work.
        guard event["response"]["status"].string == "completed" else { return [] }
        return event["response"]["output"].array.compactMap { call in
            guard call["type"].string == "function_call", call["name"].string == "run_finance_task",
                  call["status"].string == "completed", let id = call["call_id"].string,
                  let args = call["arguments"].string,
                  let value = try? JSONDecoder().decode(AssistantJSON.self, from: Data(args.utf8)),
                  let request = value["request"].string, !request.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
            return (id, request)
        }
    }
    private func dispatchPendingDelegation() {
        guard active, let pending = pendingDelegation else { return }
        let eligible = transcript.filter { ($0["start_ms"].int ?? 0) <= pending.offset }
        let userFragments = eligible.filter { $0["role"].string == "user" }
        guard let end = userFragments.compactMap({ $0["end_ms"].int }).max(), end > deliveredTranscriptEnd else {
            status = "Waiting for the spoken request…"; return
        }
        let visible = userFragments.filter { ($0["end_ms"].int ?? 0) > deliveredTranscriptEnd }.compactMap { $0["text"].string }.joined()
        pendingDelegation = nil; deliveredTranscriptEnd = end
        let request = AssistantJSON.object(["delegation_offset_ms": .number(Double(pending.offset)), "transcript_fragments": .array(Array(eligible.suffix(80)))])
        status = "Working…"
        onRequest?("Respond to the current delegated request using timestamped voice context. Fragments can be incomplete; ask for clarification before acting on uncertain amounts or targets.\n" + request.jsonString, pending.id, visible)
    }
    static func liveChunks(_ content: String) -> [String] {
        // A 400-byte UTF-8 bound is conservative for the 500-token append cap,
        // including CJK and emoji. Split only at Unicode scalar boundaries.
        var chunks: [String] = [], current = ""
        for scalar in content.unicodeScalars {
            let next = String(scalar)
            if current.utf8.count + next.utf8.count > 400 { chunks.append(current); current = "" }
            current += next
        }
        if !current.isEmpty { chunks.append(current) }
        return chunks
    }
    private func appendLive(_ type: String, content: String, delegation: String?) {
        for chunk in Self.liveChunks(content) { send(.object(["type": .string(type), "delegation_id": .text(delegation), "content": .string(chunk)])) }
    }
}

extension AssistantVoiceSession: RTCPeerConnectionDelegate {
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange stateChanged: RTCSignalingState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didAdd stream: RTCMediaStream) {
        Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.receivingTracks.append(contentsOf: stream.audioTracks)
            for track in stream.audioTracks { track.isEnabled = self.acceptingEvents }
        }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove stream: RTCMediaStream) {}
    nonisolated func peerConnectionShouldNegotiate(_ peerConnection: RTCPeerConnection) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceConnectionState) {
        if newState == .failed { Task { @MainActor [weak self] in
            guard let self, self.peer === peerConnection else { return }
            self.onCorrection?(); self.stop(); self.status = "Voice disconnected. Tap Voice to reconnect."
        } }
    }
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didChange newState: RTCIceGatheringState) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didGenerate candidate: RTCIceCandidate) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didRemove candidates: [RTCIceCandidate]) {}
    nonisolated func peerConnection(_ peerConnection: RTCPeerConnection, didOpen dataChannel: RTCDataChannel) {}
}
extension AssistantVoiceSession: RTCDataChannelDelegate {
    nonisolated func dataChannelDidChangeState(_ dataChannel: RTCDataChannel) {}
    nonisolated func dataChannel(_ dataChannel: RTCDataChannel, didReceiveMessageWith buffer: RTCDataBuffer) {
        let bytes = buffer.data
        Task { @MainActor [weak self] in
            guard let self, self.channel === dataChannel, bytes.count <= 1_000_000,
                  let event = try? JSONDecoder().decode(AssistantJSON.self, from: bytes) else { return }
            self.handle(event)
        }
    }
}
