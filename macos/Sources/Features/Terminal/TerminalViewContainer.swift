import AppKit
import Combine
import GhosttyKit
import SwiftUI

/// Use this container to achieve a glass effect at the window level.
/// Modifying `NSThemeFrame` can sometimes be unpredictable.
class TerminalViewContainer: NSView {
    private let terminalView: NSView

    /// Background color applied with glass effect
    private(set) var glassEffectView: NSView?
    private var derivedConfig: DerivedConfig?

    /// Sigpane: the tab strip when it sits beside the terminal (bottom, left or right).
    /// Only windows that draw the custom strip get one; others keep native tabs.
    private(set) var edgeTabs: RoundedTerminalTabBar?
    /// Hairline under the titlebar, separating it from the terminal like the tab bar design.
    private let titlebarRule = NSView()
    private var edgeSettings: AnyCancellable?
    private var keyObserver: NSObjectProtocol?
    private var terminalInsets: [NSLayoutConstraint] = []

    /// Sigpane Signal chrome: the trace from the selected sidebar tab to the focused
    /// pane, and the status line under the terminal.
    private let signalTrace = SignalTraceView()
    private let statusBar = SignalStatusBar()
    private var updateObserver: NSObjectProtocol?
    private var occlusionObserver: NSObjectProtocol?
    private var statusTitle: (raw: String, safe: String) = ("", "")
    /// The strip thickness last applied, so a collapse or expand can be animated.
    private var appliedThickness: CGFloat?
    /// The sidebar's width while it is sliding between collapsed and expanded.
    private var slidingThickness: CGFloat?
    /// How far the terminal is shifted sideways from its resting place while the sidebar
    /// slides. Its size does not change with this, so the terminal is not resized on
    /// every frame of the slide.
    private var railShift: CGFloat = 0
    /// The sweep that crosses the terminal when its tab comes forward.
    private let arrival = SignalArrivalView()
    private var restingInsets: (position: TabBarSettings.Position, thickness: CGFloat, status: CGFloat) = (.top, 0, 0)
    private let railMotion = SignalMotion()
    private let arrivalMotion = SignalMotion()

    var windowThemeFrameView: NSView? {
        window?.contentView?.superview
    }

    var windowCornerRadius: CGFloat? {
        guard let window, window.responds(to: Selector(("_cornerRadius"))) else {
            return nil
        }

        return window.value(forKey: "_cornerRadius") as? CGFloat
    }

