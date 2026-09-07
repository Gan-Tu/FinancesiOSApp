import Foundation
import Network

protocol CloudKitForegroundNetworkMonitoring: Sendable {
    func start(onAvailabilityChange: @escaping @MainActor @Sendable (Bool) -> Void)
    func cancel()
}

struct CloudKitForegroundSyncTriggerDependencies: Sendable {
    var makeNetworkMonitor: @Sendable () -> any CloudKitForegroundNetworkMonitoring
    var waitForFallback: @Sendable () async throws -> Void

    init(
        makeNetworkMonitor: @escaping @Sendable () -> any CloudKitForegroundNetworkMonitoring,
        waitForFallback: @escaping @Sendable () async throws -> Void
    ) {
        self.makeNetworkMonitor = makeNetworkMonitor
        self.waitForFallback = waitForFallback
    }

    static let live = Self(
        makeNetworkMonitor: { NativeCloudKitForegroundNetworkMonitor() },
        waitForFallback: { try await Task.sleep(nanoseconds: 300_000_000_000) }
    )
}

/// One foreground session owns one monitor and fallback task. Retiring its
/// generation precedes cancellation, so already-delivered callbacks are inert.
@MainActor
final class CloudKitForegroundSyncTriggers {
    private let dependencies: CloudKitForegroundSyncTriggerDependencies
    private let onTrigger: @MainActor () -> Void
    private var generation: UUID?
    private var lastAvailability: Bool?
    private var monitor: (any CloudKitForegroundNetworkMonitoring)?
    private var fallbackTask: Task<Void, Never>?

    init(dependencies: CloudKitForegroundSyncTriggerDependencies = .live, onTrigger: @escaping @MainActor () -> Void) {
        self.dependencies = dependencies
        self.onTrigger = onTrigger
    }

    func update(isActive: Bool, isEnabled: Bool, isRecovering: Bool, automaticTriggersEnabled: Bool) {
        guard isActive && isEnabled && !isRecovering && automaticTriggersEnabled else {
            stop()
            return
        }
        guard generation == nil else { return }
        let current = UUID()
        generation = current
        lastAvailability = nil
        let monitor = dependencies.makeNetworkMonitor()
        self.monitor = monitor
        monitor.start { [weak self] available in
            self?.networkChanged(available, generation: current)
        }
        let wait = dependencies.waitForFallback
        fallbackTask = Task { [weak self] in
            while !Task.isCancelled {
                do { try await wait() }
                catch { return }
                guard !Task.isCancelled, self?.fireFallback(generation: current) == true else { return }
            }
        }
    }

    /// Returning the retired task lets shutdown/tests join it after releasing
    /// an injected waiter. Ordinary lifecycle callers can ignore the handle.
    @discardableResult
    func stop() -> Task<Void, Never>? {
        generation = nil
        lastAvailability = nil
        let retiredTask = fallbackTask
        let retiredMonitor = monitor
        fallbackTask = nil
        monitor = nil
        retiredTask?.cancel()
        retiredMonitor?.cancel()
        return retiredTask
    }

    private func networkChanged(_ available: Bool, generation current: UUID) {
        guard generation == current else { return }
        let previous = lastAvailability
        lastAvailability = available
        if available && previous != true { onTrigger() }
    }

    private func fireFallback(generation current: UUID) -> Bool {
        guard generation == current else { return false }
        onTrigger()
        return generation == current
    }

    deinit {
        fallbackTask?.cancel()
        monitor?.cancel()
    }
}

private final class NativeCloudKitForegroundNetworkMonitor: CloudKitForegroundNetworkMonitoring, @unchecked Sendable {
    private let monitor = NWPathMonitor()
    private let queue = DispatchQueue(label: "Finances.CloudKitForeground.network", qos: .utility)
    private let lock = NSLock()
    private var started = false
    private var cancelled = false

    func start(onAvailabilityChange: @escaping @MainActor @Sendable (Bool) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard !started && !cancelled else { return }
        started = true
        monitor.pathUpdateHandler = { path in
            let available = path.status == .satisfied
            Task { @MainActor in onAvailabilityChange(available) }
        }
        monitor.start(queue: queue)
    }

    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        guard !cancelled else { return }
        cancelled = true
        monitor.cancel()
    }

    deinit { monitor.cancel() }
}
