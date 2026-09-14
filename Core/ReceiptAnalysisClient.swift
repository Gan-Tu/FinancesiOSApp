import Combine
import Foundation
import PDFKit
import UniformTypeIdentifiers

@MainActor final class ReceiptAnalysisClient: ObservableObject {
    static let shared = ReceiptAnalysisClient()
    @Published private(set) var authenticated = false
    @Published private(set) var localDevelopment = false
    @Published private(set) var nonce = ""
    @Published private(set) var error = ""
    private var challenge = ""
    private var token = ""
    private var authEndpoint = ""
    private let session = URLSession(configuration: .ephemeral)
    struct Options: Decodable {
        var local: Bool
        var configured: Bool
        var localOrigin: String?
        var stagedUploads: Bool?
    }
    struct Challenge: Decodable {
        var challenge: String
        var nonce: String
    }
    struct Login: Decodable { var token: String }
    private func base(_ endpoint: String) throws -> URL {
        #if DEBUG
            let allowLocalHTTP = true
        #else
            let allowLocalHTTP = false
        #endif
        guard let url = URL(string: endpoint), let host = url.host,
            url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
            url.scheme == "https"
                || (allowLocalHTTP && url.scheme == "http"
                    && ["localhost", "127.0.0.1", "::1"].contains(host))
        else {
            throw AssistError.message("Use an HTTPS API server, or localhost for development.")
        }
        return url
    }
    private func request(
        _ path: String, endpoint: String, method: String = "GET", data: Data? = nil,
        contentType: String = "application/json", origin: String? = nil
    ) throws -> URLRequest {
        var req = URLRequest(url: try base(endpoint).appendingPathComponent("api/v1/" + path))
        req.httpMethod = method
        req.httpBody = data
        req.timeoutInterval = 300
        req.setValue(contentType, forHTTPHeaderField: "Content-Type")
        if !token.isEmpty && endpoint == authEndpoint {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        return req
    }
    private func perform<T: Decodable>(_ req: URLRequest, as: T.Type = T.self) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AssistError.message("The API server did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message =
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "Receipt API request failed (\(http.statusCode))."
            if http.statusCode == 401 {
                token = ""
                authenticated = false
            }
            if http.statusCode == 413 { throw AssistError.attachmentLimit(message) }
            throw AssistError.message(message)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true else {
            throw AssistError.message(
                "This server does not provide the receipt API. Check the API server URL.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func prepareSignIn(endpoint: String) async {
        nonce = ""
        error = ""
        localDevelopment = false
        if authEndpoint != endpoint {
            token = ""
            authenticated = false
        }
        do {
            let options: Options = try await perform(request("receipt-analysis/options", endpoint: endpoint))
            guard options.configured else { throw AssistError.message("The API server needs an OpenAI key.") }
            if options.local {
                #if DEBUG
                    guard let host = try base(endpoint).host,
                        ["localhost", "127.0.0.1", "::1"].contains(host)
                    else { throw AssistError.message("Local authentication requires localhost.") }
                    localDevelopment = true
                    return
                #else
                    throw AssistError.message("Use a hosted API with Sign in with Apple.")
                #endif
            }
            let value: Challenge = try await perform(
                request("auth/apple/native/challenge", endpoint: endpoint))
            challenge = value.challenge
            nonce = value.nonce
        } catch { self.error = error.localizedDescription }
    }
    func signIn(identityToken: Data, endpoint: String) async throws {
        let data = try JSONSerialization.data(withJSONObject: [
            "identityToken": String(decoding: identityToken, as: UTF8.self), "challenge": challenge,
        ])
        let value: Login = try await perform(
            request("auth/apple/native", endpoint: endpoint, method: "POST", data: data))
        token = value.token
        authEndpoint = endpoint
        authenticated = true
        nonce = ""
    }
    func analyze(
        draft: TransactionDraft, ledgerID: UUID, accounts: [Account], commodities: [Commodity],
        metadata: [UUID: PaymentAccountMetadata], assets: [(AttachmentAsset, URL)],
        settings: ReceiptAISettings
    ) async throws -> ReceiptAnalysisResponse {
        let options: Options = try await perform(
            request("receipt-analysis/options", endpoint: settings.endpoint))
        guard options.configured else { throw AssistError.message("The API server needs an OpenAI key.") }
        if options.local {
            #if DEBUG
                guard let host = try base(settings.endpoint).host,
                    ["localhost", "127.0.0.1", "::1"].contains(host)
                else { throw AssistError.message("Local authentication requires localhost.") }
                struct Local: Decodable { var ok: Bool }
                let _: Local = try await perform(
                    request(
                        "auth/local", endpoint: settings.endpoint, method: "POST", origin: options.localOrigin
                    ))
            #else
                throw AssistError.message("Use a hosted API with Sign in with Apple.")
            #endif
        } else if token.isEmpty || settings.endpoint != authEndpoint {
            throw AssistError.message("Sign in with Apple in Receipt Suggestions settings.")
        }
        let context = try Self.context(
            draft: draft, ledgerID: ledgerID, accounts: accounts, commodities: commodities,
            metadata: metadata, settings: settings)
        let boundary = "Finances-" + UUID().uuidString
        let body = try await Task.detached(priority: .userInitiated) {
            try Self.multipart(context: context, assets: assets, boundary: boundary)
        }.value
        try Task.checkCancellation()
        if options.stagedUploads == true && body.count > 3_500_000 {
            return try await stagedAnalysis(
                body, contentType: "multipart/form-data; boundary=\(boundary)", endpoint: settings.endpoint,
                origin: options.localOrigin)
        }
        return try await perform(
            request(
                "receipt-analysis", endpoint: settings.endpoint, method: "POST", data: body,
                contentType: "multipart/form-data; boundary=\(boundary)", origin: options.localOrigin))
    }
    private func stagedAnalysis(_ body: Data, contentType: String, endpoint: String, origin: String?)
        async throws -> ReceiptAnalysisResponse
    {
        struct Start: Decodable {
            var uploadToken: String
            var chunkBytes: Int
        }
        struct Part: Decodable { var part: String }
        struct Cancelled: Decodable { var ok: Bool }
        let start: Start = try await perform(
            request(
                "receipt-upload/start", endpoint: endpoint, method: "POST",
                data: JSONSerialization.data(withJSONObject: [
                    "bytes": body.count, "contentType": contentType,
                ]), origin: origin))
        guard (1...2_000_000).contains(start.chunkBytes) else {
            throw AssistError.message("Invalid upload chunk size.")
        }
        do {
            var parts: [String] = []
            for offset in stride(from: 0, to: body.count, by: start.chunkBytes) {
                try Task.checkCancellation()
                var partRequest = try request(
                    "receipt-upload/part", endpoint: endpoint, method: "POST",
                    data: body.subdata(in: offset..<min(body.count, offset + start.chunkBytes)),
                    contentType: "application/octet-stream", origin: origin)
                partRequest.setValue(start.uploadToken, forHTTPHeaderField: "X-Receipt-Upload")
                partRequest.setValue(String(parts.count), forHTTPHeaderField: "X-Receipt-Part")
                let part: Part = try await perform(partRequest)
                parts.append(part.part)
            }
            return try await perform(
                request(
                    "receipt-analysis", endpoint: endpoint, method: "POST",
                    data: JSONSerialization.data(withJSONObject: [
                        "uploadToken": start.uploadToken, "parts": parts,
                    ]), origin: origin))
        } catch {
            if let cancellation = try? request(
                "receipt-upload/cancel", endpoint: endpoint, method: "POST",
                data: JSONSerialization.data(withJSONObject: ["uploadToken": start.uploadToken]),
                origin: origin)
            {
                Task { let _: Cancelled? = try? await perform(cancellation) }
            }
            throw error
        }
    }

    static func context(
        draft: TransactionDraft, ledgerID: UUID, accounts: [Account], commodities: [Commodity],
        metadata: [UUID: PaymentAccountMetadata], settings: ReceiptAISettings
    ) throws -> Data {
        var rows: [[String: Any]] = []
        for a in accounts where a.ledgerID == ledgerID {
            var row: [String: Any] = [
                "id": a.id.uuidString, "ledgerID": a.ledgerID.uuidString, "name": a.name,
                "kind": a.kind.rawValue,
            ]
            row["parentID"] = a.parentID?.uuidString
            row["commodityID"] = a.commodityID?.uuidString
            row["identities"] = try JSONSerialization.jsonObject(
                with: JSONEncoder().encode(metadata[a.id]?.identities ?? []))
            rows.append(row)
        }
        let formatter = ISO8601DateFormatter()
        let postings = draft.postings.map { p -> [String: Any] in
            var row: [String: Any] = ["amount": p.amount]
            row["accountID"] = p.accountID?.uuidString
            row["commodityID"] = p.commodityID?.uuidString
            return row
        }
        return try JSONSerialization.data(withJSONObject: [
            "journalID": ledgerID.uuidString, "accounts": rows,
            "commodities": commodities.filter { $0.ledgerID == ledgerID }.map {
                ["id": $0.id.uuidString, "symbol": $0.symbol, "name": $0.name]
            },
            "model": settings.model, "effort": settings.effort, "instructions": settings.instructions,
            "draft": [
                "date": formatter.string(from: draft.date), "payee": draft.payee, "note": draft.note,
                "number": draft.number, "postings": postings,
            ],
        ])
    }
    nonisolated static func multipart(context: Data, assets: [(AttachmentAsset, URL)], boundary: String)
        throws -> Data
    {
        guard !assets.isEmpty, assets.count <= 10 else {
            throw AssistError.attachmentLimit("Choose up to 10 receipts.")
        }
        var body = Data()
        var total = 0
        var pages = 0
        func append(_ text: String) { body.append(Data(text.utf8)) }
        append("--\(boundary)\r\nContent-Disposition: form-data; name=\"context\"\r\n\r\n")
        body.append(context)
        append("\r\n")
        for (asset, url) in assets {
            try Task.checkCancellation()
            let ext = url.pathExtension.lowercased()
            guard ["pdf", "jpg", "jpeg", "png", "webp", "heic", "heif"].contains(ext) else {
                throw AssistError.message("Use PDF, JPEG, PNG, WebP, HEIC, or HEIF receipts.")
            }
            let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
            guard size <= 20_000_000, total + size <= 40_000_000 else {
                throw AssistError.attachmentLimit("Receipts may be 20 MB each and 40 MB combined.")
            }
            let data = try Data(contentsOf: url)
            total += data.count
            guard data.count <= 20_000_000, total <= 40_000_000 else {
                throw AssistError.attachmentLimit("Receipts exceed the attachment limit.")
            }
            if ext == "pdf" {
                guard let pdf = PDFDocument(data: data), !pdf.isLocked else {
                    throw AssistError.message("Unlock this PDF before analyzing it.")
                }
                pages += pdf.pageCount
                guard pages <= 30 else {
                    throw AssistError.attachmentLimit("Choose PDFs with at most 30 pages combined.")
                }
            }
            let name = asset.originalFilename.replacingOccurrences(of: "\"", with: "_").replacingOccurrences(
                of: "\r", with: "_"
            ).replacingOccurrences(of: "\n", with: "_")
            let mime = UTType(filenameExtension: ext)?.preferredMIMEType ?? "application/octet-stream"
            append(
                "--\(boundary)\r\nContent-Disposition: form-data; name=\"attachments\"; filename=\"\(name)\"\r\nContent-Type: \(mime)\r\n\r\n"
            )
            body.append(data)
            append("\r\n")
        }
        append("--\(boundary)--\r\n")
        return body
    }
}