    init<Root: View>(@ViewBuilder rootView: () -> Root) {
        self.terminalView = NSHostingView(rootView: rootView())
        super.init(frame: .zero)
        setup()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// The initial content size to use as a fallback before the SwiftUI
    /// view hierarchy has completed layout (i.e. before @FocusedValue
    /// propagates `lastFocusedSurface`). Once the hosting view reports
    /// a valid intrinsic size, this fallback is no longer used.
    var initialContentSize: NSSize?

    override var intrinsicContentSize: NSSize {
        let hostingSize = terminalView.intrinsicContentSize
        // The hosting view returns a valid size once SwiftUI has laid out
        // with the correct idealWidth/idealHeight. Before that (when
        // @FocusedValue hasn't propagated), it returns a tiny default.
        // Fall back to initialContentSize in that case.
        var size = hostingSize
        if let initialContentSize,
           hostingSize.width < initialContentSize.width || hostingSize.height < initialContentSize.height {
            size = initialContentSize
        }
        // Make room for a visible edge tab strip so default window sizes keep the terminal size.
        if let edgeTabs, !edgeTabs.isHidden {
            let settings = TabBarSettingsStore.shared.settings
            if settings.position.isVertical { size.width += settings.edgeThickness } else { size.height += settings.edgeThickness }
        }
        if statusBar.superview != nil, !statusBar.isHidden { size.height += TabBarSettings.statusBarHeight }
        return size
    }

    private func setup() {
        addSubview(terminalView)
        terminalView.translatesAutoresizingMaskIntoConstraints = false
        terminalInsets = [
            terminalView.topAnchor.constraint(equalTo: topAnchor),
            terminalView.leadingAnchor.constraint(equalTo: leadingAnchor),
            terminalView.bottomAnchor.constraint(equalTo: bottomAnchor),
            terminalView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ]
        NSLayoutConstraint.activate(terminalInsets)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateGlassEffectIfNeeded()
        updateGlassEffectTopInsetIfNeeded()
        updateEdgeTabs()
    }

    override func layout() {
        super.layout()
        updateGlassEffectTopInsetIfNeeded()
        layoutEdgeTabs()
    }

    // MARK: Edge tab strip

    private func updateEdgeTabs() {
        guard let window = window as? TerminalWindow, window.drawsCustomTabStrip else {
            if window != nil { removeEdgeTabs() }
            return
        }
        if edgeTabs?.model.hostWindow !== window {
            removeEdgeTabs()
            let bar = RoundedTerminalTabBar(hostWindow: window, placement: .edge)
            // A tab joining or leaving shows or hides the strip at once: a new tab's window
            // must open with its sidebar already in place, not slide it in from nothing.
            bar.onTabCountChange = { [weak self] _ in
                self?.applyEdgeSettings(TabBarSettingsStore.shared.settings, animated: false)
            }
            addSubview(bar)
            edgeTabs = bar
            titlebarRule.wantsLayer = true
            addSubview(titlebarRule)
            addSubview(statusBar)
            addSubview(signalTrace)
            arrival.isHidden = true
            addSubview(arrival, positioned: .above, relativeTo: terminalView)
            railMotion.name = "sidebar"
            arrivalMotion.name = "arrival"
            bar.onSignalChange = { [weak self] in self?.syncSignalChrome() }
            bar.onSelectionChange = { [weak self] delta in self?.playTabTransition(delta) }
            // A tab that is not on screen stops its timers and its trace animation.
            occlusionObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didChangeOcclusionStateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncLiveness() }
            }
            syncLiveness()
            // Focus moves and split resizes do not relayout this view, so follow the
            // window's update pass; `syncSignalChrome` only redraws when something changed.
            updateObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didUpdateNotification, object: window, queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.syncSignalChrome() }
            }
            // The published value arrives before the store updates, so use the one passed in.
            edgeSettings = TabBarSettingsStore.shared.$settings.sink { [weak self] settings in
                self?.applyEdgeSettings(settings)
            }
            // Every tab is its own window with its own strip; refresh as it comes forward.
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main
            ) { [weak bar] _ in
                MainActor.assumeIsolated { bar?.refresh() }
            }
        }
        edgeTabs?.refresh()
        applyEdgeSettings(TabBarSettingsStore.shared.settings, animated: false)
    }

    private func removeEdgeTabs() {
        edgeTabs?.removeFromSuperview()
        edgeTabs = nil
        titlebarRule.removeFromSuperview()
        statusBar.removeFromSuperview()
        signalTrace.removeFromSuperview()
        arrival.removeFromSuperview()
        edgeSettings = nil
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        keyObserver = nil
        if let updateObserver { NotificationCenter.default.removeObserver(updateObserver) }
        updateObserver = nil
        if let occlusionObserver { NotificationCenter.default.removeObserver(occlusionObserver) }
        occlusionObserver = nil
        appliedThickness = nil
        railMotion.stop()
        arrivalMotion.stop()
        arrival.isHidden = true
        slidingThickness = nil
        railShift = 0
        applyTerminalInsets(position: .top, thickness: 0)
    }

    /// `animated` is for the user collapsing or expanding the sidebar from settings. Tabs
    /// coming and going, and a window being set up, place the strip without motion.
    private func applyEdgeSettings(_ settings: TabBarSettings, animated: Bool = true) {
        guard let edgeTabs else { return }
        let visible = settings.position != .top
            && (settings.showWithSingleTab || edgeTabs.displayedTabs.count > 1)
        edgeTabs.isHidden = !visible
        titlebarRule.layer?.backgroundColor = edgeTabs.theme.foreground.withAlphaComponent(0.08).cgColor
        statusBar.isHidden = !settings.showsStatusBar
        let thickness = visible ? settings.edgeThickness : 0
        let status = settings.showsStatusBar ? TabBarSettings.statusBarHeight : 0
        // Collapsing or expanding the sidebar slides instead of snapping.
        let slides = animated && settings.isSignal && settings.animations && settings.position.isVertical
            && appliedThickness != nil && appliedThickness != thickness
            && window?.isFrontTab == true && !RoundedTerminalTabBar.reduceMotion
        let from = slidingThickness ?? appliedThickness ?? thickness
        appliedThickness = thickness
        if slides {
            // The terminal takes its new width once, at the start, and glides into place
            // while the sidebar's width follows. Nothing is resized frame by frame.
            let side: CGFloat = settings.position == .left ? 1 : -1
            let position = settings.position
            railMotion.run(duration: 0.3) { [weak self] progress in
                guard let self else { return }
                self.slidingThickness = progress < 1 ? from + (thickness - from) * progress : nil
                self.railShift = side * (from - thickness) * (1 - progress)
                self.applyTerminalInsets(position: position, thickness: thickness, status: status)
                self.needsLayout = true
                self.layoutSubtreeIfNeeded()
            }
        } else {
            if !railMotion.isRunning || restingInsets.position != settings.position {
                railMotion.stop()
                slidingThickness = nil
                railShift = 0
            }
            applyTerminalInsets(position: settings.position, thickness: thickness, status: status)
            needsLayout = true
        }
        invalidateIntrinsicContentSize()
    }

    /// Timers and the trace pulse only run while this tab's window is on screen.
    private func syncLiveness() {
        let visible = window?.occlusionState.contains(.visible) == true
        edgeTabs?.isLive = visible
        statusBar.isLive = visible
        if visible { syncSignalChrome() } else { signalTrace.clear() }
    }

    /// A short fade and slide of the terminal when the selection moves to this tab.
    private func playTabTransition(_ delta: Int) {
        let settings = TabBarSettingsStore.shared.settings
        guard settings.isSignal, settings.animations, delta != 0, window?.isFrontTab == true,
              !RoundedTerminalTabBar.reduceMotion else { return }
        // A line in the window's color sweeps the terminal in the direction the selection
        // moved: down the list for a later tab with a sidebar, sideways with a top or
        // bottom strip. It is drawn over the terminal. Nothing underneath moves, resizes
        // or turns transparent, so a translucent window never shows through more.
        arrival.color = edgeTabs?.signalColor ?? .controlAccentColor
        arrival.horizontal = !settings.position.isVertical
        arrival.forward = delta > 0
        arrival.frame = terminalView.frame
        arrival.isHidden = false
        arrivalMotion.run(duration: 0.4, delay: RoundedTerminalTabBar.settleDelay(for: window)) { [weak self] progress in
            guard let self else { return }
            self.arrival.progress = progress
            if progress >= 1 { self.arrival.isHidden = true }
        }
    }

    private func applyTerminalInsets(position: TabBarSettings.Position, thickness: CGFloat, status: CGFloat = 0) {
        restingInsets = (position, thickness, status)
        applyTerminalInsets()
    }

    /// Sets the terminal's edges: its resting place plus whatever shift is in progress.
    /// A shift moves both edges of an axis together, so the terminal keeps its size.
    private func applyTerminalInsets() {
        guard terminalInsets.count == 4 else { return }
        let (position, thickness, status) = restingInsets
        terminalInsets[1].constant = (position == .left ? thickness : 0) + railShift
        terminalInsets[2].constant = -((position == .bottom ? thickness : 0) + status)
        terminalInsets[3].constant = (position == .right ? -thickness : 0) + railShift
    }

    private func layoutEdgeTabs() {
        titlebarRule.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1)
        // The status line spans the window's foot; the tab strip sits above it.
        let status: CGFloat = statusBar.superview != nil && !statusBar.isHidden ? TabBarSettings.statusBarHeight : 0
        statusBar.frame = NSRect(x: 0, y: 0, width: bounds.width, height: status)
        signalTrace.frame = bounds
        if !arrival.isHidden { arrival.frame = terminalView.frame }
        if let edgeTabs, !edgeTabs.isHidden {
            let settings = TabBarSettingsStore.shared.settings
            let t = slidingThickness ?? settings.edgeThickness
            edgeTabs.frame = switch settings.position {
            case .top, .bottom: NSRect(x: 0, y: status, width: bounds.width, height: t)
            case .left: NSRect(x: 0, y: status, width: t, height: max(0, bounds.height - status))
            case .right: NSRect(x: bounds.width - t, y: status, width: t, height: max(0, bounds.height - status))
            }
        }
        syncSignalChrome()
    }

    // MARK: Signal chrome

    /// A pane's frame in this view: its terminal area plus the header strip above it.
    private func paneFrame(of surface: NSView, header: CGFloat) -> NSRect? {
        var node: NSView? = surface
        while let current = node, !(current is SurfaceScrollView) { node = current.superview }
        guard let host = node, let window, host.window === window else { return nil }
        var rect = convert(host.bounds, from: host)
        rect.size.height += header  // This view is not flipped, so the header is above.
        return rect
    }

    /// Refreshes the trace and status line from the window's current tab, focus and layout.
    private func syncSignalChrome() {
        guard let window = window as? TerminalWindow, let edgeTabs else {
            signalTrace.clear()
            return
        }
        // This runs on every window update, so tabs that are not on screen do nothing.
        guard window.occlusionState.contains(.visible) else { return }
        let settings = TabBarSettingsStore.shared.settings
        let controller = window.terminalController
        let focused = controller?.focusedSurface
        let leaves = controller?.surfaceTree.root?.leaves() ?? []
        let color = edgeTabs.signalColor

        if !statusBar.isHidden {
            var content = SignalStatusBar.Content()
            // This runs on every window update, so the cleaned title is kept until it changes.
            let rawTitle = focused?.title ?? ""
            if rawTitle != statusTitle.raw { statusTitle = (rawTitle, SignalText.chromeSafe(rawTitle)) }
            content.title = statusTitle.safe
            if let focused, let index = leaves.firstIndex(where: { $0 === focused }) {
                content.pane = "pane \(SignalText.paneLetter(index)) of \(leaves.count)"
            }
            if let size = focused?.surfaceSize {
                content.size = "\(size.columns)×\(size.rows)"
            }
            content.agent = focused?.agentActivity.summary.lead
            statusBar.theme = edgeTabs.theme
            statusBar.color = color
            statusBar.content = content
            statusBar.hints = SignalHints.current(settings)
        }

        let header: CGFloat = settings.showsPaneHeaders ? TabBarSettings.paneHeaderHeight : 0
        // The strip the trace starts from: the titlebar strip for Top, else the edge strip.
        let strip: RoundedTerminalTabBar? = settings.position == .top
            ? window.titlebarTabStrip
            : (edgeTabs.isHidden ? nil : edgeTabs)
        guard settings.isSignal, settings.signalTrace, let strip,
              let focused, let pane = paneFrame(of: focused, header: header),
              let tabFrame = strip.selectedTabFrame else {
            signalTrace.clear()
            return
        }
        let tab = convert(tabFrame, from: strip)
        let half = settings.gutter / 2
        func crisp(_ point: NSPoint) -> NSPoint { NSPoint(x: point.x.rounded() + 0.5, y: point.y.rounded() + 0.5) }
        let points: [NSPoint]
        switch settings.position {
        case .left, .right:
            // Out of the tab, along the gutter beside the sidebar, across to the pane's header.
            let left = settings.position == .left
            let lane = left ? edgeTabs.frame.maxX + half : edgeTabs.frame.minX - half
            let port = NSPoint(x: left ? pane.minX : pane.maxX, y: pane.maxY - (header > 0 ? header / 2 : 12))
            let start = NSPoint(x: left ? tab.maxX : tab.minX, y: tab.midY)
            points = [start, NSPoint(x: lane, y: start.y), NSPoint(x: lane, y: port.y), port]
        case .top, .bottom:
            // Out of the tab, along the gutter beside the strip, then into the pane's edge.
            let top = settings.position == .top
            let lane = top ? terminalView.frame.maxY - half : terminalView.frame.minY + half
            let x = min(max(tab.midX, pane.minX + 18), max(pane.minX + 18, pane.maxX - 18))
            let start = NSPoint(x: tab.midX, y: top ? tab.minY : tab.maxY)
            points = [start, NSPoint(x: start.x, y: lane), NSPoint(x: x, y: lane),
                      NSPoint(x: x, y: top ? pane.maxY : pane.minY)]
        }
        let route = SignalTraceView.Route(
            points: points.map(crisp),
            panes: leaves.compactMap { paneFrame(of: $0, header: header) },
            radius: settings.paneCornerRadius)
        signalTrace.update(route, color: color,
                           animated: settings.animations && !RoundedTerminalTabBar.reduceMotion)
    }

    func ghosttyConfigDidChange(_ config: Ghostty.Config, preferredBackgroundColor: NSColor?) {
        let newValue = DerivedConfig(config: config, preferredBackgroundColor: preferredBackgroundColor, cornerRadius: windowCornerRadius)
        guard newValue != derivedConfig else { return }
        derivedConfig = newValue

        // Attach the glass effect synchronously if missing to prevent flicker when a new tab appears.
        // Existing updates remain deferred, as they can occur during SwiftUI rendering.
        if glassEffectView == nil {
            updateGlassEffectIfNeeded()
        } else {
            DispatchQueue.main.async(execute: updateGlassEffectIfNeeded)
        }
    }
}

