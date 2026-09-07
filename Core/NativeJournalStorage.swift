import Foundation

/// Storage follows immutable build metadata, never current sign-in, network,
/// or provisioning availability. Explicitly injected storage URLs bypass this.
enum NativeJournalStorage {
    static func subdirectory(bundleIdentifier: String?, infoDictionary: [String: Any]?) -> String? {
        let appDirectory: String
        switch bundleIdentifier {
        case "dev.gan.FinancesMacApp": appDirectory = "FinancesMacApp"
        case "dev.gan.FinancesApp.iOS": appDirectory = "FinancesMobile"
        default: return nil
        }
        let configured = infoDictionary?["FinancesCloudKitEnvironment"] as? String
        let environment = configured.flatMap { ["Development", "Production"].contains($0) ? $0 : nil } ?? "Local"
        return "\(appDirectory)/\(environment)"
    }
}
