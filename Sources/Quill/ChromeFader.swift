import AppKit

/// Fades the window chrome (title bar, toolbar, traffic lights, word count) away while
/// typing and brings it back when the mouse moves, iA-style. In full screen the system
/// already tucks the title bar away, so only the word count fades there.
final class ChromeFader: ObservableObject {
    @Published private(set) var hidden = false
    private weak var window: NSWindow?
    private var monitor: Any?
    private var fullScreenObserver: Any?
    private var mouseAtHide = NSPoint.zero

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
    }

    func typingStarted(in window: NSWindow?) {
        guard let window else { return }
        attach(window)
        mouseAtHide = NSEvent.mouseLocation
        setHidden(true)
    }

    /// Brings the chrome back without waiting for the mouse, as when the sidebar is called
    /// up from the keyboard mid-sentence.
    func reveal() {
        setHidden(false)
    }

    private func attach(_ window: NSWindow) {
        guard self.window !== window else { return }
        self.window = window
        // What shows through the faded title bar should match the page.
        window.backgroundColor = Theme.background
        window.titlebarSeparatorStyle = .none
        window.acceptsMouseMovedEvents = true
        // A title bar faded out in the window would slide down blank in full screen.
        if let fullScreenObserver { NotificationCenter.default.removeObserver(fullScreenObserver) }
        fullScreenObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.willEnterFullScreenNotification, object: window, queue: .main
        ) { [weak self] _ in
            guard let self, let window = self.window else { return }
            self.titlebarContainer(of: window)?.alphaValue = 1
        }
        if monitor == nil {
            monitor = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDown, .rightMouseDown]) { [weak self] event in
                self?.mouseActivity(event)
                return event
            }
        }
    }

    private func mouseActivity(_ event: NSEvent) {
        guard hidden else { return }
        let p = NSEvent.mouseLocation
        // Ignore trackpad jitter; a deliberate move or any click reveals the chrome.
        if event.type != .mouseMoved || hypot(p.x - mouseAtHide.x, p.y - mouseAtHide.y) > 4 {
            setHidden(false)
        }
    }

    private func setHidden(_ hide: Bool) {
        guard hide != hidden, let window, let titlebar = titlebarContainer(of: window) else { return }
        hidden = hide
        guard !window.styleMask.contains(.fullScreen) else { return }
        NSAnimationContext.runAnimationGroup { ctx in
            ctx.duration = hide ? 0.5 : 0.2
            titlebar.animator().alphaValue = hide ? 0 : 1
        }
    }

    /// The private NSTitlebarContainerView that holds the title, toolbar and window buttons.
    private func titlebarContainer(of window: NSWindow) -> NSView? {
        let start = window.standardWindowButton(.closeButton)?.superview
        var view = start
        while let v = view, !String(describing: type(of: v)).contains("TitlebarContainer") {
            view = v.superview
        }
        return view ?? start
    }
}