// MARK: - Signal chrome views

/// Sigpane: the luminous line that wires the selected sidebar tab to the focused pane.
/// It is masked by the panes, so it only shows in the gutters — like a trace running
/// under the panes — and ends in a lit port on the focused pane's edge.
private final class SignalTraceView: NSView {
    private let masked = CALayer()
    private let base = CAShapeLayer()
    private let flow = CAShapeLayer()
    private let port = CALayer()
    private let paneMask = CAShapeLayer()

    /// Where the trace runs: out of the selected tab, along the gutter beside the sidebar,
    /// then across to the focused pane. `panes` are masked out of it.
    struct Route: Equatable {
        /// Corner points of the line, from the tab to the pane. Corners are rounded.
        var points: [NSPoint]
        var panes: [NSRect]
        var radius: CGFloat
    }

    private struct Drawn: Equatable {
        var route: Route
        var color: NSColor
        var size: NSSize
        var animated: Bool
    }

    private var drawn: Drawn?

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = true
        isHidden = true
        for line in [base, flow] {
            line.fillColor = nil
            line.lineCap = .round
            line.lineJoin = .round
        }
        base.lineWidth = 1
        flow.lineWidth = 1.6
        flow.lineDashPattern = [14, 190]
        flow.shadowOffset = .zero
        flow.shadowRadius = 3
        flow.shadowOpacity = 0.9
        port.cornerRadius = 3.5
        port.shadowOffset = .zero
        port.shadowRadius = 5
        port.shadowOpacity = 0.9
        paneMask.fillRule = .evenOdd
        masked.mask = paneMask
        masked.addSublayer(base)
        masked.addSublayer(flow)
        layer?.addSublayer(masked)
        layer?.addSublayer(port)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// The trace never takes clicks; they go to the tabs and terminal underneath.
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func clear() {
        guard !isHidden || drawn != nil else { return }
        drawn = nil
        isHidden = true
        flow.removeAnimation(forKey: "flow")
    }

