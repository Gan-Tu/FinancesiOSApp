import Foundation
import Security

struct CloudKitSyncConfiguration: Equatable, Sendable {
    var containerIdentifier = "iCloud.dev.gan.FinanceApp"
    var environment = "Development"
    var zoneName = "FinancesJournal_v1"

    static func availableConfiguration() -> Self? {
        let info = Bundle.main.infoDictionary ?? [:]
        let configuration = Self(
            containerIdentifier: info["FinancesCloudKitContainerIdentifier"] as? String ?? "iCloud.dev.gan.FinanceApp",
            environment: info["FinancesCloudKitEnvironment"] as? String ?? "Development",
            zoneName: "FinancesJournal_v1"
        )
        return configuration.validationErrorForCurrentApplication() == nil ? configuration : nil
    }

    func validationErrorForCurrentApplication() -> String? {
        guard containerIdentifier.hasPrefix("iCloud."), !zoneName.isEmpty,
              ["Development", "Production"].contains(environment) else { return "CloudKit configuration is invalid." }
        #if os(macOS)
        var code: SecCode?
        var staticCode: SecStaticCode?
        var information: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCheckValidity(code, [], nil) == errSecSuccess,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &information) == errSecSuccess,
              let info = information as? [String: Any],
              let flags = info[kSecCodeInfoFlags as String] as? NSNumber,
              flags.uint32Value & 0x0002 /* kSecCodeSignatureAdhoc */ == 0,
              let team = info[kSecCodeInfoTeamIdentifier as String] as? String, !team.isEmpty,
              let entitlements = info[kSecCodeInfoEntitlementsDict as String] as? [String: Any],
              (entitlements["com.apple.developer.icloud-services"] as? [String])?.contains("CloudKit") == true,
              (entitlements["com.apple.developer.icloud-container-identifiers"] as? [String])?.contains(containerIdentifier) == true,
              entitlements["com.apple.developer.icloud-container-environment"] as? String == environment else {
            return "CloudKit requires a signed build with the configured iCloud container. This local build stays offline."
        }
        #elseif targetEnvironment(simulator)
        // A compile-only simulator build cannot prove CloudKit entitlement access.
        return "CloudKit sync requires a signed device build; this simulator stays offline."
        #elseif os(iOS)
        // iOS has no public SecTask entitlement inspector. Device code signing is
        // enforced by the OS; these explicit markers mirror the signed target.
        let info = Bundle.main.infoDictionary ?? [:]
        guard info["FinancesCloudKitEnabled"] as? Bool == true,
              info["FinancesCloudKitContainerIdentifier"] as? String == containerIdentifier,
              info["FinancesCloudKitEnvironment"] as? String == environment,
              let team = info["FinancesCloudKitTeamIdentifier"] as? String,
              !team.isEmpty, !team.contains("$("),
              Bundle.main.bundleURL.pathExtension == "app" ||
                (Bundle.main.bundleURL.pathExtension == "appex" &&
                 Bundle.main.bundleIdentifier == "dev.gan.FinancesApp.iOS.Share" &&
                 (info["NSExtension"] as? [String: Any])?["NSExtensionPointIdentifier"] as? String == "com.apple.share-services") else {
            return "CloudKit requires the configured, signed iOS app."
        }
        #else
        return "CloudKit sync is not configured on this platform."
        #endif
        return nil
    }
}

struct CloudKitSyncRecord: Equatable, Sendable, Codable {
    var recordType: String
    var recordID: String
    var operation: String = "upsert"
    var parentRecordID: String? = nil
    var contentHash: String? = nil
    var payloadJSON: String? = nil
    var clientChangeID: String? = nil
    var systemFields: Data? = nil
    /// Fetched files are owned by this client until moved by the caller or cancel/deinit.
    var assetFileURL: URL? = nil
    var assetSHA256: String? = nil
    var assetFilename: String? = nil
    var assetMIMEType: String? = nil
    var key: String { "\(recordType):\(recordID)" }
}
