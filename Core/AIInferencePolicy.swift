import Foundation

/// Development, Simulator and test builds never make real AI requests.
/// Production use on a physical device retains its authenticated backend.
enum AIInferencePolicy {
    static var usesIsolatedSample: Bool {
        // FinancesMobileLaunchState only redirects --demo to sample storage in Debug.
        #if DEBUG
        return CommandLine.arguments.contains("--demo")
        #else
        return false
        #endif
    }

    static var blocksNetwork: Bool {
        #if DEBUG || targetEnvironment(simulator)
        return true
        #else
        let environment = ProcessInfo.processInfo.environment
        return environment["FINANCES_DISABLE_INFERENCE"] == "1"
            || environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestBundlePath"] != nil
            || NSClassFromString("XCTestCase") != nil
            || CommandLine.arguments.contains("--demo")
            || CommandLine.arguments.contains("--mock-ai")
            || CommandLine.arguments.contains(where: { $0.hasPrefix("--qa-") })
        #endif
    }

    static func requireNetworkInference() throws {
        guard !blocksNetwork else {
            throw AssistError.message("Real AI inference is disabled during development, testing and verification. Use mock responses.")
        }
    }
}