    func update(_ route: Route, color: NSColor, animated: Bool) {
        // The pulse is re-added when AppKit has dropped it (e.g. after the window was hidden).
        if animated, flow.animation(forKey: "flow") == nil {
            let pulse = CABasicAnimation(keyPath: "lineDashPhase")
            pulse.fromValue = 0
            pulse.toValue = -204
            pulse.duration = 2.2
            pulse.repeatCount = .infinity
            flow.add(pulse, forKey: "flow")
        } else if !animated {
            flow.removeAnimation(forKey: "flow")
        }

        let next = Drawn(route: route, color: color, size: bounds.size, animated: animated)
        guard next != drawn else { return }
        drawn = next
        isHidden = false

        guard let start = route.points.first, let end = route.points.last, route.points.count > 1 else {
            clear()
            return
        }
        let path = CGMutablePath()
        path.move(to: start)
        // Round each inner corner by up to 7 points, less where a leg is short.
        for index in 1..<(route.points.count - 1) {
            let before = route.points[index - 1]
            let corner = route.points[index]
            let after = route.points[index + 1]
            let incoming = hypot(corner.x - before.x, corner.y - before.y)
            let outgoing = hypot(after.x - corner.x, after.y - corner.y)
            let reach = min(7, incoming / 2, outgoing / 2)
            guard reach >= 0.5 else {
                path.addLine(to: corner)
                continue
            }
            path.addLine(to: CGPoint(x: corner.x + (before.x - corner.x) / incoming * reach,
                                     y: corner.y + (before.y - corner.y) / incoming * reach))
            path.addQuadCurve(to: CGPoint(x: corner.x + (after.x - corner.x) / outgoing * reach,
                                          y: corner.y + (after.y - corner.y) / outgoing * reach),
                              control: corner)
        }
        path.addLine(to: end)

        let holes = CGMutablePath()
        holes.addRect(bounds.insetBy(dx: -40, dy: -40))
        for pane in route.panes where pane.width > 2 && pane.height > 2 {
            let r = max(0, min(route.radius, pane.width / 2, pane.height / 2))
            holes.addRoundedRect(in: pane, cornerWidth: r, cornerHeight: r)
        }

        CATransaction.begin()
        CATransaction.setDisableActions(true)
        masked.frame = bounds
        paneMask.frame = bounds
        paneMask.path = holes
        base.path = path
        flow.path = path
        base.strokeColor = color.withAlphaComponent(0.45).cgColor
        flow.strokeColor = color.cgColor
        flow.shadowColor = color.cgColor
        flow.isHidden = !animated
        port.backgroundColor = color.cgColor
        port.shadowColor = color.cgColor
        port.frame = CGRect(x: end.x - 3.5, y: end.y - 3.5, width: 7, height: 7)
        CATransaction.commit()
    }
}

