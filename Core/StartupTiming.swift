import Foundation

/// Opt-in wall-clock instrumentation for the launch path.
///
/// Enabled only when the process was started with `--measure-startup`, so the
/// checks cost one cached boolean read on the normal launch path. Steps print
/// as `startup.<name>: <ms>` lines, matching `LedgerStore`'s existing output so
/// nested store timings and the outer startup phases read as one report.
enum StartupTiming {
    static let isEnabled = CommandLine.arguments.contains("--measure-startup")

    @inline(__always)
    static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    /// Prints the elapsed time since `start` under `name` and advances `start`
    /// so consecutive calls report back-to-back phases.
    static func log(_ name: String, from start: inout TimeInterval) {
        guard isEnabled else { return }
        let end = now()
        print("startup.\(name): \(String(format: "%.2f", (end - start) * 1_000))ms")
        start = end
    }
}
