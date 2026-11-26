import SwiftUI

/// The travelling bar that says an agent is working. Events carry no percentage, so it
/// only shows that something is happening.
///
/// Core Animation moves the bar, in the render server: the app runs no timer and redraws
/// nothing while it travels. (It was a SwiftUI timeline in the pane and an 18 Hz redraw of
/// the whole session card in the sidebar, which together cost about five percent of a
/// core for every agent at work.)
final class AgentActivityTrackView: NSView {
    private static let motionKey = "travel"

    var color: NSColor = AgentActivity.Phase.running.color {
        didSet { if color != oldValue { needsDisplay = true } }
    }

    /// The setting. Reduce Motion is followed here, so callers do not watch for it.
    var animates = true {
        didSet { if animates != oldValue { syncMotion() } }
    }

    /// How much of the track the bar covers.
    var segmentRatio: CGFloat = 0.34 {
        didSet { if segmentRatio != oldValue { needsLayout = true } }
    }

    /// Seconds for one pass along the track.
    var duration: TimeInterval = 1 {
        didSet { if duration != oldValue { segment.removeAnimation(forKey: Self.motionKey); syncMotion() } }
    }

    private let segment = CALayer()

    /// Whether the bar is moving right now.
    var isTravelling: Bool { segment.animation(forKey: Self.motionKey) != nil }

    private var occlusionObserver: NSObjectProtocol?
    private var motionObserver: NSObjectProtocol?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        layer?.masksToBounds = true
        layer?.addSublayer(segment)
        setAccessibilityElement(false)
        motionObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMotion() }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    deinit {
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        if let motionObserver { NSWorkspace.shared.notificationCenter.removeObserver(motionObserver) }
    }

    override var wantsUpdateLayer: Bool { true }

    /// Never takes clicks: they go to the tab or the terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func updateLayer() {
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        layer?.cornerRadius = bounds.height / 2
        segment.backgroundColor = color.cgColor
        segment.cornerRadius = bounds.height / 2
        CATransaction.commit()
    }

    override func layout() {
        super.layout()
        // The corners follow the height.
        needsDisplay = true
        syncMotion()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        guard let window else {
            segment.removeAnimation(forKey: Self.motionKey)
            return
        }
        // AppKit drops a layer's animations while its window is off screen (every tab
        // is a window, and only the selected one is on screen), so the travel is put
        // back when the window returns.
        occlusionObserver = NotificationCenter.default.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncMotion() }
        }
        syncMotion()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        syncMotion()
    }

    /// Places the bar and starts, restarts or stops its travel to match the view's size,
    /// the setting, Reduce Motion and whether the window is on screen.
    private func syncMotion() {
        let width = bounds.width
        let height = bounds.height
        guard width >= 2, height >= 1 else {
            segment.removeAnimation(forKey: Self.motionKey)
            return
        }
        let length = max(height, (width * segmentRatio).rounded())
        let from = length / 2
        let to = width - length / 2
        let moves = animates
            && !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            && window?.occlusionState.contains(.visible) == true
            && to > from

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        segment.bounds = CGRect(x: 0, y: 0, width: length, height: height)
        // At rest the bar sits in the middle of its track.
        segment.position = CGPoint(x: width / 2, y: height / 2)
        CATransaction.commit()

        guard moves else {
            segment.removeAnimation(forKey: Self.motionKey)
            return
        }
        // Leave a travel that already fits alone, so it does not jump back to the start
        // every time the view is laid out.
        if let running = segment.animation(forKey: Self.motionKey) as? CABasicAnimation,
           running.fromValue as? CGFloat == from, running.toValue as? CGFloat == to {
            return
        }
        let travel = CABasicAnimation(keyPath: "position.x")
        travel.fromValue = from
        travel.toValue = to
        travel.duration = duration
        travel.autoreverses = true
        travel.repeatCount = .infinity
        travel.timingFunction = CAMediaTimingFunction(name: .easeInEaseOut)
        segment.add(travel, forKey: Self.motionKey)
    }
}

/// `AgentActivityTrackView` for SwiftUI.
struct AgentActivityTrack: NSViewRepresentable {
    let color: NSColor
    let animates: Bool
    var ratio: CGFloat = 0.34
    var duration: TimeInterval = 1

    func makeNSView(context: Context) -> AgentActivityTrackView { AgentActivityTrackView() }

    func updateNSView(_ view: AgentActivityTrackView, context: Context) {
        view.color = color
        view.segmentRatio = ratio
        view.duration = duration
        view.animates = animates
    }
}
