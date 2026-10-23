import AppKit
import SwiftUI

/// Hands two-finger trackpad swipes and mouse-wheel turns over the view to `onScroll`, as
/// points to move by, which SwiftUI has no gesture for on the Mac. Watches the window's
/// events rather than standing in their way, so clicks and drags still reach the view.
struct ScrollWheelReader: NSViewRepresentable {
    let onScroll: (CGSize) -> Void

    func makeNSView(context: Context) -> ReaderView {
        let view = ReaderView()
        view.onScroll = onScroll
        return view
    }

    func updateNSView(_ view: ReaderView, context: Context) {
        view.onScroll = onScroll
    }

    final class ReaderView: NSView {
        var onScroll: ((CGSize) -> Void)?
        private var monitor: Any?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let monitor { NSEvent.removeMonitor(monitor) }
            monitor = nil
            guard window != nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self, event.window === self.window,
                      self.bounds.contains(self.convert(event.locationInWindow, from: nil))
                else { return event }
                // A mouse wheel moves in lines rather than points.
                let step: CGFloat = event.hasPreciseScrollingDeltas ? 1 : 10
                self.onScroll?(CGSize(width: event.scrollingDeltaX * step, height: event.scrollingDeltaY * step))
                return nil
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        deinit {
            if let monitor { NSEvent.removeMonitor(monitor) }
        }
    }
}