/// Sigpane: the slim status line under the terminal in Signal windows. It follows the
/// focused pane. For an agent: its state and how long the turn has run, the model, the
/// permission mode, how full the context window is, the cost and the lines changed. For
/// a shell: the title and the key hints. Then which pane has focus, its size, the time.
private final class SignalStatusBar: NSView {
    struct Content: Equatable {
        var title = ""
        var pane = ""
        var size = ""
        /// The agent session in the focused pane, when there is one.
        var agent: AgentActivity.Session?
    }

    var theme = RoundedTabTheme.fallback { didSet { if theme != oldValue { needsDisplay = true } } }
    var color: NSColor = .controlAccentColor { didSet { if color != oldValue { needsDisplay = true } } }
    var content = Content() {
        didSet {
            guard content != oldValue else { return }
            needsDisplay = true
            updateClock()
        }
    }
    /// Keys worth remembering, most useful first. As many as fit are drawn in the free
    /// middle of the line.
    var hints: [SignalHints.Hint] = [] { didSet { if hints != oldValue { needsDisplay = true } } }
    private var clock: Timer?
    /// How often the line needs drawing again by itself: every second while it shows a
    /// running turn's time, otherwise once a minute for the clock.
    private var clockInterval: TimeInterval = 0
    /// Where the clock was last drawn, so a tick repaints only that.
    private var clockRect = NSRect.zero

    /// False while the window is not on screen; the clock stops ticking.
    var isLive = true {
        didSet { if isLive != oldValue { updateClock() } }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter
    }()

