import AuthenticationServices
import CloudKit
import Combine
import CryptoKit
import Foundation
import PDFKit
import Security
import UniformTypeIdentifiers

struct ReceiptSessionCredential: Codable {
    var token: String
    var expiresAt: Date
    var cloudKitUserID: String?
    var cloudKitScope: String?
    var appleUserID: String?

    static func claims(_ token: String) throws -> [String: Any] {
        let parts = token.split(separator: ".")
        guard parts.count == 3 else { throw AssistError.message("Invalid receipt session.") }
        var encoded = String(parts[1]).replacingOccurrences(of: "-", with: "+").replacingOccurrences(
            of: "_", with: "/")
        encoded += String(repeating: "=", count: (4 - encoded.count % 4) % 4)
        guard let data = Data(base64Encoded: encoded),
            let claims = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { throw AssistError.message("Invalid receipt session.") }
        return claims
    }
    init(token: String, cloudKitUserID: String? = nil, cloudKitScope: String? = nil, appleUserID: String? = nil) throws {
        guard let expiration = try Self.claims(token)["exp"] as? Double,
            expiration > Date().timeIntervalSince1970
        else {
            throw AssistError.message("The receipt session has expired.")
        }
        self.token = token
        expiresAt = Date(timeIntervalSince1970: expiration)
        self.cloudKitUserID = cloudKitUserID
        self.cloudKitScope = cloudKitScope
        self.appleUserID = appleUserID
    }
}
@MainActor protocol ReceiptCredentialStore {
    func load(endpoint: String) throws -> ReceiptSessionCredential?
    func save(_ value: ReceiptSessionCredential, endpoint: String) throws
    func remove(endpoint: String) throws
}
@MainActor final class ReceiptKeychainStore: ReceiptCredentialStore {
    #if os(iOS)
    static let defaultAccessGroup: String? = "group.dev.gan.FinancesApp.iOS"
    private static let defaultService = "dev.gan.FinancesApp.iOS.receipt-session.v1"
    #else
    static let defaultAccessGroup: String? = nil
    private static let defaultService = (Bundle.main.bundleIdentifier ?? "Finances") + ".receipt-session.v1"
    #endif
    private let service: String
    private let accessGroup: String?
    init(service: String? = nil, accessGroup: String? = ReceiptKeychainStore.defaultAccessGroup) {
        self.service = service ?? Self.defaultService
        self.accessGroup = accessGroup
    }
    private func query(_ endpoint: String, scoped: Bool = true) -> [String: Any] {
        var value: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service, kSecAttrAccount as String: endpoint,
            kSecUseDataProtectionKeychain as String: true,
        ]
        if scoped, let accessGroup { value[kSecAttrAccessGroup as String] = accessGroup }
        return value
    }
    private func check(_ status: OSStatus) throws {
        guard status == errSecSuccess else {
            throw AssistError.message(
                "Receipt sign-in could not access Keychain (\(status)). Try again after unlocking this device."
            )
        }
    }
    func load(endpoint: String) throws -> ReceiptSessionCredential? {
        if let stored = try read(endpoint: endpoint, scoped: true) { return stored.value }
        // Existing installs used the containing app's default Keychain group.
        // Migrate only after the shared write succeeds, keeping the same device-
        // unlocked protection and leaving credentials out of the receipt files.
        guard accessGroup != nil, Bundle.main.bundleURL.pathExtension != "appex",
              let legacy = try read(endpoint: endpoint, scoped: false) else { return nil }
        try save(legacy.value, endpoint: endpoint)
        if let group = legacy.group, group != accessGroup {
            var old = query(endpoint, scoped: false)
            old[kSecAttrAccessGroup as String] = group
            let status = SecItemDelete(old as CFDictionary)
            if status != errSecItemNotFound { try check(status) }
        }
        return legacy.value
    }
    private func read(endpoint: String, scoped: Bool) throws -> (value: ReceiptSessionCredential, group: String?)? {
        var request = query(endpoint, scoped: scoped)
        request[kSecReturnData as String] = true
        request[kSecReturnAttributes as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: CFTypeRef?
        let status = SecItemCopyMatching(request as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        try check(status)
        guard let attributes = result as? [String: Any], let data = attributes[kSecValueData as String] as? Data else { return nil }
        return (try JSONDecoder().decode(ReceiptSessionCredential.self, from: data), attributes[kSecAttrAccessGroup as String] as? String)
    }
    func save(_ value: ReceiptSessionCredential, endpoint: String) throws {
        let data = try JSONEncoder().encode(value)
        let status = SecItemUpdate(
            query(endpoint) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
        if status == errSecItemNotFound {
            var request = query(endpoint)
            request[kSecValueData as String] = data
            request[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlockedThisDeviceOnly
            try check(SecItemAdd(request as CFDictionary, nil))
        } else {
            try check(status)
        }
    }
    func remove(endpoint: String) throws {
        let status = SecItemDelete(query(endpoint, scoped: false) as CFDictionary)
        if status != errSecItemNotFound { try check(status) }
    }
}

private final class ReceiptSessionObservers {
    var tokens: [NSObjectProtocol] = []
    deinit { tokens.forEach { NotificationCenter.default.removeObserver($0) } }
}

@MainActor final class ReceiptAnalysisClient: ObservableObject {
    static let shared = ReceiptAnalysisClient()
    @Published private(set) var authenticated = false
    @Published private(set) var localDevelopment = false
    @Published private(set) var nonce = ""
    @Published private(set) var error = ""
    private var challenge = ""
    private var token = ""
    private var authEndpoint = ""
    private let session: URLSession
    private let credentialStore: any ReceiptCredentialStore
    private var credential: ReceiptSessionCredential?
    private var generation = UUID()
    private let observers = ReceiptSessionObservers()
    init(
        credentialStore: (any ReceiptCredentialStore)? = nil,
        session: URLSession = URLSession(configuration: .ephemeral)
    ) {
        self.credentialStore = credentialStore ?? ReceiptKeychainStore()
        self.session = session
        for name in [
            Notification.Name.CKAccountChanged,
            ASAuthorizationAppleIDProvider.credentialRevokedNotification,
        ] {
            observers.tokens.append(
                NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) {
                    [weak self] _ in
                    Task { @MainActor in self?.invalidateSession() }
                })
        }
    }
    private func canonicalEndpoint(_ endpoint: String) throws -> String {
        var value = try base(endpoint).absoluteString
        while value.hasSuffix("/") { value.removeLast() }
        return value
    }
    func restoreSession(endpoint: String) throws {
        let endpoint = try canonicalEndpoint(endpoint)
        if authEndpoint != endpoint {
            generation = UUID()
            authEndpoint = endpoint
            credential = nil
            token = ""
            authenticated = false
        }
        // The app and share extension can renew or remove this session independently.
        credential = try credentialStore.load(endpoint: endpoint)
        if let credential, credential.expiresAt > Date().addingTimeInterval(60) {
            token = credential.token
            authenticated = true
        } else {
            if credential != nil { try credentialStore.remove(endpoint: endpoint) }
            credential = nil
            token = ""
            authenticated = false
        }
    }
    private func saveSession(_ value: ReceiptSessionCredential, endpoint: String, stamp: UUID) throws {
        guard generation == stamp, authEndpoint == (try canonicalEndpoint(endpoint)) else {
            throw CancellationError()
        }
        try credentialStore.save(value, endpoint: authEndpoint)
        credential = value
        token = value.token
        authenticated = true
        nonce = ""
    }
    private func invalidateSession() {
        generation = UUID()
        if !authEndpoint.isEmpty { try? credentialStore.remove(endpoint: authEndpoint) }
        credential = nil
        token = ""
        authenticated = false
        nonce = ""
    }
    private func checkSavedIdentity() async throws {
        let stamp = generation
        if let user = credential?.cloudKitUserID {
            guard let configuration = CloudKitSyncConfiguration.availableConfiguration(),
                credential?.cloudKitScope == "\(configuration.containerIdentifier):\(configuration.environment.lowercased())" else {
                invalidateSession()
                return
            }
            let current = try await CKContainer(identifier: configuration.containerIdentifier)
                .userRecordID()
            guard generation == stamp else { throw CancellationError() }
            if current.recordName != user { invalidateSession() }
        } else if let user = credential?.appleUserID {
            let state = try await ASAuthorizationAppleIDProvider().credentialState(forUserID: user)
            guard generation == stamp else { throw CancellationError() }
            if state == .revoked || state == .notFound { invalidateSession() }
        }
    }
    func validateSharedAccountScope(_ expected: String) async throws {
        guard !expected.isEmpty else { return }
        guard let config = CloudKitSyncConfiguration.availableConfiguration() else {
            throw AssistError.message("Receipt AI needs the signed Finances build with iCloud enabled.")
        }
        let user = try await CKContainer(identifier: config.containerIdentifier).userRecordID()
        try Task.checkCancellation()
        let key = "\(config.containerIdentifier):\(config.environment):\(user.recordName)"
        let actual = SHA256.hash(data: Data(key.utf8)).map { String(format: "%02x", $0) }.joined()
        guard actual == expected else {
            throw AssistError.message("Your iCloud account changed. Open Finances to refresh its accounts before analyzing receipts.")
        }
    }
    private func connectCloudKit(endpoint: String) async throws -> Bool {
        // Never send an iCloud credential automatically to a user-configured server.
        guard try canonicalEndpoint(endpoint) == "https://finances.tugan.app",
            !CommandLine.arguments.contains("--demo"),
            !CommandLine.arguments.contains(where: { $0.hasPrefix("--qa-data-directory") }),
            let configuration = CloudKitSyncConfiguration.availableConfiguration()
        else { return false }
        struct Configuration: Decodable {
            var container: String
            var environment: String
            var apiToken: String
        }
        let stamp = generation
        let config: Configuration = try await perform(
            request("auth/cloudkit/native/config", endpoint: endpoint), retryAuthentication: false)
        guard config.container == configuration.containerIdentifier,
            config.environment.lowercased() == configuration.environment.lowercased()
        else { return false }
        let container = CKContainer(identifier: configuration.containerIdentifier)
        let user = try await container.userRecordID()
        let operation = CKFetchWebAuthTokenOperation(apiToken: config.apiToken)
        operation.qualityOfService = .userInitiated
        operation.configuration.timeoutIntervalForRequest = 20
        operation.configuration.timeoutIntervalForResource = 30
        let webToken: String = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                operation.fetchWebAuthTokenResultBlock = { continuation.resume(with: $0) }
                container.privateCloudDatabase.add(operation)
            }
        } onCancel: {
            operation.cancel()
        }
        try Task.checkCancellation()
        guard generation == stamp else { throw CancellationError() }
        let login: Login = try await perform(
            request(
                "auth/cloudkit/native", endpoint: endpoint, method: "POST",
                data: JSONSerialization.data(withJSONObject: [
                    "webAuthToken": webToken, "expectedUserRecordName": user.recordName,
                ])), retryAuthentication: false)
        try saveSession(
            ReceiptSessionCredential(token: login.token, cloudKitUserID: user.recordName,
                cloudKitScope: "\(configuration.containerIdentifier):\(configuration.environment.lowercased())"),
            endpoint: endpoint, stamp: stamp)
        return true
    }
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
        if !token.isEmpty, try canonicalEndpoint(endpoint) == authEndpoint {
            req.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
        }
        if let origin { req.setValue(origin, forHTTPHeaderField: "Origin") }
        return req
    }
    private func perform<T: Decodable>(
        _ req: URLRequest, as: T.Type = T.self, retryAuthentication: Bool = true
    ) async throws -> T {
        let (data, response) = try await session.data(for: req)
        guard let http = response as? HTTPURLResponse else {
            throw AssistError.message("The API server did not respond.")
        }
        guard (200..<300).contains(http.statusCode) else {
            let message =
                (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
                ?? "Receipt API request failed (\(http.statusCode))."
            if http.statusCode == 401, !token.isEmpty,
                req.value(forHTTPHeaderField: "Authorization") == "Bearer " + token
            {
                let endpoint = authEndpoint
                invalidateSession()
                if retryAuthentication, try await connectCloudKit(endpoint: endpoint) {
                    var retry = req
                    retry.setValue("Bearer " + token, forHTTPHeaderField: "Authorization")
                    return try await perform(retry, as: T.self, retryAuthentication: false)
                }
            }
            if http.statusCode == 413 { throw AssistError.attachmentLimit(message) }
            throw AssistError.message(message)
        }
        guard http.value(forHTTPHeaderField: "Content-Type")?.contains("application/json") == true
        else {
            throw AssistError.message(
                "This server does not provide the receipt API. Check the API server URL.")
        }
        return try JSONDecoder().decode(T.self, from: data)
    }
    func prepareSignIn(endpoint: String) async {
        nonce = ""
        error = ""
        localDevelopment = false
        do {
            try restoreSession(endpoint: endpoint)
            try await checkSavedIdentity()
            let stamp = generation
            let options: Options = try await perform(
                request("receipt-analysis/options", endpoint: endpoint))
            guard options.configured else {
                throw AssistError.message("The API server needs an OpenAI key.")
            }
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
            guard generation == stamp else { throw CancellationError() }
            if authenticated { return }
            if (try? await connectCloudKit(endpoint: endpoint)) == true { return }
            guard generation == stamp else { throw CancellationError() }
            let value: Challenge = try await perform(
                request("auth/apple/native/challenge", endpoint: endpoint))
            guard generation == stamp else { throw CancellationError() }
            challenge = value.challenge
            nonce = value.nonce
        } catch { self.error = error.localizedDescription }
    }
    func signIn(identityToken: Data, endpoint: String) async throws {
        try restoreSession(endpoint: endpoint)
        let stamp = generation
        let appleToken = String(decoding: identityToken, as: UTF8.self)
        let data = try JSONSerialization.data(withJSONObject: [
            "identityToken": String(decoding: identityToken, as: UTF8.self), "challenge": challenge,
        ])
        let value: Login = try await perform(
            request("auth/apple/native", endpoint: endpoint, method: "POST", data: data))
        let appleUser = try? ReceiptSessionCredential.claims(appleToken)["sub"] as? String
        try saveSession(
            ReceiptSessionCredential(token: value.token, appleUserID: appleUser), endpoint: endpoint,
            stamp: stamp)
    }
    func analyze(
        draft: TransactionDraft, ledgerID: UUID, accounts: [Account], commodities: [Commodity],
        metadata: [UUID: PaymentAccountMetadata], assets: [(AttachmentAsset, URL)],
        settings: ReceiptAISettings
    ) async throws -> ReceiptAnalysisResponse {
        try restoreSession(endpoint: settings.endpoint)
        try await checkSavedIdentity()
        let options: Options = try await perform(
            request("receipt-analysis/options", endpoint: settings.endpoint))
        guard options.configured else {
            throw AssistError.message("The API server needs an OpenAI key.")
        }
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
        } else if !authenticated {
            guard (try? await connectCloudKit(endpoint: settings.endpoint)) == true else {
                throw AssistError.message("Sign in with Apple in Receipt Suggestions settings.")
            }
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
