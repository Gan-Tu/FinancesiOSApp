import SwiftUI
import UIKit

/// Observes the real scroll viewport rather than guessing a delay for List to
/// finish positioning a distant, lazily-created day header.
struct RegisterInitialPositionProbe: UIViewRepresentable {
    let armed: Bool
    let onPositioned: @MainActor () -> Void

    func makeUIView(context: Context) -> AnchorView { AnchorView() }
    func updateUIView(_ view: AnchorView, context: Context) {
        view.armed = armed
        view.onPositioned = onPositioned
        view.connectAndCheck()
    }

    final class AnchorView: UIView {
        var armed = false
        var onPositioned: (@MainActor () -> Void)?
        private weak var scrollView: UIScrollView?
        private var offsetObservation: NSKeyValueObservation?
        private var sizeObservation: NSKeyValueObservation?
        private var boundsObservation: NSKeyValueObservation?

        override func didMoveToWindow() { super.didMoveToWindow(); connectAndCheck() }
        override func layoutSubviews() { super.layoutSubviews(); connectAndCheck() }

        func connectAndCheck() {
            var ancestor = superview
            while let view = ancestor, !(view is UIScrollView) { ancestor = view.superview }
            if let scroll = ancestor as? UIScrollView, scroll !== scrollView {
                scrollView = scroll
                offsetObservation = scroll.observe(\.contentOffset, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.checkPosition() }
                }
                sizeObservation = scroll.observe(\.contentSize, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.checkPosition() }
                }
                boundsObservation = scroll.observe(\.bounds, options: [.new]) { [weak self] _, _ in
                    MainActor.assumeIsolated { self?.checkPosition() }
                }
            }
            checkPosition()
        }

        private func checkPosition() {
            guard armed, window != nil, bounds.height > 0, let scroll = scrollView else { return }
            let frame = convert(bounds, to: scroll)
            let inset = scroll.adjustedContentInset
            let top = scroll.contentOffset.y + inset.top
            let visible = CGRect(x: scroll.contentOffset.x, y: top, width: scroll.bounds.width,
                                 height: max(0, scroll.bounds.height - inset.top - inset.bottom))
            let maximumOffset = max(-inset.top, scroll.contentSize.height - scroll.bounds.height + inset.bottom)
            let atTop = abs(frame.minY - top) < 2
            let atClampedEnd = scroll.contentOffset.y >= maximumOffset - 2 && frame.intersects(visible)
            // Exact alignment is not guaranteed while List measures lazy rows.
            // A visible target header is enough to safely reveal today's rows.
            let targetIsVisible = visible.contains(CGPoint(x: frame.midX, y: frame.midY))
            guard atTop || atClampedEnd || targetIsVisible else { return }
            armed = false
            DispatchQueue.main.async { [weak self] in
                guard let self, self.window != nil else { return }
                self.onPositioned?()
            }
        }
    }
}
