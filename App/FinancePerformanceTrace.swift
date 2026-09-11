import SwiftUI
import UIKit

/// Opt-in app-side timing: action dispatch to destination layout followed by
/// two display callbacks. Compiles to no-op view helpers in release builds.
enum FinancePerformanceTrace {
    @MainActor static var enabled: Bool {
        #if DEBUG
        CommandLine.arguments.contains("--demo-performance")
        #else
        false
        #endif
    }
    @MainActor static func begin(_ name: String) {
        #if DEBUG
        if enabled { AppActionPerformanceTrace.shared.begin(name) }
        #endif
    }
}

extension View {
    @MainActor @ViewBuilder func performanceDestination(_ name: String, ready: Bool = true) -> some View {
        #if DEBUG
        if FinancePerformanceTrace.enabled && (!name.hasPrefix("swipe-clear-") || AppActionPerformanceTrace.shared.hasPending(name)) {
            background(AppActionPerformanceLayout(name: name, ready: ready).allowsHitTesting(false))
                .onAppear {
                    // Retained navigation destinations may reappear with valid
                    // unchanged bounds and receive no new UIKit layout pass.
                    DispatchQueue.main.async {
                        if ready { AppActionPerformanceTrace.shared.layout(name) }
                    }
                }
        }
        else { self }
        #else
        self
        #endif
    }
}

#if DEBUG
@MainActor
private final class AppActionPerformanceTrace: NSObject {
    static let shared = AppActionPerformanceTrace()
    private struct Pending {
        var start = CACurrentMediaTime()
        var layoutObserved = false
        var displayCallbacks = 0
    }
    private var pending: [String: Pending] = [:]
    private var measurements: [[String: Any]] = []
    private var displayLink: CADisplayLink?
    override init() {
        super.init()
        NotificationCenter.default.addObserver(self, selector: #selector(finish), name: UIApplication.willResignActiveNotification, object: nil)
    }
    func begin(_ name: String) {
        pending[name] = Pending()
        if displayLink == nil {
            let link = CADisplayLink(target: self, selector: #selector(frame(_:)))
            link.add(to: .main, forMode: .common); displayLink = link
        }
    }
    func hasPending(_ name: String) -> Bool { pending[name] != nil }
    func layout(_ name: String) {
        guard pending[name] != nil else { return }
        pending[name]?.layoutObserved = true
    }
    @objc private func frame(_ link: CADisplayLink) {
        if pending["template-menu"] != nil && nativeTransactionMenuIsVisible() { layout("template-menu") }
        if pending["transaction-editor-cancel"] != nil && nativeSheetHasDismissed() { layout("transaction-editor-cancel") }
        for name in Array(pending.keys) {
            guard var item = pending[name], item.layoutObserved else { continue }
            item.displayCallbacks += 1
            if item.displayCallbacks >= 2 {
                measurements.append(["name": name, "elapsed_ms": (CACurrentMediaTime() - item.start) * 1000])
                pending.removeValue(forKey: name)
            } else { pending[name] = item }
        }
        if pending.isEmpty { displayLink?.invalidate(); displayLink = nil }
    }
    private func nativeSheetHasDismissed() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        return windows.contains { window in
            window.isKeyWindow && window.rootViewController?.viewIfLoaded?.window != nil && window.rootViewController?.presentedViewController == nil
        }
    }
    private func nativeTransactionMenuIsVisible() -> Bool {
        let windows = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows)
        for window in windows where window.isKeyWindow {
            var controller = window.rootViewController
            while let presented = controller?.presentedViewController { controller = presented }
            if let alert = controller as? UIAlertController, alert.title == "New Transaction", !alert.actions.isEmpty,
               alert.viewIfLoaded?.window != nil { return true }
        }
        return false
    }
    @objc private func finish() {
        displayLink?.invalidate(); displayLink = nil
        let destination = FileManager.default.temporaryDirectory.appendingPathComponent("FinancesiOS-Demo/performance-actions.json")
        let output: [String: Any] = ["metric": "action-to-first-layout-plus-two-display-callbacks", "measurements": measurements,
            "unfinished": Array(pending.keys).sorted()]
        if let encoded = try? JSONSerialization.data(withJSONObject: output, options: [.sortedKeys]) {
            try? encoded.write(to: destination, options: .atomic)
        }
    }
}

private struct AppActionPerformanceLayout: UIViewRepresentable {
    let name: String
    let ready: Bool
    func makeUIView(context: Context) -> Marker { Marker() }
    func updateUIView(_ view: Marker, context: Context) {
        view.name = name; view.ready = ready; view.setNeedsLayout()
    }
    final class Marker: UIView {
        var name = ""
        var ready = false
        override func layoutSubviews() {
            super.layoutSubviews()
            guard ready, window != nil, bounds.width > 0, bounds.height > 0 else { return }
            AppActionPerformanceTrace.shared.layout(name)
        }
    }
}
#endif
