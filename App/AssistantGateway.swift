import Foundation
import UniformTypeIdentifiers

@MainActor
protocol AssistantGatewayProtocol {
    func connect() async throws -> String
    func localIdentity() async throws -> String?
    func options() async throws -> AssistantJSON
    func step(items: [AssistantJSON], settings: AssistantSettings, receive: @escaping @MainActor (AssistantStepEvent) throws -> Void) async throws
    func upload(url: URL, fileID: String) async throws -> AssistantJSON
    func voice(sdp: String, provider: String, context: String) async throws -> AssistantJSON
}

@MainActor
final class AssistantGateway: AssistantGatewayProtocol {
    let endpoint: String
    private let auth: ReceiptAnalysisClient
    init(endpoint: String = "https://finances.tugan.app", auth: ReceiptAnalysisClient = .shared) { self.endpoint = endpoint; self.auth = auth }
    func connect() async throws -> String { try await auth.connectAssistant(endpoint: endpoint) }
    func localIdentity() async throws -> String? { try await auth.verifiedAssistantIdentity(endpoint: endpoint) }
    func options() async throws -> AssistantJSON {
        let request = try auth.assistantRequest("mobile-assistant/options", endpoint: endpoint)
        let (data, response) = try await auth.assistantURLSession.data(for: request); try check(response)
        return try JSONDecoder().decode(AssistantJSON.self, from: data)
    }
    func check(_ response: URLResponse) throws {
        guard let http = response as? HTTPURLResponse else { throw AssistantFailure("connection_failed", "The server did not respond.") }
        if http.statusCode == 401 { auth.assistantSessionExpired(); throw AssistantFailure("session_expired", "Your session expired. Tap Resume to reconnect.") }
        if http.statusCode == 410 { throw AssistantFailure("attachments_expired", "A temporary chat upload expired. Continue without old uploads, then reattach any file the assistant still needs. Saved receipts are unaffected.") }
        guard (200..<300).contains(http.statusCode) else { throw AssistantFailure("request_failed", http.statusCode == 404 ? "The mobile assistant backend needs to be deployed." : "The assistant request failed (\(http.statusCode)). Tap Resume to retry.") }
    }
    func step(items: [AssistantJSON], settings: AssistantSettings, receive: @escaping @MainActor (AssistantStepEvent) throws -> Void) async throws {
        let body = AssistantJSON.object(["version": .number(1), "capabilities": .array([.string("conversation_titles")]), "items": .array(items), "settings": try .model(settings)])
        let request = try auth.assistantRequest("mobile-assistant/step", endpoint: endpoint, data: body.encoded())
        let (bytes, response) = try await auth.assistantURLSession.bytes(for: request)
        try check(response)
        guard (response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Type")?.contains("application/x-ndjson") == true else { throw AssistantFailure("invalid_response", "The assistant returned an unexpected response.") }
        var complete = false
        for try await line in bytes.lines {
            try Task.checkCancellation()
            guard line.utf8.count <= 2_000_000 else { throw AssistantFailure("response_limit", "The response is too large. Ask a narrower question.") }
            if line.isEmpty { continue }
            let event = try JSONDecoder().decode(AssistantStepEvent.self, from: Data(line.utf8))
            if event.type == "error" { throw AssistantFailure("interrupted", event.message ?? "The reply was interrupted.") }
            if event.type == "step_completed" { complete = true }
            try receive(event)
        }
        guard complete else { throw AssistantFailure("interrupted", "The reply was interrupted. Tap Resume to continue.") }
    }
    func upload(url: URL, fileID: String) async throws -> AssistantJSON {
        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0, size <= 15 * 1024 * 1024 else { throw AssistantFailure("attachment_limit", "Chat files must be at most 15 MiB.") }
        let boundary = "FinancesAssistant-" + UUID().uuidString
        let context = AssistantJSON.object(["files": .array([.object(["file_id": .string(fileID)])])])
        var data = Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"context\"\r\n\r\n\(context.jsonString)\r\n".utf8)
        let filename = url.lastPathComponent.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(of: "\r", with: "_").replacingOccurrences(of: "\n", with: "_")
        let mime = UTType(filenameExtension: url.pathExtension)?.preferredMIMEType ?? "application/octet-stream"
        data.append(Data("--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(filename)\"\r\nContent-Type: \(mime)\r\n\r\n".utf8))
        data.append(try Data(contentsOf: url)); data.append(Data("\r\n--\(boundary)--\r\n".utf8))
        let value: AssistantJSON = try await auth.uploadAssistantAttachment(data, contentType: "multipart/form-data; boundary=\(boundary)", endpoint: endpoint)
        guard let attachment = value["attachments"].array.first, attachment["file_id"].string?.lowercased() == fileID.lowercased(), attachment["id"].string != nil else { throw AssistantFailure("upload_failed", "The file could not be matched to its upload.") }
        return attachment
    }
    func voice(sdp: String, provider: String, context: String) async throws -> AssistantJSON {
        let body = AssistantJSON.object(["version": .number(1), "sdp": .string(sdp), "provider": .string(provider), "context": .string(String(context.prefix(8000)))])
        let request = try auth.assistantRequest("mobile-assistant/voice-session", endpoint: endpoint, data: body.encoded())
        let (data, response) = try await auth.assistantURLSession.data(for: request); try check(response)
        return try JSONDecoder().decode(AssistantJSON.self, from: data)
    }
}