    override var isFlipped: Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateClock()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateClock()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateClock()
    }

    private func updateClock() {
        guard window != nil, isLive, !isHidden else {
            clock?.invalidate()
            clock = nil
            clockInterval = 0
            return
        }
        let wanted: TimeInterval = content.agent?.elapsed() != nil ? 1 : 60
        guard clock == nil || clockInterval != wanted else { return }
        clock?.invalidate()
        clockInterval = wanted
        needsDisplay = true
        // The clock shows minutes, so it only needs drawing as each minute starts. A
        // turn's time counts seconds, and is drawn each second while one is running.
        let now = Date().timeIntervalSinceReferenceDate
        let first = Date(timeIntervalSinceReferenceDate: (now / wanted).rounded(.down) * wanted + wanted)
        let timer = Timer(fire: first, interval: wanted, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                if self.clockInterval == 1 { self.needsDisplay = true } else { self.setNeedsDisplay(self.clockRect) }
            }
        }
        // Slack lets the system batch this wakeup with others.
        timer.tolerance = wanted == 1 ? 0.25 : 1
        RunLoop.main.add(timer, forMode: .common)
        clock = timer
    }

    /// Draws one piece of text on the status line and returns the x where it ends.
    private func put(_ string: String, at x: CGFloat, font: NSFont, color: NSColor,
                     maxWidth: CGFloat = .greatestFiniteMagnitude) -> CGFloat {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color, .paragraphStyle: style,
        ])
        let size = text.safeSize()
        let width = min(ceil(size.width), max(0, maxWidth))
        let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: width, height: size.height)
        text.safeDraw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
        return x + width
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        let fg = theme.foreground
        theme.background.withAlphaComponent(theme.backgroundOpacity).setFill()
        bounds.fill()
        fg.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()

        let regular = SignalFont.mono(10.5, .regular)
        let strong = SignalFont.mono(10.5, .semibold)

        // Trailing side first, so a long title on the leading side knows where to stop.
        var right = bounds.width - 14
        let trailing: [(String, CGFloat)] = [
            (Self.timeFormatter.string(from: Date()), 0.55), (content.size, 0.55), (content.pane, 0.32),
        ]
        for (index, (string, alpha)) in trailing.enumerated() where !string.isEmpty {
            let width = ceil(NSAttributedString(string: string, attributes: [.font: regular]).safeSize().width)
            guard right - width > 90 else { break }
            _ = put(string, at: right - width, font: regular, color: fg.withAlphaComponent(alpha))
            if index == 0 { clockRect = NSRect(x: right - width - 2, y: 0, width: width + 4, height: bounds.height) }
            right -= width + 16
        }

        var x: CGFloat = 14
        if let agent = content.agent {
            drawAgent(agent, from: x, to: right, regular: regular, strong: strong)
            return
        }
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.midY - 3).rounded(), width: 6, height: 6)).fill()
        x += 13
        // With hints to show, a long title gives up some of its room for them.
        let room = right - x
        let titleRoom = hints.isEmpty ? room : min(room, max(160, room * 0.38))
        if !content.title.isEmpty, room > 40 {
            x = put(content.title, at: x, font: regular, color: fg.withAlphaComponent(0.4), maxWidth: titleRoom)
        }
        // The clock repaints only itself every second; the hints are left of it.
        if !hints.isEmpty, dirtyRect.minX < right {
            drawHints(from: x + 28, to: right - 6)
        }
    }

    /// The focused pane's agent session, most important first; what does not fit is left out.
    private func drawAgent(_ agent: AgentActivity.Session, from start: CGFloat, to end: CGFloat,
                           regular: NSFont, strong: NSFont) {
        let fg = theme.foreground
        let phase = agent.phase
        let state = phase == .ready ? fg.withAlphaComponent(0.45) : phase.color
        var x = start
        func width(_ string: String, _ font: NSFont) -> CGFloat {
            ceil(NSAttributedString(string: string, attributes: [.font: font]).safeSize().width)
        }
        func fits(_ needed: CGFloat) -> Bool { x + needed <= end - 8 }

        state.setFill()
        NSBezierPath(ovalIn: NSRect(x: x, y: (bounds.midY - 3).rounded(), width: 6, height: 6)).fill()
        x += 13
        let label = agent.elapsed().map { "\(phase.label) \($0)" } ?? phase.label
        x = put(label, at: x, font: strong, color: state, maxWidth: max(0, end - x - 8)) + 14

        if let model = agent.model, fits(width(model, regular)) {
            x = put(model, at: x, font: regular, color: fg.withAlphaComponent(0.6)) + 12
        }
        if let mode = agent.modeLabel, fits(width(mode, regular) + 12) {
            let chip = NSRect(x: x + 0.5, y: (bounds.midY - 7.5).rounded() + 0.5, width: width(mode, regular) + 11, height: 14)
            let box = NSBezierPath(roundedRect: chip, xRadius: 4, yRadius: 4)
            // A mode that lets the agent act without asking stands out a little.
            let tone = agent.modeIsPermissive ? AgentActivity.Phase.approval.color : fg
            tone.withAlphaComponent(agent.modeIsPermissive ? 0.4 : 0.14).setStroke()
            box.lineWidth = 1
            box.stroke()
            _ = put(mode, at: x + 6, font: regular, color: tone.withAlphaComponent(agent.modeIsPermissive ? 0.95 : 0.6))
            x = chip.maxX + 14
        }
        if let percent = agent.context, fits(width("CTX", regular) + 110) {
            x = put("CTX", at: x, font: regular, color: fg.withAlphaComponent(0.34)) + 6
            // Ten cells, one for each tenth of the context window in use.
            let warning = AgentActivity.Session.contextColor(percent)
            let lit = Int((Double(percent) / 10).rounded())
            for cell in 0..<10 {
                (cell < lit ? (warning ?? color) : fg.withAlphaComponent(0.12)).setFill()
                NSBezierPath(roundedRect: NSRect(x: x, y: (bounds.midY - 4.5).rounded(), width: 5, height: 9),
                             xRadius: 1, yRadius: 1).fill()
                x += 6.5
            }
            x += 4
            x = put("\(percent)%", at: x, font: regular, color: warning ?? fg.withAlphaComponent(0.6)) + 6
            if let tokens = agent.tokensLabel, fits(width(tokens, regular)) {
                x = put(tokens, at: x, font: regular, color: fg.withAlphaComponent(0.34))
            }
            x += 14
        }
        if let cost = agent.cost {
            let text = String(format: "$%.2f", cost)
            if fits(width(text, regular)) {
                x = put(text, at: x, font: regular, color: fg.withAlphaComponent(0.6)) + 12
            }
        }
        // What the session has changed: how many files (from the hooks), and lines added
        // and removed (from the status line). Shown from the start, so it is clear where
        // the numbers will appear; dim while they are all zero.
        if let files = agent.filesLabel, fits(width(files, regular)) {
            x = put(files, at: x, font: regular, color: fg.withAlphaComponent(0.6)) + 8
        }
        if let added = agent.linesAdded, let removed = agent.linesRemoved,
           fits(width("+\(added) −\(removed)", regular) + 6) {
            let quiet = added + removed == 0
            x = put("+\(added)", at: x, font: regular,
                    color: quiet ? fg.withAlphaComponent(0.3) : AgentActivity.Phase.complete.color) + 6
            _ = put("−\(removed)", at: x, font: regular,
                    color: quiet ? fg.withAlphaComponent(0.3) : AgentActivity.Phase.error.color)
        }
    }

    /// The key hints, as many as fit, centered in the free stretch of the line: each a
    /// small key cap and what it does.
    private func drawHints(from start: CGFloat, to end: CGFloat) {
        let fg = theme.foreground
        let keyFont = SignalFont.mono(9.5, .semibold)
        let labelFont = SignalFont.mono(10, .regular)
        let gap: CGFloat = 18
        struct Piece {
            let keys: NSAttributedString
            let label: NSAttributedString
            let cap: CGFloat
            let width: CGFloat
        }
        var pieces: [Piece] = []
        var total: CGFloat = 0
        for hint in hints {
            let keys = NSAttributedString(string: hint.keys, attributes: [
                .font: keyFont, .foregroundColor: fg.withAlphaComponent(0.62), .kern: 0.6,
            ])
            let label = NSAttributedString(string: hint.label, attributes: [
                .font: labelFont, .foregroundColor: fg.withAlphaComponent(0.36),
            ])
            let cap = ceil(keys.safeSize().width) + 10
            let width = cap + 6 + ceil(label.safeSize().width)
            guard total + width + (pieces.isEmpty ? 0 : gap) <= end - start else { break }
            total += width + (pieces.isEmpty ? 0 : gap)
            pieces.append(Piece(keys: keys, label: label, cap: cap, width: width))
        }
        guard !pieces.isEmpty else { return }

        var x = (start + (end - start - total) / 2).rounded()
        let capHeight: CGFloat = 15
        let capY = ((bounds.height - capHeight) / 2).rounded()
        for piece in pieces {
            let box = NSBezierPath(
                roundedRect: NSRect(x: x + 0.5, y: capY + 0.5, width: piece.cap - 1, height: capHeight - 1),
                xRadius: 4, yRadius: 4)
            fg.withAlphaComponent(0.05).setFill()
            box.fill()
            fg.withAlphaComponent(0.16).setStroke()
            box.lineWidth = 1
            box.stroke()
            let keySize = piece.keys.safeSize()
            piece.keys.safeDraw(at: NSPoint(
                x: x + ((piece.cap - keySize.width) / 2).rounded(),
                y: capY + ((capHeight - keySize.height) / 2).rounded()))
            let labelSize = piece.label.safeSize()
            piece.label.safeDraw(at: NSPoint(
                x: x + piece.cap + 6, y: ((bounds.height - labelSize.height) / 2).rounded()))
            x += piece.width + gap
        }
    }
}

