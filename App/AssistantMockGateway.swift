import Foundation

/// Deterministic development transport. No URLSession, credentials or provider
/// client are used, even when a real API key exists elsewhere on the machine.
@MainActor
final class AssistantMockGateway: AssistantGatewayProtocol {
    func connect() async throws -> String {
        guard AIInferencePolicy.usesIsolatedSample else {
            throw AssistantFailure("inference_disabled", "Real inference is disabled in development. Launch the isolated sample app with --demo for mock AI.")
        }
        return "local-developer"
    }
    func localIdentity() async throws -> String? { AIInferencePolicy.usesIsolatedSample ? "local-developer" : nil }
    func options() async throws -> AssistantJSON {
        .object(["version": .number(1), "models": .array(AssistantSettings.models.map {
            .object(["id": .string($0.id), "label": .string($0.label), "efforts": .array($0.efforts.map(AssistantJSON.string))])
        })])
    }
    func step(items: [AssistantJSON], settings: AssistantSettings, receive: @escaping @MainActor (AssistantStepEvent) throws -> Void) async throws {
        let lastUser = items.lastIndex { $0["type"].string == "message" && $0["role"].string == "user" }
        let request = lastUser.map { items[$0]["text"].string ?? "" } ?? ""
        let results = lastUser.map { Array(items.dropFirst($0 + 1)).filter { $0["type"].string == "tool_result" } } ?? []
        let response: String
        if request.contains("MID_TURN_STEER_OK") {
            response = "MID_TURN_STEER_OK"
        } else if request.contains("MOCK_SLOW_REPLY") {
            try receive(AssistantStepEvent(type: "text_delta", text: "Mock reply in progress…"))
            try await Task.sleep(for: .seconds(30))
            response = "Mock reply finished."
        } else if request.localizedCaseInsensitiveContains("Checking") {
            if results.isEmpty {
                try receive(AssistantStepEvent(type: "step_completed", continuation: "mock-only", calls: [
                    AssistantToolCall(id: UUID().uuidString, name: "get_balances", arguments: "{\"journal\":\"Personal\",\"account\":\"Checking\"}")
                ]))
                return
            }
            let result = results.last?["output"].string ?? "{}"
            response = "Mock Checking balance response from the local tool:\n\(result)"
        } else {
            response = "Mock response. Real inference is disabled in this development build."
        }
        try Task.checkCancellation()
        try receive(AssistantStepEvent(type: "step_completed", text: response, continuation: "mock-only", calls: []))
    }
    func upload(url: URL, fileID: String) async throws -> AssistantJSON {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 15 * 1024 * 1024 else { throw AssistantFailure("attachment_limit", "Chat files must be at most 15 MiB.") }
        return .object(["id": .string(UUID().uuidString), "file_id": .string(fileID), "filename": .string(url.lastPathComponent), "size_bytes": .number(Double(size))])
    }
    func voice(sdp: String, provider: String, context: String) async throws -> AssistantJSON {
        throw AssistantFailure("inference_disabled", "Voice inference is disabled in development and tests.")
    }
}