// MARK: - BaseTerminalController + terminalViewContainer

extension BaseTerminalController {
    var terminalViewContainer: TerminalViewContainer? {
        window?.contentView as? TerminalViewContainer
    }
}

// MARK: Glass

/// An `NSView` that contains a liquid glass background effect and
/// an inactive-window tint overlay.
#if compiler(>=6.2)
@available(macOS 26.0, *)
private class TerminalGlassView: NSView, ObservableObject {
    /// We use this to apply glass effect to background colors
    ///
    struct GlassBackground: View {
        @ObservedObject var model: GlassViewModel

        var body: some View {
            model.color
                .glassEffect(
                    model.glass,
                    in: RoundedRectangle(cornerRadius: model.cornerRadius)
                )
        }
    }

    class GlassViewModel: ObservableObject {
        @Published var backgroundColor: Color = .clear
        @Published var backgroundOpacity: Double = 0
        @Published var cornerRadius: CGFloat = 0
        @Published var glass: Glass = .identity

        /// backgroundColor applied with backgroundOpacity
        var color: Color {
            backgroundColor.opacity(backgroundOpacity)
        }
    }

    private let glassEffectView: NSView
    private var topConstraint: NSLayoutConstraint!
    private let glassViewModel: GlassViewModel

    init(topOffset: CGFloat) {
        let viewModel = GlassViewModel()
        self.glassEffectView = NSHostingView(rootView: GlassBackground(model: viewModel))
        self.glassViewModel = viewModel
        super.init(frame: .zero)

        translatesAutoresizingMaskIntoConstraints = false

        // Glass effect view fills this view.
        glassEffectView.translatesAutoresizingMaskIntoConstraints = false
        addSubview(glassEffectView)
        topConstraint = glassEffectView.topAnchor.constraint(
            equalTo: topAnchor,
            constant: topOffset
        )
        NSLayoutConstraint.activate([
            topConstraint,
            glassEffectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            glassEffectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            glassEffectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    /// Configures the glass, tint color, corner radius.
    func configure(
        glass: Glass,
        backgroundColor: NSColor,
        backgroundOpacity: Double,
        cornerRadius: CGFloat?,
    ) {
        glassViewModel.backgroundColor = Color(backgroundColor)
        glassViewModel.backgroundOpacity = backgroundOpacity
        glassViewModel.cornerRadius = cornerRadius ?? 0
        glassViewModel.glass = glass
    }

    /// Updates the top inset offset for both the glass effect and tint overlay.
    /// Call this when the safe area insets change (e.g., during layout).
    func updateTopInset(_ offset: CGFloat) {
        topConstraint.constant = offset
    }
}
#endif // compiler(>=6.2)

extension TerminalViewContainer {
#if compiler(>=6.2)
    @available(macOS 26.0, *)
    private func addGlassEffectViewIfNeeded() -> TerminalGlassView? {
        if let existed = glassEffectView as? TerminalGlassView {
            updateGlassEffectTopInsetIfNeeded()
            return existed
        }
        guard let themeFrameView = windowThemeFrameView else {
            return nil
        }
        let effectView = TerminalGlassView(topOffset: -themeFrameView.safeAreaInsets.top)
        addSubview(effectView, positioned: .below, relativeTo: terminalView)
        NSLayoutConstraint.activate([
            effectView.topAnchor.constraint(equalTo: topAnchor),
            effectView.leadingAnchor.constraint(equalTo: leadingAnchor),
            effectView.bottomAnchor.constraint(equalTo: bottomAnchor),
            effectView.trailingAnchor.constraint(equalTo: trailingAnchor),
        ])
        glassEffectView = effectView
        return effectView
    }
#endif // compiler(>=6.2)

    private func updateGlassEffectIfNeeded() {
#if compiler(>=6.2)
        guard #available(macOS 26.0, *), let derivedConfig else {
            glassEffectView?.removeFromSuperview()
            glassEffectView = nil
            return
        }
        guard let effectView = addGlassEffectViewIfNeeded() else {
            return
        }

        effectView.configure(
            glass: derivedConfig.glass.official,
            backgroundColor: derivedConfig.backgroundColor,
            backgroundOpacity: derivedConfig.backgroundOpacity,
            cornerRadius: derivedConfig.cornerRadius,
        )
#endif // compiler(>=6.2)
    }

    private func updateGlassEffectTopInsetIfNeeded() {
#if compiler(>=6.2)
        guard
            #available(macOS 26.0, *),
            let effectView = glassEffectView as? TerminalGlassView,
            let themeFrameView = windowThemeFrameView
        else {
            return
        }
        effectView.updateTopInset(-themeFrameView.safeAreaInsets.top)
#endif // compiler(>=6.2)
    }

    struct DerivedConfig: Equatable {
        let glass: BackportGlass
        let backgroundColor: NSColor
        let backgroundOpacity: Double
        let cornerRadius: CGFloat?

        init?(config: Ghostty.Config, preferredBackgroundColor: NSColor?, cornerRadius: CGFloat?) {
            switch config.backgroundBlur {
            case .macosGlassRegular:
                glass = .regular
            case .macosGlassClear:
                glass = .clear
            default:
                return nil
            }
            self.backgroundColor = preferredBackgroundColor ?? NSColor(config.backgroundColor)
            self.backgroundOpacity = config.backgroundOpacity
            self.cornerRadius = cornerRadius
        }
    }
}

/// Sigpane: the sweep that crosses a terminal when its tab comes forward. A thin line in
/// the window's color travels across with a short glow trailing it. Nothing under it is
/// darkened. It is only on screen for the length of the sweep.
private final class SignalArrivalView: NSView {
    var color: NSColor = .controlAccentColor
    /// Along the width (top and bottom tab strips) instead of down the height.
    var horizontal = false
    /// Towards the far edge (a later tab) or back from it.
    var forward = true
    /// 0 as the sweep starts, 1 once it has crossed.
    var progress: CGFloat = 1 { didSet { needsDisplay = true } }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        guard progress < 1, bounds.width > 1, bounds.height > 1 else { return }

        // The line fades in as it leaves one edge and out as it reaches the other.
        let strength = sin(progress * .pi)
        let length = horizontal ? bounds.width : bounds.height
        let at = (forward ? progress : 1 - progress) * length
        let tail: CGFloat = forward ? -110 : 110
        let glow = horizontal
            ? NSRect(x: min(at, at + tail), y: 0, width: abs(tail), height: bounds.height)
            : NSRect(x: 0, y: min(at, at + tail), width: bounds.width, height: abs(tail))
        // The glow is brightest at the line and gone at the end of the tail.
        let gradient = NSGradient(
            starting: color.withAlphaComponent(forward ? 0 : 0.16 * strength),
            ending: color.withAlphaComponent(forward ? 0.16 * strength : 0))
        gradient?.draw(in: glow, angle: horizontal ? 0 : 90)

        color.withAlphaComponent(0.9 * strength).setFill()
        let line = horizontal
            ? NSRect(x: at - 0.75, y: 0, width: 1.5, height: bounds.height)
            : NSRect(x: 0, y: at - 0.75, width: bounds.width, height: 1.5)
        line.fill(using: .sourceOver)
    }
}
