import AppKit
import Combine
import GhosttyKit

/// Presents native AppKit tab groups without taking ownership of terminal sessions.
/// Window references are weak so a closed tab cannot be retained by its own chrome.
/// The settings preview subclasses this with sample tabs (`PreviewTabModel`).
@MainActor
class RoundedTerminalTabModel: ObservableObject {
    struct Tab: Identifiable {
        let id: ObjectIdentifier
        let window: Weak<NSWindow>
        let title: String
        let color: TerminalTabColor
        let selected: Bool
        /// Random color slot (index into `TabBarSettings.randomPaletteIndices`).
        var autoColor: Int?
        /// Second line of a Signal session card: the tab's working directory.
        var subtitle: String?
        /// The directory's own name, set when the title is nothing but the directory
        /// (what shells show by default), so a card does not say the same path twice.
        var shortTitle: String?
        var activity = AgentActivity.Summary()

        /// The title a Signal card, chip or titlebar shows.
        var displayTitle: String { shortTitle ?? title }
    }

    /// The focused pane's working directory.
    static func directory(of window: NSWindow) -> String? {
        guard let pwd = (window.windowController as? BaseTerminalController)?.focusedSurface?.pwd,
              !pwd.isEmpty else { return nil }
        return pwd
    }

    /// The directory's last component ("~" for home) when `title` is only that directory.
    static func shortTitle(_ title: String, directory: String?) -> String? {
        guard let directory, SignalText.isDirectoryTitle(title, path: directory) else { return nil }
        let tilde = SignalText.tilde(directory)
        return tilde == "~" || directory == "/" ? tilde : (directory as NSString).lastPathComponent
    }

    /// Picks a random color slot that differs from the given neighbours.
    static func randomColorSlot(avoiding neighbours: [Int?]) -> Int {
        let count = TabBarSettings.randomPaletteIndices.count
        let taken = Set(neighbours.compactMap { $0 })
        let choices = (0..<count).filter { !taken.contains($0) }
        return (choices.isEmpty ? Array(0..<count) : choices).randomElement() ?? 0
    }

    /// Gives every tab in every Sigpane tab group a new random color.
    static func shuffleAllColors() {
        var seen = Set<ObjectIdentifier>()
        for window in NSApp.windows.compactMap({ $0 as? TerminalWindow }) {
            let windows = window.tabGroup?.windows ?? [window]
            guard let first = windows.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            var previous: Int?
            for case let tab as TerminalWindow in windows {
                tab.autoTabColorSlot = randomColorSlot(avoiding: [previous])
                previous = tab.autoTabColorSlot
            }
        }
        NotificationCenter.default.post(name: .ghosttyXTabColorsDidShuffle, object: nil)
    }

    @Published var tabs: [Tab] = []
    weak var hostWindow: TerminalWindow?
    private weak var observedGroup: NSWindowTabGroup?
    private var groupObservations: [NSKeyValueObservation] = []
    private var titleObservations: [NSKeyValueObservation] = []
    private var refreshScheduled = false
    /// Whether the host window has been seen on screen. Until it has, nothing is skipped:
    /// a window that is still being set up is not "behind".
    private var hostWasOnScreen = false
    private var activityObservation: AnyCancellable?

    init(hostWindow: TerminalWindow?) {
        self.hostWindow = hostWindow
        if hostWindow != nil {
            // An agent's state changes with every tool it uses. Every tab is a window with
            // strips of its own, and the ones behind are refreshed when they come forward,
            // so only the strip on screen follows these.
            activityObservation = NotificationCenter.default.publisher(for: AgentActivityChannel.didChange)
                .sink { [weak self] _ in self?.scheduleRefresh(ifOnScreen: true) }
        }
    }

    func refresh() {
        guard let hostWindow else { tabs = []; return }
        if hostWindow.occlusionState.contains(.visible) { hostWasOnScreen = true }
        let group = hostWindow.tabGroup
        if observedGroup !== group {
            observedGroup = group
            groupObservations = []
            if let group {
                groupObservations = [
                    group.observe(\.windows) { [weak self] _, _ in self?.scheduleRefresh() },
                    group.observe(\.selectedWindow) { [weak self] _, _ in self?.scheduleRefresh() },
                ]
            }
        }
        let windows = group?.windows ?? [hostWindow]
        let ids = windows.map(ObjectIdentifier.init)
        if ids != tabs.map(\.id) {
            // Programs retitle their tabs all the time (an agent does it every turn), and
            // every tab is a window with strips of its own that watch every title. The
            // strips behind are refreshed as they come forward, so only the one on
            // screen follows titles.
            titleObservations = windows.map { window in
                window.observe(\.title) { [weak self] _, _ in self?.scheduleRefresh(ifOnScreen: true) }
            }
        }
        // New tabs pick a color unlike the tabs on either side of them.
        let terminals = windows.map { $0 as? TerminalWindow }
        var assignedColor = false
        for (index, terminal) in terminals.enumerated() where terminal?.autoTabColorSlot == nil {
            guard let terminal else { continue }
            let before = index > 0 ? terminals[index - 1]?.autoTabColorSlot : nil
            let after = index + 1 < terminals.count ? terminals[index + 1]?.autoTabColorSlot : nil
            terminal.autoTabColorSlot = Self.randomColorSlot(avoiding: [before, after])
            assignedColor = true
        }
        if assignedColor {
            // Panes read their tint from the window, so tell them once it has a color.
            DispatchQueue.main.async {
                NotificationCenter.default.post(name: .ghosttyXTabColorsDidShuffle, object: nil)
            }
        }
        tabs = windows.map { window in
            SignalDemo.trace("title [\(window.title)]")
            let clean = SignalText.chromeSafe(window.title)
            let title = clean.isEmpty ? "Terminal" : clean
            let directory = Self.directory(of: window)
            return Tab(id: ObjectIdentifier(window), window: Weak(window),
                       title: title,
                       color: (window as? TerminalWindow)?.tabColor ?? .none,
                       selected: window === (group?.selectedWindow ?? hostWindow),
                       autoColor: (window as? TerminalWindow)?.autoTabColorSlot,
                       subtitle: directory.map { SignalText.chromeSafe(SignalText.abbreviate(path: $0)) },
                       shortTitle: Self.shortTitle(title, directory: directory),
                       activity: Self.activity(of: window))
        }
    }

    private static func activity(of window: NSWindow) -> AgentActivity.Summary {
        guard let controller = window.windowController as? BaseTerminalController else { return .init() }
        return .init(sessions: controller.surfaceTree.flatMap { $0.agentActivity.summary.sessions })
    }

    /// `ifOnScreen` is for changes a strip only has to show, not act on: one in a tab that
    /// is behind skips them, and catches up when its window comes forward (the window
    /// refreshes its strips as it becomes key or main).
    nonisolated func scheduleRefresh(ifOnScreen: Bool = false) {
        DispatchQueue.main.async { [weak self] in
            guard let self, !self.refreshScheduled else { return }
            if ifOnScreen, self.hostWasOnScreen,
               self.hostWindow?.occlusionState.contains(.visible) == false { return }
            self.refreshScheduled = true
            // Rebind observations after the KVO callback has returned.
            DispatchQueue.main.async { [weak self] in
                self?.refreshScheduled = false
                self?.refresh()
            }
        }
    }

    func select(_ tab: Tab) {
        guard let window = tab.window.value else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
    }

    func close(_ tab: Tab) {
        // Uses Ghostty's confirmation/undo path; never terminate a shell directly.
        (tab.window.value?.windowController as? TerminalController)?.closeTab(nil)
    }

    func move(_ tab: Tab, by offset: Int) {
        guard let window = tab.window.value,
              let group = window.tabGroup,
              let index = group.windows.firstIndex(of: window) else { return }
        let destination = min(max(index + offset, 0), group.windows.count - 1)
        guard destination != index else { return }
        group.insertWindow(window, at: destination)
        scheduleRefresh()
    }

    func reorder(_ identifiers: [String], before destination: Tab) -> Bool {
        guard let id = identifiers.first,
              let source = tabs.first(where: { String(describing: $0.id) == id }),
              let sourceWindow = source.window.value,
              let targetWindow = destination.window.value,
              let group = targetWindow.tabGroup,
              group.windows.contains(sourceWindow),
              let index = group.windows.firstIndex(of: targetWindow) else { return false }
        group.insertWindow(sourceWindow, at: index)
        scheduleRefresh()
        return true
    }

    func newTab() { hostWindow?.terminalController?.newTab(nil) }

    func rename(_ tab: Tab) {
        select(tab)
        (tab.window.value?.windowController as? TerminalController)?.promptTabTitle()
    }

    func detach(_ tab: Tab) { tab.window.value?.moveTabToNewWindow(nil) }

    func setColor(_ color: TerminalTabColor, for tab: Tab) {
        (tab.window.value as? TerminalWindow)?.tabColor = color
        refresh()
    }

    func shuffleColors() { Self.shuffleAllColors() }
}

extension Notification.Name {
    static let ghosttyXTabColorsDidShuffle = Notification.Name("com.amsynist.ghosttyx.tabColorsDidShuffle")
}

/// Colors for the tab strip, taken from the active Ghostty theme so the chrome matches
/// the terminal. The accent is a palette entry picked in the Tab Bar settings.
struct RoundedTabTheme: Equatable {
    var foreground: NSColor
    var background: NSColor
    /// `background-opacity`; edge bars paint the terminal background themselves.
    var backgroundOpacity: CGFloat = 1
    var palette: [NSColor]

    /// Tokyo Night values, used until a Ghostty config is available.
    static let fallback = RoundedTabTheme(
        foreground: NSColor(srgbRed: 0.753, green: 0.792, blue: 0.961, alpha: 1),
        background: NSColor(rgb: 0x1a1b26),
        palette: [
            0x15161e, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xa9b1d6,
            0x414868, 0xf7768e, 0x9ece6a, 0xe0af68, 0x7aa2f7, 0xbb9af7, 0x7dcfff, 0xc0caf5,
        ].map { NSColor(rgb: $0) })

    init(foreground: NSColor, background: NSColor, palette: [NSColor]) {
        self.foreground = foreground
        self.background = background
        self.palette = palette
    }

    init(config: Ghostty.Config) {
        let fallback = Self.fallback
        foreground = config.roundedTabColor("foreground") ?? fallback.foreground
        background = config.roundedTabColor("background") ?? fallback.background
        backgroundOpacity = CGFloat(min(max(config.backgroundOpacity, 0), 1))
        let palette = config.roundedTabPalette ?? []
        self.palette = palette.count >= 16 ? palette : fallback.palette
    }

    static var current: RoundedTabTheme {
        guard let delegate = NSApp.delegate as? AppDelegate else { return fallback }
        return RoundedTabTheme(config: delegate.ghostty.config)
    }

    func accent(_ accent: TabBarSettings.Accent) -> NSColor {
        guard let index = accent.paletteIndex, palette.indices.contains(index) else { return foreground }
        return palette[index]
    }

    /// The palette color for a random tab color slot.
    func color(slot: Int) -> NSColor? {
        let indices = TabBarSettings.randomPaletteIndices
        let index = indices[abs(slot) % indices.count]
        return palette.indices.contains(index) ? palette[index] : nil
    }

    /// A tab's color: picked by hand first, else its random palette color.
    func color(picked: TerminalTabColor, slot: Int?, settings: TabBarSettings) -> NSColor? {
        if let color = picked.displayColor { return color }
        guard settings.tabColors == .random, let slot else { return nil }
        return color(slot: slot)
    }

    /// The color a window's Signal chrome is tinted with: its tab's color while the tint
    /// follows the tab, else the accent.
    @MainActor
    func signal(for window: NSWindow?, settings: TabBarSettings) -> NSColor {
        let fallback = self.accent(settings.accent)
        guard settings.tintFollowsTab, let window = window as? TerminalWindow else { return fallback }
        return color(picked: window.tabColor, slot: window.autoTabColorSlot, settings: settings) ?? fallback
    }
}

private extension NSColor {
    convenience init(rgb: Int) {
        self.init(srgbRed: CGFloat((rgb >> 16) & 0xff) / 255, green: CGFloat((rgb >> 8) & 0xff) / 255,
                  blue: CGFloat(rgb & 0xff) / 255, alpha: 1)
    }
}

extension Ghostty.Config {
    fileprivate func roundedTabColor(_ key: String) -> NSColor? {
        guard let config else { return nil }
        var color = ghostty_config_color_s()
        guard ghostty_config_get(config, &color, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return NSColor(srgbRed: CGFloat(color.r) / 255, green: CGFloat(color.g) / 255,
                       blue: CGFloat(color.b) / 255, alpha: 1)
    }

    fileprivate var roundedTabPalette: [NSColor]? {
        guard let config else { return nil }
        var palette = ghostty_config_palette_s()
        let key = "palette"
        guard ghostty_config_get(config, &palette, key, UInt(key.lengthOfBytes(using: .utf8))) else { return nil }
        return withUnsafeBytes(of: &palette.colors) { raw in
            raw.bindMemory(to: ghostty_config_color_s.self).prefix(16).map {
                NSColor(srgbRed: CGFloat($0.r) / 255, green: CGFloat($0.g) / 255, blue: CGFloat($0.b) / 255, alpha: 1)
            }
        }
    }
}

/// The capsule tab strip. One component serves every position:
/// - `.titlebar`: inside the native titlebar accessory, shown when the position is Top.
///   For other positions it becomes an empty, draggable placeholder that shields the
///   hidden native tab bar from clicks.
/// - `.edge`: beside the terminal content (bottom bar or left/right sidebar).
/// - `.preview`: the settings window's live preview; always follows the chosen position.
///
/// Native controls are important here: this view can live inside AppKit's titlebar
/// accessory, where hosting-view drag handling can consume SwiftUI button clicks.
@MainActor
final class RoundedTerminalTabBar: NSView {
    enum Placement { case titlebar, edge, preview }

    let model: RoundedTerminalTabModel
    let placement: Placement
    private let store: TabBarSettingsStore
    private let scroll = NSScrollView()
    private let document = FlippedTabDocument()
    private let addButton = TabAddButton()
    private let approvalButton = NSButton()
    private let sectionLabels = (0...AgentActivity.Provider.allCases.count).map { _ in NSTextField(labelWithString: "") }
    private let header = NSTextField(labelWithString: "")
    private let headerCount = NSTextField(labelWithString: "")
    private var cells: [ObjectIdentifier: RoundedTabCell] = [:]
    private var observations: [AnyCancellable] = []
    private(set) var displayedTabs: [RoundedTerminalTabModel.Tab] = []

    // Signal interface
    private let indicator = TabSelectionIndicator()
    private var indicatorTarget: NSRect?
    private var hasPopulated = false
    private var loadSamples: [Double] = []
    private var loadTimer: Timer?
    /// Held while a session card is showing a turn's time, so the time is redrawn each second.
    private var clockHold: AgentClock.Token?
    /// Where the titlebar's "needs approval" pill was last drawn; a click there goes to it.
    private var attentionRect = NSRect.zero
    private lazy var actionButtons: [TitlebarActionButton] = {
        let kinds: [TitlebarActionButton.Kind] = [.splitRight, .splitDown, .commands]
        return kinds.map { kind in
            let button = TitlebarActionButton()
            button.kind = kind
            button.toolTip = kind.title
            button.setAccessibilityLabel(kind.title)
            button.onMouseDown = { [weak self] _ in self?.perform(kind) }
            return button
        }
    }()

    private let railToggle = RailToggleButton()
    /// When this bar last animated a selection change, so one change animates once.
    private var animatedChangeAt: TimeInterval = 0
    private let indicatorMotion = SignalMotion()
    /// Tabs whose arrival this bar has already shown (or that were never new to it).
    private var entered: Set<ObjectIdentifier> = []

    /// The latest selection change in each tab group. Every tab is its own window with its
    /// own strip, so the strip that comes forward reads where the selection came from here.
    private struct SelectionChange {
        var previous: ObjectIdentifier?
        var current: ObjectIdentifier
        var at: TimeInterval
    }
    private static var selectionHistory: [ObjectIdentifier: SelectionChange] = [:]

    private var groupKey: ObjectIdentifier {
        if let group = model.hostWindow?.tabGroup { return ObjectIdentifier(group) }
        return ObjectIdentifier(model)
    }

    /// Called when the selected tab's color changes (the window's Signal chrome follows it).
    var onSignalChange: (() -> Void)?

    /// Called on the selected tab's own strip when the selection has just moved to it.
    /// The argument is how many positions it moved (negative is towards the first tab).
    var onSelectionChange: ((Int) -> Void)?

    /// False while this strip's window is not on screen; its timers stop.
    var isLive = true {
        didSet { if isLive != oldValue { updateLoadTimer() } }
    }

    static var reduceMotion: Bool { NSWorkspace.shared.accessibilityDisplayShouldReduceMotion }

    /// How long motion in a window should hold before it starts. A window made a moment
    /// ago is still starting its terminal and laying itself out, and anything that moved
    /// through that would stutter or be missed.
    static func settleDelay(for window: NSWindow?) -> TimeInterval {
        guard let window = window as? TerminalWindow else { return 0 }
        return ProcessInfo.processInfo.systemUptime - window.bornAt < 0.7 ? 0.24 : 0
    }

    private(set) var settings: TabBarSettings
    var theme = RoundedTabTheme.current {
        didSet { if theme != oldValue { applyAppearance() } }
    }

    /// Called whenever the number of tabs changes (edge bars hide with a single tab).
    var onTabCountChange: ((Int) -> Void)?

    /// True when the strip should draw as a vertical sidebar.
    var isVertical: Bool { placement != .titlebar && settings.position.isVertical }

    /// In the titlebar while tabs live elsewhere: draw nothing, move the window on drag.
    var isPlaceholder: Bool { placement == .titlebar && settings.position != .top }

    /// A sidebar in the Signal design: session cards with a sliding selection.
    var isSignalRail: Bool { isVertical && settings.isSignal }

    /// A horizontal strip (top or bottom) in the Signal design: chips with a sliding selection.
    var isSignalStrip: Bool { !isVertical && !isPlaceholder && settings.isSignal }

    /// A Signal sidebar shrunk to its numbered tiles.
    var isRailCollapsed: Bool { isSignalRail && settings.sidebarCollapsed }

    /// A tab's color: picked by hand first, else its random palette color.
    func color(for tab: RoundedTerminalTabModel.Tab) -> NSColor? {
        theme.color(picked: tab.color, slot: tab.autoColor, settings: settings)
    }

    /// The color the Signal chrome takes: the selected tab's color, else the accent.
    var signalColor: NSColor {
        let accent = theme.accent(settings.accent)
        guard settings.tintFollowsTab, let selected = displayedTabs.first(where: \.selected) else { return accent }
        return color(for: selected) ?? accent
    }

    /// Frame of the selected tab in this bar's coordinates while it is scrolled into view.
    var selectedTabFrame: NSRect? {
        guard let index = displayedTabs.firstIndex(where: \.selected), let frame = tabFrame(at: index),
              scroll.frame.insetBy(dx: -1, dy: -1).contains(NSPoint(x: frame.midX, y: frame.midY)) else { return nil }
        return frame
    }

    private var showsActions: Bool { isPlaceholder && settings.isSignal && settings.titlebarActions }

    private var agentSummary: AgentActivity.Summary {
        .init(sessions: displayedTabs.flatMap(\.activity.sessions))
    }

    private var groupsAgentSessions: Bool {
        isSignalRail && settings.groupAgentSessions && agentSummary.primary != nil
    }

    private var sidebarGroups: [(name: String?, symbol: String, tabs: [RoundedTerminalTabModel.Tab])] {
        guard groupsAgentSessions else { return [(nil, "", displayedTabs)] }
        let providers = AgentActivity.Provider.allCases.map(Optional.some) + [nil]
        return providers.compactMap { provider in
            let tabs = displayedTabs.filter { $0.activity.sessions.first?.provider == provider }
            guard !tabs.isEmpty else { return nil }
            let symbol = switch provider {
            case .claude: "✦"
            case .codex: "‹/›"
            case nil: "❯"
            }
            return (provider?.name ?? "Shell", symbol, tabs)
        }
    }

    private var hasPendingApproval: Bool { agentSummary.primary == .approval }

    private var showsApprovalShortcut: Bool {
        isSignalRail && settings.showApprovalShortcut && hasPendingApproval && bounds.height >= 140
    }

    private var horizontalActivityWidth: CGFloat {
        guard isSignalStrip, bounds.width >= 300 else { return 0 }
        let counts = agentSummary.visibleCounts
        guard !counts.isEmpty else { return 0 }
        return counts.reduce(8) { width, item in
            width + ceil(activityCount("\(item.phase.glyph) \(item.count)", color: item.phase.color).safeSize().width) + 14
        }
    }

    /// Height reserved for the session overview or load sparkline.
    private var footerHeight: CGFloat {
        guard isSignalRail else { return 0 }
        let overview: CGFloat = if agentSummary.primary != nil {
            isRailCollapsed ? 17 : 56
        } else {
            !isRailCollapsed && settings.systemLoad ? 34 : 0
        }
        return overview + (showsApprovalShortcut ? 29 : 0)
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    convenience init(hostWindow: TerminalWindow, placement: Placement = .titlebar,
                     store: TabBarSettingsStore = .shared) {
        self.init(model: RoundedTerminalTabModel(hostWindow: hostWindow), placement: placement, store: store)
    }

    init(model: RoundedTerminalTabModel, placement: Placement, store: TabBarSettingsStore = .shared) {
        self.model = model
        self.placement = placement
        self.store = store
        self.settings = store.settings
        super.init(frame: .zero)
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasHorizontalScroller = false
        scroll.hasVerticalScroller = false
        scroll.automaticallyAdjustsContentInsets = false
        scroll.documentView = document
        document.addSubview(indicator)
        indicator.isHidden = true
        addButton.target = self
        addButton.action = #selector(newTab)
        addButton.toolTip = "New tab"
        addButton.setAccessibilityLabel("New tab")
        addButton.menuProvider = { [weak self] in self?.barMenu() }
        header.font = SignalFont.system(10.5, .semibold)
        header.isSelectable = false
        header.lineBreakMode = .byClipping
        addSubview(scroll)
        addSubview(header)
        headerCount.font = SignalFont.digits(10.5, .semibold)
        headerCount.alignment = .right
        headerCount.isSelectable = false
        addSubview(headerCount)
        addSubview(addButton)
        approvalButton.bezelStyle = .inline
        approvalButton.controlSize = .small
        approvalButton.image = NSImage(systemSymbolName: "arrow.up.right", accessibilityDescription: nil)
        approvalButton.contentTintColor = AgentActivity.Phase.approval.color
        approvalButton.target = self
        approvalButton.action = #selector(jumpToApproval)
        approvalButton.toolTip = "Next approval"
        approvalButton.setAccessibilityLabel("Next approval")
        addSubview(approvalButton)
        for label in sectionLabels {
            label.font = SignalFont.mono(10, .medium)
            label.lineBreakMode = .byTruncatingTail
            document.addSubview(label)
        }
        for button in actionButtons { addSubview(button) }
        railToggle.onMouseDown = { [weak self] _ in self?.toggleSidebar() }
        railToggle.setAccessibilityLabel("Collapse or expand the sidebar")
        addSubview(railToggle)
        setAccessibilityElement(false)
        observations = [
            model.$tabs.sink { [weak self] tabs in self?.reconcile(tabs) },
            store.$settings.sink { [weak self] settings in self?.settingsDidChange(settings) },
        ]
        applyAppearance()
        // Follow config reloads (e.g. a theme change) without reopening the window.
        NotificationCenter.default.addObserver(
            self, selector: #selector(configDidChange(_:)), name: .ghosttyConfigDidChange, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(colorsDidShuffle), name: .ghosttyXTabColorsDidShuffle, object: nil)
        NotificationCenter.default.addObserver(
            self, selector: #selector(clockDidTick), name: AgentClock.didTick, object: nil)
    }

    /// A second has passed: the cards that show a turn's time draw it again.
    @objc private func clockDidTick() {
        guard clockHold != nil else { return }
        for tab in displayedTabs where tab.activity.lead?.elapsed() != nil {
            guard let cell = cells[tab.id], cell.frame.intersects(document.visibleRect) else { continue }
            cell.needsDisplay = true
        }
    }

    @objc private func colorsDidShuffle() { model.refresh() }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    @objc private func configDidChange(_ notification: Notification) {
        // Only the global config carries the theme; surface-level changes don't.
        guard notification.object == nil else { return }
        theme = RoundedTabTheme.current
    }

    func refresh() {
        theme = RoundedTabTheme.current
        model.refresh()
    }

    private func settingsDidChange(_ settings: TabBarSettings) {
        let wasVertical = isVertical
        self.settings = settings
        if wasVertical != isVertical { attachAddButton() }
        applyAppearance()
        reconcile(model.tabs)
    }

    private func applyAppearance() {
        scroll.isHidden = isPlaceholder
        addButton.isHidden = isPlaceholder
        header.isHidden = isPlaceholder || !isVertical || isRailCollapsed
        headerCount.isHidden = header.isHidden
        railToggle.isHidden = isPlaceholder || !isSignalRail
        railToggle.tint = theme.foreground
        railToggle.collapsed = isRailCollapsed
        railToggle.toolTip = isRailCollapsed ? "Expand sidebar" : "Collapse sidebar"
        updateHeader()
        addButton.theme = theme
        addButton.settings = settings
        addButton.isRow = isVertical
        addButton.compact = isRailCollapsed
        for button in actionButtons {
            button.isHidden = !showsActions
            button.tint = theme.foreground
        }
        syncSignalColor()
        updateLoadTimer()
        for cell in cells.values { cell.appearanceDidChange() }
        needsLayout = true
        needsDisplay = true
    }

    private func updateHeader() {
        let signal = isSignalRail
        let color = theme.foreground.withAlphaComponent(signal ? 0.32 : 0.4)
        let font: NSFont = signal
            ? SignalFont.mono(10, .medium)
            : SignalFont.system(10.5, .semibold)
        let countFont: NSFont = signal ? font : SignalFont.digits(10.5, .semibold)
        let trailing = NSMutableParagraphStyle()
        trailing.alignment = .right
        header.attributedStringValue = NSAttributedString(string: signal ? "SESSIONS" : "TABS", attributes: [
            .font: font, .foregroundColor: color, .kern: signal ? 2.0 : 0.0,
        ])
        let count = displayedTabs.count
        headerCount.attributedStringValue = NSAttributedString(
            string: signal ? SignalText.ordinal(count - 1) : "\(count)",
            attributes: [.font: countFont, .foregroundColor: color, .paragraphStyle: trailing])
    }

    /// Pushes the selected tab's color to everything that is tinted by it.
    private func syncSignalColor() {
        let color = signalColor
        addButton.signalColor = isSignalRail ? color : nil
        indicator.color = color
        indicator.glow = settings.focusGlow
        needsDisplay = true
        onSignalChange?()
    }

    /// Horizontal strips keep `+` beside the scroller; sidebars scroll it with the list.
    private func attachAddButton() {
        let parent: NSView = isVertical ? document : self
        guard addButton.superview !== parent else { return }
        addButton.removeFromSuperview()
        parent.addSubview(addButton)
    }

    @objc private func newTab() { model.newTab() }
    @objc private func toggleSidebar() { store.settings.sidebarCollapsed.toggle() }

    @objc private func jumpToApproval() {
        let tabs = sidebarGroups.flatMap(\.tabs)
        guard hasPendingApproval, !tabs.isEmpty else { return }
        let from = tabs.firstIndex(where: \.selected) ?? (tabs.count - 1)
        for offset in 1...tabs.count {
            let tab = tabs[(from + offset) % tabs.count]
            guard tab.activity.primary == .approval else { continue }
            model.select(tab)
            if let controller = tab.window.value?.windowController as? BaseTerminalController,
               let pane = controller.surfaceTree.first(where: { $0.agentActivity.summary.primary == .approval }) {
                Ghostty.moveFocus(to: pane)
            }
            return
        }
    }

    private func reconcile(_ tabs: [RoundedTerminalTabModel.Tab]) {
        let countChanged = tabs.count != displayedTabs.count
        let shouldRevealSelection = tabs.map(\.id) != displayedTabs.map(\.id)
            || tabs.first(where: \.selected)?.id != displayedTabs.first(where: \.selected)?.id
        displayedTabs = tabs
        let keep = Set(tabs.map(\.id))
        for id in cells.keys where !keep.contains(id) {
            cells.removeValue(forKey: id)?.removeFromSuperview()
        }
        entered.formIntersection(keep)
        // Each tab is its own window with its own strip. A strip that is not on screen
        // shows nothing, so it leaves arrivals for when it comes forward.
        let onScreen = window?.isFrontTab == true
        let now = ProcessInfo.processInfo.systemUptime
        if let selected = tabs.first(where: \.selected) {
            let key = groupKey
            let known = Self.selectionHistory[key]
            if known?.current != selected.id {
                // Entries are tiny, but closed tab groups would otherwise stay forever.
                if Self.selectionHistory.count > 64 { Self.selectionHistory.removeAll() }
                Self.selectionHistory[key] = SelectionChange(previous: known?.current, current: selected.id, at: now)
            }
        }
        for (index, tab) in tabs.enumerated() {
            let cell = cells[tab.id] ?? RoundedTabCell(owner: self)
            var entering = false
            if cell.superview == nil {
                document.addSubview(cell)
                cells[tab.id] = cell
                if !(tab.window.value is TerminalWindow) { entering = hasPopulated }
            }
            // A tab that was just opened animates in, once, in the strip that is showing.
            // Tabs that were already there do not.
            if let window = tab.window.value as? TerminalWindow, !entered.contains(tab.id) {
                if now - window.bornAt > 2 {
                    entered.insert(tab.id)
                } else if onScreen {
                    entered.insert(tab.id)
                    entering = true
                }
            }
            cell.update(tab, index: index, count: tabs.count, entering: entering)
        }
        if !tabs.isEmpty { hasPopulated = true }
        attachAddButton()
        updateHeader()
        syncSignalColor()
        updateLoadTimer()
        needsLayout = true
        needsDisplay = true
        layoutSubtreeIfNeeded()
        if shouldRevealSelection,
           let selected = tabs.first(where: \.selected), let cell = cells[selected.id] {
            document.scrollToVisible(cell.frame.insetBy(dx: -8, dy: -8))
        }
        if countChanged { onTabCountChange?(tabs.count) }
    }

    // MARK: Layout

    override func layout() {
        super.layout()
        approvalButton.isHidden = !showsApprovalShortcut
        for label in sectionLabels { label.isHidden = true }
        guard !isPlaceholder else { layoutActions(); return }
        if isVertical { layoutVertical() } else { layoutHorizontal() }
    }

    /// Titlebar buttons sit at the trailing end of the placeholder strip.
    private func layoutActions() {
        var x = bounds.width - 10
        for button in actionButtons.reversed() {
            x -= 28
            button.frame = NSRect(x: x, y: ((bounds.height - 24) / 2).rounded(), width: 28, height: 24)
            x -= 2
        }
    }

    private func perform(_ kind: TitlebarActionButton.Kind) {
        guard let controller = model.hostWindow?.terminalController else { return }
        switch kind {
        case .splitRight: controller.splitRight(self)
        case .splitDown: controller.splitDown(self)
        case .commands: controller.toggleCommandPalette(self)
        }
    }

    private func layoutHorizontal() {
        let s = settings
        let height = bounds.height
        let tab = min(CGFloat(s.tabHeight), max(16, height - 6)).rounded()
        let gap = CGFloat(s.spacing)
        let inset: CGFloat = placement == .titlebar ? 6 : 12
        let stripWidth = bounds.width - horizontalActivityWidth
        let available = max(0, stripWidth - inset * 2 - gap - tab)
        let count = displayedTabs.count
        var widths: [CGFloat]
        switch s.width {
        case .fit:
            widths = displayedTabs.enumerated().map { index, item in
                RoundedTabCell.fittedWidth(item, index: index, height: tab, settings: s)
            }
        case .equal:
            let share = count > 0 ? (available - gap * CGFloat(count - 1)) / CGFloat(count) : 0
            widths = Array(repeating: min(max(share, 72), 200).rounded(.down), count: count)
        }
        let content = widths.reduce(0, +) + gap * CGFloat(max(0, count - 1))
        let viewport = min(content, available)
        var start = inset
        if s.alignment == .center {
            start = max(inset, ((stripWidth - viewport - gap - tab) / 2).rounded())
        }
        let y = ((height - tab) / 2).rounded()
        // Signal strips leave room at both ends, so the selection glow is not cut off.
        let lead: CGFloat = isSignalStrip ? 6 : 0
        scroll.frame = NSRect(x: start - lead, y: 0, width: viewport + lead * 2, height: height)
        document.frame = NSRect(x: 0, y: 0, width: content + lead * 2, height: height)
        var x: CGFloat = lead
        for (index, item) in displayedTabs.enumerated() {
            guard let cell = cells[item.id] else { continue }
            cell.frame = NSRect(x: x, y: y, width: widths[index], height: tab)
            x += widths[index] + gap
        }
        header.frame = .zero
        headerCount.frame = .zero
        addButton.frame = NSRect(x: start + viewport + (count > 0 ? gap : 0), y: y, width: tab, height: tab)
        placeIndicator()
    }

    private func layoutVertical() {
        let s = settings
        let signal = isSignalRail
        let pad: CGFloat = 10
        let headerHeight: CGFloat = 26
        let row = signal ? TabBarSettings.signalRowHeight : CGFloat(s.tabHeight)
        let gap = CGFloat(s.spacing)
        // Signal sidebars end with a shorter dashed "New session" row.
        let addHeight: CGFloat = signal ? 38 : row
        let addGap: CGFloat = signal ? 4 : 0
        // Room above the first card, so the selection glow is not cut off by the scroller.
        let lead: CGFloat = signal ? 8 : 0
        // Signal sidebars carry the collapse button at the header's trailing end.
        let toggle: CGFloat = signal ? 26 : 0
        // Never a negative size: a collapsed sidebar is narrower than the header's margins.
        header.frame = NSRect(x: pad + 6, y: pad + 4, width: max(0, bounds.width - pad * 2 - 40 - toggle), height: 14)
        headerCount.frame = NSRect(x: bounds.width - pad - 6 - 30 - toggle, y: pad + 4, width: 30, height: 14)
        railToggle.frame = isRailCollapsed
            ? NSRect(x: ((bounds.width - 26) / 2).rounded(), y: pad, width: 26, height: 22)
            : NSRect(x: bounds.width - pad - 26, y: pad, width: 26, height: 22)
        let top = pad + headerHeight - lead
        scroll.frame = NSRect(x: 0, y: top, width: bounds.width, height: max(0, bounds.height - top - footerHeight))
        let count = displayedTabs.count
        let groups = sidebarGroups
        let sectionHeight: CGFloat = isRailCollapsed ? 15 : 23
        let sectionSpace = groupsAgentSessions ? CGFloat(groups.count) * sectionHeight : 0
        let listHeight = lead + CGFloat(count) * row + CGFloat(count) * gap + addGap + addHeight + pad + sectionSpace
        document.frame = NSRect(x: 0, y: 0, width: bounds.width, height: max(listHeight, scroll.frame.height))
        var y: CGFloat = lead
        let width = max(0, bounds.width - pad * 2)
        for (index, group) in groups.enumerated() {
            if let name = group.name {
                let label = sectionLabels[index]
                label.stringValue = isRailCollapsed ? group.symbol : "\(name)  ·  \(group.tabs.count)"
                label.textColor = theme.foreground.withAlphaComponent(0.55)
                label.alignment = isRailCollapsed ? .center : .left
                label.setAccessibilityLabel(name)
                label.isHidden = false
                label.frame = NSRect(x: pad + 3, y: y + 2, width: max(0, width - 6), height: 14)
                y += sectionHeight
            }
            for item in group.tabs {
                cells[item.id]?.frame = NSRect(x: pad, y: y, width: width, height: row)
                y += row + gap
            }
        }
        addButton.frame = NSRect(x: pad, y: y + addGap, width: width, height: addHeight)
        if showsApprovalShortcut {
            let count = agentSummary.visibleCounts.first?.count ?? 1
            approvalButton.title = isRailCollapsed ? "" : "Next Approval  ·  \(count)"
            approvalButton.imagePosition = isRailCollapsed ? .imageOnly : .imageLeading
            approvalButton.frame = NSRect(x: pad, y: bounds.height - 29, width: width, height: 23)
        }
        placeIndicator()
    }

    /// Moves the sliding highlight behind the selected tab. It springs to a newly selected
    /// tab; resizes and first placement are immediate.
    private func placeIndicator() {
        guard isSignalRail || isSignalStrip, let selected = displayedTabs.first(where: \.selected),
              let cell = cells[selected.id] else {
            indicator.isHidden = true
            indicatorTarget = nil
            return
        }
        // A tab that has just been added or is being removed has no frame yet. There is
        // nothing to put the highlight behind until the strip has been laid out.
        guard cell.frame.width >= 1, cell.frame.height >= 1 else {
            indicatorMotion.stop()
            indicator.isHidden = true
            indicatorTarget = nil
            return
        }
        let outset = TabSelectionIndicator.outset
        let target = cell.frame.insetBy(dx: -outset, dy: -outset)
        indicator.isHidden = false
        indicator.underline = !isVertical
        indicator.radius = isVertical ? 10 : min(8, cell.frame.height / 2)

        // A selection change that just happened in this tab group, not yet animated here.
        // The strip coming forward may never have seen the old selection, so it starts
        // the highlight from the previously selected tab.
        var origin: NSRect?
        var delta = 0
        let now = ProcessInfo.processInfo.systemUptime
        // A strip that is not on screen only keeps the highlight in place. The change
        // stays unplayed, so the strip plays it when its window comes forward.
        guard window?.isFrontTab == true else {
            indicatorMotion.stop()
            indicatorTarget = target
            indicator.frame = target
            return
        }
        if let change = Self.selectionHistory[groupKey], change.current == selected.id,
           change.at > animatedChangeAt, now - change.at < 0.8 {
            animatedChangeAt = change.at
            if let previous = change.previous, let previousCell = cells[previous],
               let from = displayedTabs.firstIndex(where: { $0.id == previous }),
               let to = displayedTabs.firstIndex(where: { $0.id == selected.id }) {
                origin = previousCell.frame.insetBy(dx: -outset, dy: -outset)
                delta = to - from
            }
        }

        guard origin != nil || indicatorTarget != target else { return }
        let moved = indicatorTarget.map { abs($0.minY - target.minY) > 0.5 || abs($0.minX - target.minX) > 0.5 } ?? false
        indicatorTarget = target
        guard origin != nil || moved, settings.animations, !Self.reduceMotion else {
            indicatorMotion.stop()
            indicator.frame = target
            return
        }
        // Slight overshoot, so the highlight settles like a spring.
        let start = origin ?? indicator.frame
        indicatorMotion.run(
            duration: 0.42, curve: .spring, delay: Self.settleDelay(for: window)
        ) { [weak self] progress in
            guard let self else { return }
            // The spring runs about a tenth past its end. Going from a large frame to a
            // small one, that tenth can be more than the small one's size, and a view
            // must never be given a negative size.
            self.indicator.frame = NSRect(
                x: start.minX + (target.minX - start.minX) * progress,
                y: start.minY + (target.minY - start.minY) * progress,
                width: max(0, start.width + (target.width - start.width) * progress),
                height: max(0, start.height + (target.height - start.height) * progress))
        }
        if delta != 0, selected.window.value === model.hostWindow { onSelectionChange?(delta) }
    }

    // MARK: System load (Signal sidebar footer)

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateLoadTimer()
    }

    private func updateLoadTimer() {
        let timing = window != nil && isLive && isSignalRail && !isRailCollapsed
            && displayedTabs.contains { $0.activity.lead?.elapsed() != nil }
        if timing, clockHold == nil { clockHold = AgentClock.shared.hold() }
        if !timing { clockHold = nil }
        guard window != nil, isLive, settings.systemLoad, footerHeight > 0, !isRailCollapsed,
              agentSummary.primary == nil else {
            loadTimer?.invalidate()
            loadTimer = nil
            return
        }
        guard loadTimer == nil else { return }
        sampleLoad()
        let timer = Timer(timeInterval: 3, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.sampleLoad()
            }
        }
        timer.tolerance = 1
        RunLoop.main.add(timer, forMode: .common)
        loadTimer = timer
    }

    private func sampleLoad() {
        var load = [Double](repeating: 0, count: 3)
        guard getloadavg(&load, 3) > 0 else { return }
        loadSamples.append(load[0])
        if loadSamples.count > 28 { loadSamples.removeFirst(loadSamples.count - 28) }
        // Only the footer changes.
        setNeedsDisplay(NSRect(x: 0, y: bounds.height - footerHeight, width: bounds.width, height: footerHeight))
    }

    private func drawFooter() {
        let height = footerHeight
        guard height > 0 else { return }
        if agentSummary.primary != nil {
            drawFleet(top: bounds.height - height)
            return
        }
        let fg = theme.foreground
        let font = SignalFont.mono(10, .medium)
        let top = bounds.height - height
        let label = NSAttributedString(string: "LOAD", attributes: [
            .font: font, .foregroundColor: fg.withAlphaComponent(0.32), .kern: 1.5,
        ])
        let labelSize = label.safeSize()
        let lineY = (top + (height - 10 - labelSize.height) / 2).rounded()
        label.safeDraw(at: NSPoint(x: 16, y: lineY))
        let reading = loadSamples.last.map { String(format: "%.2f", $0) } ?? "--"
        let value = NSAttributedString(string: reading, attributes: [
            .font: font, .foregroundColor: fg.withAlphaComponent(0.55),
        ])
        let valueSize = value.safeSize()
        value.safeDraw(at: NSPoint(x: bounds.width - 16 - valueSize.width, y: lineY))
        let left = 16 + labelSize.width + 10
        let chart = NSRect(x: left, y: lineY, width: bounds.width - 16 - valueSize.width - 10 - left,
                           height: labelSize.height)
        guard loadSamples.count > 1, chart.width > 8 else { return }
        let low = loadSamples.min() ?? 0
        let high = max(loadSamples.max() ?? 1, low + 0.05)
        let path = NSBezierPath()
        for (index, sample) in loadSamples.enumerated() {
            let x = chart.minX + chart.width * CGFloat(index) / CGFloat(loadSamples.count - 1)
            let y = chart.maxY - 1 - (chart.height - 2) * CGFloat((sample - low) / (high - low))
            if index == 0 { path.move(to: NSPoint(x: x, y: y)) } else { path.line(to: NSPoint(x: x, y: y)) }
        }
        path.lineWidth = 1.2
        path.lineJoinStyle = .round
        signalColor.setStroke()
        path.stroke()
    }

    /// The fleet: every agent session in this window's tabs as one segment of a bar, most
    /// urgent first, with a line that says how many are in each state.
    private func drawFleet(top: CGFloat) {
        let fg = theme.foreground
        let sessions = agentSummary.sessions.sorted {
            (AgentActivity.Phase.allCases.firstIndex(of: $0.phase) ?? 0)
                < (AgentActivity.Phase.allCases.firstIndex(of: $1.phase) ?? 0)
        }
        guard !sessions.isEmpty else { return }
        let inset: CGFloat = isRailCollapsed ? 9 : 16
        let width = bounds.width - inset * 2
        guard width > 8 else { return }
        fg.withAlphaComponent(0.07).setFill()
        NSRect(x: 0, y: top, width: bounds.width, height: 1).fill()
        var y = top + (isRailCollapsed ? 6 : 10)
        if !isRailCollapsed {
            let font = SignalFont.mono(9.5, .medium)
            let label = NSAttributedString(string: "AGENTS", attributes: [
                .font: font, .foregroundColor: fg.withAlphaComponent(0.32), .kern: 1.6,
            ])
            label.safeDraw(at: NSPoint(x: inset, y: y))
            let count = NSAttributedString(string: SignalText.ordinal(sessions.count - 1), attributes: [
                .font: font, .foregroundColor: fg.withAlphaComponent(0.32),
            ])
            count.safeDraw(at: NSPoint(x: bounds.width - inset - count.safeSize().width, y: y))
            y += label.safeSize().height + 5
        }
        let gap: CGFloat = 2
        let segment = max(2, (width - gap * CGFloat(sessions.count - 1)) / CGFloat(sessions.count))
        for (index, session) in sessions.enumerated() {
            let rect = NSRect(x: inset + CGFloat(index) * (segment + gap), y: y, width: segment, height: 5)
            guard rect.maxX <= bounds.width - inset + 0.5 else { break }
            (session.phase == .ready ? fg.withAlphaComponent(0.22) : session.phase.color).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 2, yRadius: 2).fill()
        }
        guard !isRailCollapsed else { return }
        let sentence = NSAttributedString(string: agentSummary.sentence, attributes: [
            .font: SignalFont.mono(10.5, .regular), .foregroundColor: fg.withAlphaComponent(0.6),
            .paragraphStyle: SignalText.truncating,
        ])
        sentence.safeDraw(
            with: NSRect(x: inset, y: y + 11, width: width, height: sentence.safeSize().height),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Frame of the tab at `index` in this bar's coordinates.
    func tabFrame(at index: Int) -> NSRect? {
        guard displayedTabs.indices.contains(index), let cell = cells[displayedTabs[index].id] else { return nil }
        return convert(cell.bounds, from: cell)
    }

    /// Size along the cross axis that an edge placement wants.
    var preferredThickness: CGFloat { settings.edgeThickness }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        // Nothing can be drawn into less than a point or two, and the insets and
        // midpoints below turn such bounds into invalid numbers: AppKit ends the app
        // when a path is handed one (seen with a strip squeezed to nothing).
        guard bounds.width >= 2, bounds.height >= 2 else { return }
        let s = settings
        if isPlaceholder { drawPlaceholderTitle(); return }
        // The titlebar already has the window background; the preview mimics that for Top.
        guard placement == .edge || (placement == .preview && s.position != .top) else {
            drawHorizontalActivity()
            return
        }
        if placement == .edge {
            // Only terminal surfaces paint the background, so beside them we paint it too
            // (same color and opacity) instead of showing the blurred desktop.
            theme.background.withAlphaComponent(theme.backgroundOpacity).setFill()
            bounds.fill()
        }
        if s.showBackground {
            theme.foreground.withAlphaComponent(0.035).setFill()
            bounds.fill()
        }
        if isSignalRail {
            // No separator: the gutter beside a Signal sidebar carries the trace instead.
            drawFooter()
            return
        }
        drawHorizontalActivity()
        theme.foreground.withAlphaComponent(0.08).setFill()
        switch s.position {
        case .top: NSRect(x: 0, y: bounds.maxY - 1, width: bounds.width, height: 1).fill()
        case .bottom: NSRect(x: 0, y: 0, width: bounds.width, height: 1).fill()
        case .left: NSRect(x: bounds.maxX - 1, y: 0, width: 1, height: bounds.height).fill()
        case .right: NSRect(x: 0, y: 0, width: 1, height: bounds.height).fill()
        }
    }

    // MARK: Placeholder (tabs shown elsewhere): behave like an empty titlebar.

    /// Draws the focused tab's title centered on the window, like a plain titlebar.
    private func drawPlaceholderTitle() {
        if settings.isSignal { drawSignalTitle(); return }
        guard let window, let title = displayedTabs.first(where: \.selected)?.title ?? model.hostWindow?.title,
              !title.isEmpty else { return }
        let text = NSAttributedString(string: title, attributes: [
            .font: SignalFont.titleBar(),
            .foregroundColor: theme.foreground.withAlphaComponent(window.isMainWindow ? 0.75 : 0.4),
        ])
        let size = text.safeSize()
        let center = convert(NSPoint(x: window.frame.width / 2, y: 0), from: nil).x
        let width = min(size.width, max(0, bounds.width - 24))
        var x = (center - width / 2).rounded()
        x = min(max(x, 12), max(12, bounds.width - 12 - width))
        let rect = NSRect(x: x, y: ((bounds.height - size.height) / 2).rounded(), width: width, height: size.height)
        text.safeDraw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    /// Signal titlebar: the selected tab as a capsule — its number on the tab's color,
    /// its title, then its directory.
    private func drawSignalTitle() {
        guard let window else { return }
        let selectedIndex = displayedTabs.firstIndex(where: \.selected)
        let tab = selectedIndex.map { displayedTabs[$0] }
        let title = tab?.displayTitle ?? SignalText.chromeSafe(model.hostWindow?.title ?? "")
        guard !title.isEmpty else { return }
        let active = window.isMainWindow
        let fg = theme.foreground
        let text = NSMutableAttributedString(string: "")
        text.append(NSAttributedString(string: title, attributes: [
            .font: SignalFont.mono(12, .semibold),
            .foregroundColor: fg.withAlphaComponent(active ? 0.92 : 0.45),
        ]))
        if settings.showSubtitle, let subtitle = tab?.subtitle {
            let regular = SignalFont.mono(12, .regular)
            text.append(NSAttributedString(string: "  /  ", attributes: [
                .font: regular, .foregroundColor: fg.withAlphaComponent(0.25),
            ]))
            text.append(NSAttributedString(string: subtitle, attributes: [
                .font: regular, .foregroundColor: fg.withAlphaComponent(active ? 0.5 : 0.3),
            ]))
        }
        let number = NSAttributedString(string: SignalText.ordinal(selectedIndex ?? 0), attributes: [
            .font: SignalFont.mono(10, .bold),
            .foregroundColor: theme.background,
        ])
        let tileWidth: CGFloat = 24
        let height: CGFloat = 24
        let textSize = text.safeSize()
        // Keep clear of the titlebar buttons at the trailing end, and of the pill that
        // says a session in another tab is waiting for an answer.
        var reserved: CGFloat = showsActions ? 110 : 12
        attentionRect = .zero
        if let waiting = displayedTabs.first(where: { !$0.selected && $0.activity.primary == .approval }) {
            let amber = AgentActivity.Phase.approval.color
            let note = NSAttributedString(string: "! \(waiting.displayTitle) needs approval", attributes: [
                .font: SignalFont.mono(11, .semibold), .foregroundColor: amber,
                .paragraphStyle: SignalText.truncating,
            ])
            let noteSize = note.safeSize()
            let pillWidth = min(ceil(noteSize.width) + 20, 260, max(0, bounds.width / 3))
            if pillWidth > 70 {
                let pill = NSRect(x: bounds.width - reserved - pillWidth, y: ((bounds.height - 24) / 2).rounded(),
                                  width: pillWidth, height: 24)
                let shape = NSBezierPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
                amber.withAlphaComponent(0.1).setFill()
                shape.fill()
                amber.withAlphaComponent(0.35).setStroke()
                shape.lineWidth = 1
                shape.stroke()
                note.safeDraw(
                    with: NSRect(x: pill.minX + 10, y: (pill.midY - noteSize.height / 2).rounded(),
                                 width: pill.width - 20, height: noteSize.height),
                    options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
                attentionRect = pill
                reserved += pillWidth + 8
            }
        }
        let available = max(0, bounds.width - 12 - reserved)
        let width = min(5 + tileWidth + 9 + ceil(textSize.width) + 12, available)
        guard width > tileWidth + 30 else { return }
        let center = convert(NSPoint(x: window.frame.width / 2, y: 0), from: nil).x
        var x = (center - width / 2).rounded()
        x = min(max(x, 12), max(12, bounds.width - reserved - width))
        let capsule = NSRect(x: x, y: ((bounds.height - height) / 2).rounded(), width: width, height: height)
        let shape = NSBezierPath(roundedRect: capsule.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        fg.withAlphaComponent(0.03).setFill()
        shape.fill()
        fg.withAlphaComponent(0.08).setStroke()
        shape.lineWidth = 1
        shape.stroke()
        let tile = NSRect(x: capsule.minX + 5, y: capsule.midY - 8, width: tileWidth, height: 16)
        signalColor.withAlphaComponent(active ? 1 : 0.5).setFill()
        NSBezierPath(roundedRect: tile, xRadius: 4, yRadius: 4).fill()
        let numberSize = number.safeSize()
        number.safeDraw(at: NSPoint(x: (tile.midX - numberSize.width / 2).rounded(),
                                y: (tile.midY - numberSize.height / 2).rounded()))
        let textRect = NSRect(x: tile.maxX + 9, y: (capsule.midY - textSize.height / 2).rounded(),
                              width: max(0, capsule.maxX - 12 - tile.maxX - 9), height: textSize.height)
        text.safeDraw(with: textRect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    private func activityCount(_ text: String, color: NSColor) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: SignalFont.mono(10, .semibold),
            .foregroundColor: color,
        ])
    }

    private func drawHorizontalActivity() {
        let width = horizontalActivityWidth
        guard width > 0 else { return }
        drawActivityOverview(
            in: NSRect(x: bounds.width - width, y: 0, width: width - 8, height: bounds.height),
            compact: true)
    }

    private func drawActivityOverview(in area: NSRect, compact: Bool = false) {
        let counts = agentSummary.visibleCounts
        var labels = counts.map { activityCount("\($0.count) \($0.phase.shortLabel)", color: $0.phase.color) }
        if compact || labels.reduce(0, { $0 + ceil($1.safeSize().width) + 14 }) > area.width {
            labels = counts.map { activityCount("\($0.phase.glyph) \($0.count)", color: $0.phase.color) }
        }
        var x = area.minX
        let y = area.midY
        for ((phase, _), label) in zip(counts, labels) {
            let size = label.safeSize()
            let rect = NSRect(x: x, y: y - 9, width: ceil(size.width) + 10, height: 18)
            guard rect.maxX <= area.maxX else { break }
            phase.color.withAlphaComponent(0.13).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 5, yRadius: 5).fill()
            label.safeDraw(at: NSPoint(x: rect.minX + 5, y: y - size.height / 2))
            x = rect.maxX + 4
        }
    }

    override func hitTest(_ point: NSPoint) -> NSView? {
        if isPlaceholder {
            // `point` is in the superview's coordinate space.
            guard !isHidden else { return nil }
            if showsActions {
                let local = convert(point, from: superview)
                if let button = actionButtons.first(where: { !$0.isHidden && $0.frame.contains(local) }) {
                    return button
                }
            }
            return frame.contains(point) ? self : nil
        }
        return super.hitTest(point)
    }

    override func mouseDown(with event: NSEvent) {
        guard isPlaceholder, let window else { return super.mouseDown(with: event) }
        if attentionRect.contains(convert(event.locationInWindow, from: nil)) {
            jumpToApproval()
            return
        }
        if event.clickCount == 2 {
            switch UserDefaults.standard.string(forKey: "AppleActionOnDoubleClick") {
            case "Minimize": window.performMiniaturize(nil)
            case "None": break
            default: window.performZoom(nil)
            }
        } else {
            window.performDrag(with: event)
        }
    }

    // MARK: Menus

    override func menu(for event: NSEvent) -> NSMenu? { isPlaceholder ? nil : barMenu() }

    func barMenu() -> NSMenu {
        let menu = NSMenu()
        let item = NSMenuItem(title: "New Tab", action: #selector(newTab), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        menu.addItem(.separator())
        addTabBarItems(to: menu)
        return menu
    }

    /// Position submenu plus the settings window, shared by tab and bar menus.
    func addTabBarItems(to menu: NSMenu) {
        let positions = NSMenu()
        for position in TabBarSettings.Position.allCases {
            let item = NSMenuItem(title: position.title, action: #selector(setPosition(_:)), keyEquivalent: "")
            item.representedObject = position.rawValue
            item.target = self
            item.state = settings.position == position ? .on : .off
            positions.addItem(item)
        }
        let positionItem = NSMenuItem(title: "Tab Bar Position", action: nil, keyEquivalent: "")
        positionItem.submenu = positions
        menu.addItem(positionItem)
        if settings.tabColors == .random {
            let shuffle = NSMenuItem(title: "Shuffle Tab Colors", action: #selector(shuffleColors), keyEquivalent: "")
            shuffle.target = self
            menu.addItem(shuffle)
        }
        if isSignalRail {
            let collapse = NSMenuItem(title: isRailCollapsed ? "Expand Sidebar" : "Collapse Sidebar",
                                      action: #selector(toggleSidebar), keyEquivalent: "")
            collapse.target = self
            menu.addItem(collapse)
        }
        if settings.isSignal && hasPendingApproval {
            let approval = NSMenuItem(title: "Next Approval", action: #selector(jumpToApproval), keyEquivalent: "")
            approval.target = self
            menu.addItem(approval)
        }
        let settingsItem = NSMenuItem(title: "Sigpane Settings…", action: #selector(openSettings), keyEquivalent: "")
        settingsItem.target = self
        menu.addItem(settingsItem)
    }

    @objc private func setPosition(_ sender: NSMenuItem) {
        guard let raw = sender.representedObject as? String,
              let position = TabBarSettings.Position(rawValue: raw) else { return }
        store.settings.position = position
    }

    @objc private func openSettings() { TabBarSettingsController.shared.show() }
    @objc private func shuffleColors() { model.shuffleColors() }
}

private final class FlippedTabDocument: NSView {
    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func menu(for event: NSEvent) -> NSMenu? {
        (enclosingScrollView?.superview as? RoundedTerminalTabBar)?.barMenu()
    }
}

/// Handle selection on mouse-down, without a SwiftUI drag recognizer competing
/// with the click. Standard button action handling remains available to AX/keyboard.
private class TabMouseButton: NSButton {
    var onMouseDown: ((NSEvent) -> Void)?
    var onDrag: ((NSEvent) -> Void)?
    var menuProvider: (() -> NSMenu?)?
    override var mouseDownCanMoveWindow: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        isBordered = false
        title = ""
        imagePosition = .noImage
        setButtonType(.momentaryChange)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override func mouseDown(with event: NSEvent) {
        if let onMouseDown { onMouseDown(event) } else { super.mouseDown(with: event) }
    }
    override func mouseDragged(with event: NSEvent) { onDrag?(event) }
    override func menu(for event: NSEvent) -> NSMenu? { menuProvider?() ?? superview?.menu(for: event) }
}

/// Buttons that draw their own hover state.
private class HoverTabButton: TabMouseButton {
    private var tracking: NSTrackingArea?
    var isHovered = false { didSet { needsDisplay = true } }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }
    override func mouseEntered(with event: NSEvent) { isHovered = true }
    override func mouseExited(with event: NSEvent) { isHovered = false }
}

/// The sliding highlight behind the selected session card in a Signal sidebar.
private final class TabSelectionIndicator: NSView {
    /// Room around the card for the glow, so this view's bounds do not clip it.
    static let outset: CGFloat = 12

    var color: NSColor = .controlAccentColor { didSet { if color != oldValue { needsDisplay = true } } }
    var glow = true { didSet { if glow != oldValue { needsDisplay = true } } }
    var radius: CGFloat = 10 { didSet { if radius != oldValue { needsDisplay = true } } }
    /// Horizontal strips mark the selection with a bar along the bottom instead of the side.
    var underline = false { didSet { if underline != oldValue { needsDisplay = true } } }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        let card = bounds.insetBy(dx: Self.outset + 0.5, dy: Self.outset + 0.5)
        guard card.width > 4, card.height > 4 else { return }
        let radius = min(self.radius, card.height / 2)
        let shape = NSBezierPath(roundedRect: card, xRadius: radius, yRadius: radius)
        shape.lineWidth = 1
        if glow {
            NSGraphicsContext.saveGraphicsState()
            let halo = NSShadow()
            halo.shadowColor = color.withAlphaComponent(0.55)
            halo.shadowBlurRadius = underline ? 6 : 10
            halo.shadowOffset = .zero
            halo.set()
            color.withAlphaComponent(0.36).setStroke()
            shape.stroke()
            NSGraphicsContext.restoreGraphicsState()
        }
        NSGradient(starting: color.withAlphaComponent(0.22), ending: color.withAlphaComponent(0.05))?
            .draw(in: shape, angle: 0)
        color.withAlphaComponent(0.36).setStroke()
        shape.stroke()
        // The bright bar: on the leading edge of a card, under a chip.
        let bar = underline
            ? NSRect(x: card.minX + 10, y: card.maxY - 1.5, width: max(0, card.width - 20), height: 2)
            : NSRect(x: card.minX - 0.5, y: card.minY + 11, width: 2, height: max(0, card.height - 22))
        color.setFill()
        NSBezierPath(roundedRect: bar, xRadius: 1, yRadius: 1).fill()
    }
}

/// Collapses a Signal sidebar to its numbered tiles, and expands it again.
private final class RailToggleButton: HoverTabButton {
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
    var collapsed = false { didSet { if collapsed != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        if isHovered {
            tint.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6).fill()
        }
        // A window outline with its sidebar: narrow when collapsed, wider when open.
        let icon = NSRect(x: (bounds.midX - 6.5).rounded() + 0.5, y: (bounds.midY - 5.5).rounded() + 0.5,
                          width: 13, height: 11)
        let path = NSBezierPath()
        path.appendRoundedRect(icon, xRadius: 2.5, yRadius: 2.5)
        let divider = icon.minX + (collapsed ? 3 : 5)
        path.move(to: NSPoint(x: divider, y: icon.minY))
        path.line(to: NSPoint(x: divider, y: icon.maxY))
        path.lineWidth = 1.3
        tint.withAlphaComponent(isHovered ? 0.95 : 0.45).setStroke()
        path.stroke()
    }
}

/// Split and command palette buttons at the trailing end of a Signal titlebar.
private final class TitlebarActionButton: HoverTabButton {
    enum Kind {
        case splitRight, splitDown, commands
        var title: String {
            switch self {
            case .splitRight: "Split Right"
            case .splitDown: "Split Down"
            case .commands: "Command Palette"
            }
        }
    }

    var kind: Kind = .splitRight { didSet { needsDisplay = true } }
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }
    override var isFlipped: Bool { true }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        if isHovered {
            tint.withAlphaComponent(0.07).setFill()
            NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 7, yRadius: 7).fill()
        }
        let icon = NSRect(x: (bounds.midX - 6.5).rounded() + 0.5, y: (bounds.midY - 5.5).rounded() + 0.5,
                          width: 13, height: 11)
        let path = NSBezierPath()
        switch kind {
        case .splitRight:
            path.appendRoundedRect(icon, xRadius: 2.5, yRadius: 2.5)
            path.move(to: NSPoint(x: icon.midX, y: icon.minY))
            path.line(to: NSPoint(x: icon.midX, y: icon.maxY))
        case .splitDown:
            path.appendRoundedRect(icon, xRadius: 2.5, yRadius: 2.5)
            path.move(to: NSPoint(x: icon.minX, y: icon.midY))
            path.line(to: NSPoint(x: icon.maxX, y: icon.midY))
        case .commands:
            path.appendOval(in: NSRect(x: icon.minX + 0.5, y: icon.minY, width: 8.5, height: 8.5))
            path.move(to: NSPoint(x: icon.minX + 8, y: icon.minY + 7.5))
            path.line(to: NSPoint(x: icon.maxX, y: icon.maxY + 0.5))
        }
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        tint.withAlphaComponent(isHovered ? 0.95 : 0.5).setStroke()
        path.stroke()
    }
}

/// The small round close control inside a capsule.
private final class TabCloseButton: HoverTabButton {
    var tint: NSColor = .labelColor { didSet { needsDisplay = true } }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        let circle = bounds.insetBy(dx: 0.5, dy: 0.5)
        if isHovered {
            tint.withAlphaComponent(0.18).setFill()
            NSBezierPath(ovalIn: circle).fill()
        }
        let r: CGFloat = 3.25
        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y - r)); path.line(to: NSPoint(x: c.x + r, y: c.y + r))
        path.move(to: NSPoint(x: c.x + r, y: c.y - r)); path.line(to: NSPoint(x: c.x - r, y: c.y + r))
        path.lineWidth = 1.4
        path.lineCapStyle = .round
        tint.withAlphaComponent(isHovered ? 1 : 0.8).setStroke()
        path.stroke()
    }
}

/// `+` as a round capsule in horizontal strips, or a dashed "New tab" row in sidebars.
private final class TabAddButton: HoverTabButton {
    var theme = RoundedTabTheme.fallback { didSet { needsDisplay = true } }
    var settings = TabBarSettings() { didSet { needsDisplay = true } }
    var isRow = false { didSet { needsDisplay = true } }
    /// Set in Signal sidebars: the row reads "New session" and lights up in this color.
    var signalColor: NSColor? { didSet { needsDisplay = true } }
    /// A collapsed sidebar shows only the plus.
    var compact = false { didSet { if compact != oldValue { needsDisplay = true } } }
    override var isFlipped: Bool { true }

    private func drawSignalRow(_ signal: NSColor) {
        let fg = theme.foreground
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        let ink = fg.withAlphaComponent(isHovered ? 0.9 : 0.5)
        shape.lineWidth = 1
        if isHovered {
            signal.withAlphaComponent(0.07).setFill()
            shape.fill()
            signal.withAlphaComponent(0.6).setStroke()
        } else {
            shape.setLineDash([3, 3], count: 2, phase: 0)
            fg.withAlphaComponent(0.14).setStroke()
        }
        shape.stroke()
        if compact {
            drawPlus(at: NSPoint(x: rect.midX, y: rect.midY), color: isHovered ? signal : ink)
            return
        }
        drawPlus(at: NSPoint(x: rect.minX + 26, y: rect.midY), color: isHovered ? signal : ink)
        let text = NSAttributedString(string: "New session", attributes: [
            .font: SignalFont.mono(12, .medium), .foregroundColor: ink,
        ])
        let size = text.safeSize()
        text.safeDraw(at: NSPoint(x: rect.minX + 50, y: (rect.midY - size.height / 2).rounded()))
        guard settings.showShortcutHints else { return }
        let hint = NSAttributedString(string: "⌘T", attributes: [
            .font: SignalFont.system(10, .medium), .foregroundColor: fg.withAlphaComponent(0.3),
        ])
        let hintSize = hint.safeSize()
        guard rect.maxX - 12 - hintSize.width > rect.minX + 50 + size.width + 8 else { return }
        hint.safeDraw(at: NSPoint(x: rect.maxX - 12 - hintSize.width, y: (rect.midY - hintSize.height / 2).rounded()))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        if isRow, let signalColor { drawSignalRow(signalColor); return }
        let fg = theme.foreground
        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(settings.cornerRadius(height: rect.height), rect.height / 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        let ink = fg.withAlphaComponent(isHovered ? 0.9 : 0.5)
        if isRow {
            if isHovered { fg.withAlphaComponent(0.06).setFill(); shape.fill() }
            shape.setLineDash([3, 3], count: 2, phase: 0)
            shape.lineWidth = 1
            fg.withAlphaComponent(0.14).setStroke()
            shape.stroke()
            drawPlus(at: NSPoint(x: rect.minX + 16, y: rect.midY), color: ink)
            let text = NSAttributedString(string: "New tab", attributes: [
                .font: SignalFont.system(12, .medium), .foregroundColor: ink,
            ])
            let size = text.safeSize()
            text.safeDraw(at: NSPoint(x: rect.minX + 30, y: rect.midY - size.height / 2))
        } else {
            fg.withAlphaComponent(isHovered ? 0.11 : 0.05).setFill()
            shape.fill()
            drawPlus(at: NSPoint(x: rect.midX, y: rect.midY), color: ink)
        }
    }

    private func drawPlus(at c: NSPoint, color: NSColor) {
        let r: CGFloat = 4.5
        let path = NSBezierPath()
        path.move(to: NSPoint(x: c.x - r, y: c.y)); path.line(to: NSPoint(x: c.x + r, y: c.y))
        path.move(to: NSPoint(x: c.x, y: c.y - r)); path.line(to: NSPoint(x: c.x, y: c.y + r))
        path.lineWidth = 1.5
        path.lineCapStyle = .round
        color.setStroke()
        path.stroke()
    }
}

@MainActor
private final class RoundedTabCell: NSView, NSDraggingSource {
    private static let dragType = NSPasteboard.PasteboardType("com.amsynist.ghosttyx.tab")
    private static let minWidth: CGFloat = 84
    private static let maxWidth: CGFloat = 200
    private static let closeSize: CGFloat = 16
    private static let dotSize: CGFloat = 7

    private weak var owner: RoundedTerminalTabBar?
    private var tab: RoundedTerminalTabModel.Tab?
    private var index = 0
    private var count = 0
    private let selectButton = TabMouseButton()
    private let closeButton = TabCloseButton()
    private var tracking: NSTrackingArea?
    private var hovered = false
    private var dragging = false

    /// 0...1 progress values the drawing interpolates on, animated via the
    /// view's animator proxy so selection and hover fade instead of snapping.
    @objc dynamic var selectAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    @objc dynamic var hoverAmount: CGFloat = 0 { didSet { needsDisplay = true } }
    /// 0 while a freshly opened tab animates in, 1 at rest.
    @objc dynamic var appearAmount: CGFloat = 1 { didSet { needsDisplay = true } }
    private let appearMotion = SignalMotion()

    override static func defaultAnimation(forKey key: NSAnimatablePropertyKey) -> Any? {
        switch key {
        case "selectAmount", "hoverAmount", "appearAmount": CABasicAnimation()
        default: super.defaultAnimation(forKey: key)
        }
    }

    private var isSignalCard: Bool { owner?.isSignalRail == true }
    private var isSignalChip: Bool { owner?.isSignalStrip == true }
    private var isCollapsed: Bool { owner?.isRailCollapsed == true }

    private static var chipFont: NSFont { SignalFont.mono(12, .semibold) }

    /// Side of the numbered tile in a Signal chip of the given height.
    private static func chipTile(height: CGFloat) -> CGFloat { max(14, height - 10) }

    /// Width a Signal chip needs: tile, title and close control.
    private static func chipWidth(_ tab: RoundedTerminalTabModel.Tab, height: CGFloat,
                                  settings: TabBarSettings) -> CGFloat {
        var width = 5 + chipTile(height: height) + 4 + 8
        width += ceil(NSAttributedString(string: tab.displayTitle, attributes: [.font: chipFont]).safeSize().width)
        width += settings.closeButton != .never ? 5 + closeSize + 8 : 10
        return min(max(width.rounded(.up), minWidth), 220)
    }

    private var theme: RoundedTabTheme { owner?.theme ?? .fallback }
    private var settings: TabBarSettings { owner?.settings ?? TabBarSettings() }

    /// The numbered tile of a Signal card or chip, in this cell. Nil for classic capsules.
    private var signalTile: NSRect? {
        if isSignalCard {
            let side: CGFloat = 27
            return NSRect(x: isCollapsed ? ((bounds.width - side) / 2).rounded() : 13,
                          y: ((bounds.height - side) / 2).rounded(), width: side, height: side)
        }
        if isSignalChip {
            let side = Self.chipTile(height: bounds.height)
            return NSRect(x: 5, y: ((bounds.height - side) / 2).rounded(), width: side + 4, height: side)
        }
        return nil
    }

    override var isFlipped: Bool { true }
    override var mouseDownCanMoveWindow: Bool { false }

    init(owner: RoundedTerminalTabBar) {
        self.owner = owner
        super.init(frame: .zero)
        selectButton.target = self
        selectButton.action = #selector(selectTab)
        selectButton.onMouseDown = { [weak self] event in
            guard let self else { return }
            if event.clickCount == 2 { self.renameTab() } else { self.selectTab() }
        }
        selectButton.onDrag = { [weak self] event in self?.beginTabDrag(event) }
        closeButton.target = self
        closeButton.action = #selector(closeTab)
        closeButton.onMouseDown = { [weak self] _ in self?.closeTab() }
        addSubview(selectButton)
        addSubview(closeButton)
        registerForDraggedTypes([Self.dragType])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    // MARK: Metrics

    private struct Metrics {
        var cap: NSRect?
        var dot: NSRect?
        var number: NSRect?
        var title: NSRect
        var close: NSRect?
    }

    /// Whether the tab shows a color: one picked by hand, or a random one.
    private static func hasColor(_ tab: RoundedTerminalTabModel.Tab, settings: TabBarSettings) -> Bool {
        tab.color.displayColor != nil || (settings.tabColors == .random && tab.autoColor != nil)
    }

    private static func capWidth(height: CGFloat, settings: TabBarSettings) -> CGFloat {
        (height * (settings.showNumbers ? 1.05 : 0.5)).rounded()
    }

    /// The tab's color: picked by hand first, else its random palette color.
    private var tabColor: NSColor? {
        guard let tab else { return nil }
        return theme.color(picked: tab.color, slot: tab.autoColor, settings: settings)
    }

    private static func fonts(height: CGFloat) -> (title: NSFont, selected: NSFont, number: NSFont) {
        let size: CGFloat = height >= 32 ? 13 : 12
        return (SignalFont.system(size, .medium),
                SignalFont.system(size, .semibold),
                SignalFont.digits(size - 1.5, .semibold))
    }

    private static func paddings(height: CGFloat, settings: TabBarSettings) -> (left: CGFloat, right: CGFloat) {
        let radius = settings.cornerRadius(height: height)
        return (max(10, (radius * 0.65).rounded()), max(6, (radius * 0.4).rounded()))
    }

    private static func numberWidth(_ index: Int, font: NSFont) -> CGFloat {
        ceil(NSAttributedString(string: "\(index + 1)", attributes: [.font: font]).safeSize().width)
    }

    /// Width a capsule needs to show its whole title (clamped), used by "Fit title".
    static func fittedWidth(_ tab: RoundedTerminalTabModel.Tab, index: Int, height: CGFloat,
                            settings: TabBarSettings) -> CGFloat {
        if settings.isSignal { return chipWidth(tab, height: height, settings: settings) }
        let fonts = fonts(height: height)
        let pad = paddings(height: height, settings: settings)
        let colored = hasColor(tab, settings: settings)
        var width = pad.right
        if colored && settings.colorStyle == .cap {
            width += capWidth(height: height, settings: settings) + 8
        } else {
            width += pad.left
            if colored && (settings.colorStyle == .dot || settings.colorStyle == .both) { width += dotSize + 6 }
            if settings.showNumbers { width += numberWidth(index, font: fonts.number) + 6 }
        }
        width += ceil(NSAttributedString(string: tab.title, attributes: [.font: fonts.selected]).safeSize().width)
        if settings.closeButton != .never { width += 6 + closeSize }
        return min(max(width.rounded(.up), minWidth), maxWidth)
    }

    private func metrics() -> Metrics {
        let s = settings
        let fonts = Self.fonts(height: bounds.height)
        let pad = Self.paddings(height: bounds.height, settings: s)
        let midY = bounds.midY
        var x = pad.left
        var m = Metrics(title: .zero)
        if isSignalCard || isSignalChip {
            // Signal tabs draw their own content; only the close control needs a frame.
            // A collapsed sidebar has no room for it (the tab menu still closes tabs).
            if s.closeButton != .never, !isCollapsed {
                let inset: CGFloat = isSignalChip ? 8 : 10
                m.close = NSRect(x: bounds.width - inset - Self.closeSize, y: (midY - Self.closeSize / 2).rounded(),
                                 width: Self.closeSize, height: Self.closeSize)
            }
            return m
        }
        let colored = tab.map { Self.hasColor($0, settings: s) } ?? false
        if colored && s.colorStyle == .cap {
            // The number lives in a colored cap on the capsule's leading end.
            let cap = NSRect(x: 0, y: 0, width: Self.capWidth(height: bounds.height, settings: s), height: bounds.height)
            m.cap = cap
            if s.showNumbers { m.number = cap }
            x = cap.maxX + 8
        } else {
            if colored && (s.colorStyle == .dot || s.colorStyle == .both) {
                m.dot = NSRect(x: x, y: midY - Self.dotSize / 2, width: Self.dotSize, height: Self.dotSize)
                x += Self.dotSize + 6
            }
            if s.showNumbers {
                let w = Self.numberWidth(index, font: fonts.number)
                m.number = NSRect(x: x, y: 0, width: w, height: bounds.height)
                x += w + 6
            }
        }
        var right = bounds.width - pad.right
        if s.closeButton != .never {
            m.close = NSRect(x: right - Self.closeSize, y: (midY - Self.closeSize / 2).rounded(),
                             width: Self.closeSize, height: Self.closeSize)
            right -= Self.closeSize + 6
        }
        m.title = NSRect(x: x, y: 0, width: max(0, right - x), height: bounds.height)
        return m
    }

    // MARK: State

    func update(_ tab: RoundedTerminalTabModel.Tab, index: Int, count: Int, entering: Bool = false) {
        let wasSelected = self.tab?.selected
        self.tab = tab; self.index = index; self.count = count
        if entering, settings.isSignal, settings.animations, !RoundedTerminalTabBar.reduceMotion {
            appearMotion.run(duration: 0.55, delay: RoundedTerminalTabBar.settleDelay(for: window)) { [weak self] progress in
                self?.appearAmount = progress
            }
        }
        let details = tab.activity.description
        let title = details.isEmpty ? tab.title : "\(tab.title), \(details)"
        selectButton.setAccessibilityLabel("Tab \(index + 1): \(title)")
        selectButton.setAccessibilityValue(tab.selected ? 1 : 0)
        closeButton.setAccessibilityLabel("Close \(tab.title)")
        toolTip = title
        let target: CGFloat = tab.selected ? 1 : 0
        if wasSelected == nil {
            selectAmount = target  // First appearance: no fade-in from nothing.
        } else if selectAmount != target {
            animate { $0.selectAmount = target }
        }
        appearanceDidChange()
    }

    func appearanceDidChange() {
        updateCloseVisibility()
        closeButton.tint = theme.foreground
        needsLayout = true
        needsDisplay = true
    }

    private func updateCloseVisibility() {
        switch settings.closeButton {
        case _ where isCollapsed: closeButton.isHidden = true
        case .never: closeButton.isHidden = true
        case .always: closeButton.isHidden = false
        case .hover: closeButton.isHidden = isSignalCard ? !hovered : !(tab?.selected == true || hovered)
        }
    }

    private func animate(duration: TimeInterval = 0.18, _ change: @escaping (RoundedTabCell) -> Void) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = duration
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            change(self.animator())
        }
    }

    override func layout() {
        super.layout()
        let m = metrics()
        // The select button covers the whole capsule; close sits on top of it.
        selectButton.frame = bounds
        closeButton.frame = m.close ?? .zero
        syncHoverWithPointer()
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        syncHoverWithPointer()
    }

    /// Tracking areas only report enter/exit when the pointer moves. Tabs are separate
    /// windows and cells move on relayout, so re-check against the real pointer position.
    private func syncHoverWithPointer() {
        guard let window else { return }
        let inside = window.isVisible && bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
        guard inside != hovered else { return }
        hovered = inside
        hoverAmount = inside ? 1 : 0
        updateCloseVisibility()
    }

    // MARK: Drawing

    private struct Palette { var fill: NSColor; var border: NSColor }

    private func palette(selected: Bool, hover: Bool) -> Palette {
        let fg = theme.foreground
        let accent = theme.accent(settings.accent)
        if let color = tabColor {
            let outline = settings.style == .outline
            switch (settings.colorStyle, selected) {
            case (.tint, true), (.both, true):
                return Palette(fill: color.withAlphaComponent(0.28), border: color.withAlphaComponent(0.7))
            case (.tint, false), (.both, false):
                return Palette(fill: color.withAlphaComponent(hover ? 0.19 : 0.11),
                               border: outline ? color.withAlphaComponent(0.38) : color.withAlphaComponent(0))
            case (.cap, true):
                return Palette(fill: color.withAlphaComponent(0.13), border: color.withAlphaComponent(0.6))
            case (.cap, false):
                return Palette(fill: hover ? color.withAlphaComponent(0.09) : fg.withAlphaComponent(0.055),
                               border: outline ? fg.withAlphaComponent(0.16) : color.withAlphaComponent(0))
            case (.dot, _):
                break
            }
        }
        switch (settings.style, selected) {
        case (.filled, true): return Palette(fill: accent.withAlphaComponent(0.22), border: accent.withAlphaComponent(0.55))
        case (.filled, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.10 : 0.06), border: .clear)
        case (.outline, true): return Palette(fill: accent.withAlphaComponent(0.12), border: accent.withAlphaComponent(0.7))
        case (.outline, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.05 : 0), border: fg.withAlphaComponent(0.16))
        case (.minimal, true): return Palette(fill: accent.withAlphaComponent(0.20), border: .clear)
        case (.minimal, false): return Palette(fill: fg.withAlphaComponent(hover ? 0.07 : 0), border: .clear)
        }
    }

    private static func mix(_ a: NSColor, _ b: NSColor, _ t: CGFloat) -> NSColor {
        let a = a.usingColorSpace(.sRGB) ?? a, b = b.usingColorSpace(.sRGB) ?? b
        func lerp(_ x: CGFloat, _ y: CGFloat) -> CGFloat { x + (y - x) * t }
        return NSColor(srgbRed: lerp(a.redComponent, b.redComponent), green: lerp(a.greenComponent, b.greenComponent),
                       blue: lerp(a.blueComponent, b.blueComponent), alpha: lerp(a.alphaComponent, b.alphaComponent))
    }

    /// Characters still "decoding" while a new tab's title settles.
    private static func scrambled(_ string: String, progress: CGFloat) -> String {
        let glyphs = Array("/\\_=+<>#%01X")
        let characters = Array(string)
        let shown = Int(CGFloat(characters.count) * min(max(progress * 1.4, 0), 1))
        var result = ""
        for (index, character) in characters.enumerated() {
            if index < shown || character == " " {
                result.append(character)
            } else {
                result.append(glyphs.randomElement() ?? character)
            }
        }
        return result
    }

    /// A Signal session card: index tile, title and directory. The selection highlight is
    /// the bar's sliding indicator, drawn behind this cell.
    private func drawSignalCard(_ tab: RoundedTerminalTabModel.Tab) {
        let theme = theme
        let s = settings
        let sel = selectAmount
        let fg = theme.foreground
        let tint = tabColor ?? theme.accent(s.accent)
        let appear = min(max(appearAmount, 0), 1)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        defer { context?.restoreGState() }
        context?.setAlpha(appear)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath(roundedRect: rect, xRadius: 10, yRadius: 10)
        if tab.activity.primary == .approval {
            let color = AgentActivity.Phase.approval.color
            color.withAlphaComponent(0.07).setFill()
            shape.fill()
            color.withAlphaComponent(0.75).setFill()
            let edge = NSRect(x: 1, y: bounds.midY - 10, width: 2, height: 20)
            NSBezierPath(roundedRect: edge, xRadius: 1, yRadius: 1).fill()
        }
        let wash = hoverAmount * (1 - sel)
        if wash > 0.01 {
            fg.withAlphaComponent(0.04 * wash).setFill()
            shape.fill()
        }
        if appear < 1 {
            // A band of the tab's color sweeps across a card as it arrives.
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            let band = NSRect(x: rect.minX - rect.width + rect.width * 2 * appear, y: rect.minY,
                              width: rect.width, height: rect.height)
            NSGradient(colors: [
                tint.withAlphaComponent(0), tint.withAlphaComponent(0.5 * (1 - appear)), tint.withAlphaComponent(0),
            ])?.draw(in: band, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Index tile: tinted at rest, solid and glowing when selected.
        let collapsed = isCollapsed
        guard let tile = signalTile else { return }
        let tilePath = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        NSGraphicsContext.saveGraphicsState()
        if sel > 0.01 {
            let glow = NSShadow()
            glow.shadowColor = tint.withAlphaComponent(0.6 * sel)
            glow.shadowBlurRadius = 9
            glow.shadowOffset = .zero
            glow.set()
        }
        Self.mix(tint.withAlphaComponent(0.11), tint, sel).setFill()
        tilePath.fill()
        NSGraphicsContext.restoreGraphicsState()
        Self.mix(tint.withAlphaComponent(0.28), tint, sel).setStroke()
        tilePath.lineWidth = 1
        tilePath.stroke()
        if s.showNumbers {
            drawText(SignalText.ordinal(index), in: tile, font: SignalFont.mono(11, .bold),
                     color: Self.mix(tint, theme.background, sel), centered: true)
        }
        let session = tab.activity.lead
        if let percent = session?.context { drawContextFrame(percent, around: tile, tint: tint) }

        // A collapsed sidebar shows the tile alone; the tooltip carries the title.
        if collapsed {
            drawStateDot(session?.phase, at: tile)
            return
        }

        // Trailing edge of the title row: the close control on hover, else how long the
        // turn has been going, else the shortcut hint.
        let left = tile.maxX + 11
        var right = bounds.width - 8
        let subtitle = session?.activity ?? (s.showSubtitle ? tab.subtitle : nil)
        let titleRow = subtitle == nil
            ? NSRect(x: left, y: 0, width: 0, height: bounds.height)
            : NSRect(x: left, y: bounds.midY - 17, width: 0, height: 17)
        if !closeButton.isHidden {
            right = closeButton.frame.minX - 6
        } else if let trailing = session?.elapsed() ?? (s.showShortcutHints && index < 9 ? "⌘\(index + 1)" : nil) {
            let hint = NSAttributedString(string: trailing, attributes: [
                .font: session?.elapsed() != nil ? SignalFont.mono(10, .regular) : SignalFont.system(10, .medium),
                .foregroundColor: fg.withAlphaComponent(0.34),
            ])
            let size = hint.safeSize()
            hint.safeDraw(at: NSPoint(x: right - size.width - 2, y: (titleRow.midY - size.height / 2).rounded()))
            right -= size.width + 8
        }

        let width = max(0, right - left)
        let titleFont = SignalFont.mono(12.5, .semibold)
        let titleColor = Self.mix(fg.withAlphaComponent(0.58 + 0.2 * hoverAmount), fg, sel)
        let title = appear < 1 ? Self.scrambled(tab.displayTitle, progress: appear) : tab.displayTitle
        drawText(title, in: NSRect(x: left, y: titleRow.minY, width: width, height: titleRow.height),
                 font: titleFont, color: titleColor)
        guard let subtitle else { return }

        let line = NSRect(x: left, y: bounds.midY + 1, width: max(0, bounds.width - 10 - left), height: 17)
        guard let session else {
            // No agent: a dot (filled in the tab's color when selected) and the directory.
            let dot = NSBezierPath(ovalIn: NSRect(x: left + 0.5, y: bounds.midY + 6.5, width: 6, height: 6))
            if sel > 0.5 {
                tint.setFill()
                dot.fill()
            } else {
                dot.lineWidth = 1
                fg.withAlphaComponent(0.32).setStroke()
                dot.stroke()
            }
            drawText(subtitle, in: NSRect(x: line.minX + 12, y: line.minY, width: max(0, line.width - 12), height: 17),
                     font: SignalFont.mono(10.5, .regular), color: fg.withAlphaComponent(0.38))
            return
        }
        // An agent: its state as a glyph, what it is doing, and a dot for each subagent.
        let phase = session.phase
        drawText(phase.glyph, in: NSRect(x: line.minX - 1, y: line.minY, width: 10, height: 17),
                 font: SignalFont.mono(10.5, .bold), color: phase == .ready ? fg.withAlphaComponent(0.45) : phase.color,
                 centered: true)
        let pips = drawPips(session.subagents, endingAt: line.maxX, midY: line.midY)
        drawText(subtitle,
                 in: NSRect(x: line.minX + 13, y: line.minY, width: max(0, line.width - 13 - pips), height: 17),
                 font: SignalFont.mono(10.5, .regular),
                 color: phase == .approval ? phase.color : fg.withAlphaComponent(0.5))
    }

    /// The outline around a tile that fills, clockwise from its top left corner, as the
    /// session's context window fills. Amber from 75%, red from 90%.
    private func drawContextFrame(_ percent: Int, around tile: NSRect, tint: NSColor) {
        guard let context = NSGraphicsContext.current?.cgContext else { return }
        let rect = tile.insetBy(dx: -3.5, dy: -3.5)
        let radius: CGFloat = 10.5
        guard rect.width > radius * 2, rect.height > radius * 2 else { return }
        let path = CGMutablePath()
        path.move(to: CGPoint(x: rect.minX + radius, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - radius, y: rect.minY))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.maxX, y: rect.minY + radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - radius))
        path.addArc(tangent1End: CGPoint(x: rect.maxX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.maxX - radius, y: rect.maxY), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX + radius, y: rect.maxY))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.maxY),
                    tangent2End: CGPoint(x: rect.minX, y: rect.maxY - radius), radius: radius)
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + radius))
        path.addArc(tangent1End: CGPoint(x: rect.minX, y: rect.minY),
                    tangent2End: CGPoint(x: rect.minX + radius, y: rect.minY), radius: radius)
        path.closeSubpath()
        let length = 2 * (rect.width + rect.height) - 8 * radius + 2 * .pi * radius
        context.saveGState()
        context.addPath(path)
        context.setLineWidth(1.5)
        context.setStrokeColor(theme.foreground.withAlphaComponent(0.1).cgColor)
        context.strokePath()
        let share = CGFloat(min(max(percent, 0), 100)) / 100
        if share > 0 {
            context.addPath(path)
            context.setLineWidth(1.8)
            context.setLineCap(.round)
            context.setLineDash(phase: 0, lengths: [max(0.01, length * share), length])
            context.setStrokeColor((AgentActivity.Session.contextColor(percent) ?? tint).cgColor)
            context.strokePath()
        }
        context.restoreGState()
    }

    /// One dot per subagent, filled while it runs and hollow once it has finished, ending
    /// at `endingAt`. More than five are counted. Returns the width taken, with its margin.
    private func drawPips(_ subagents: [AgentActivity.Subagent], endingAt right: CGFloat, midY: CGFloat) -> CGFloat {
        guard !subagents.isEmpty else { return 0 }
        let fg = theme.foreground
        var x = right
        let extra = subagents.count - 5
        if extra > 0 {
            let more = NSAttributedString(string: "+\(extra)", attributes: [
                .font: SignalFont.mono(9.5, .regular), .foregroundColor: fg.withAlphaComponent(0.34),
            ])
            let size = more.safeSize()
            x -= size.width
            more.safeDraw(at: NSPoint(x: x, y: (midY - size.height / 2).rounded()))
            x -= 3
        }
        // Running ones first, so a glance says whether anything is still going.
        let shown = subagents.sorted { !$0.done && $1.done }.prefix(5)
        for agent in shown.reversed() {
            x -= 5
            let dot = NSBezierPath(ovalIn: NSRect(x: x + 0.5, y: midY - 2, width: 4, height: 4))
            if agent.done {
                dot.lineWidth = 1
                fg.withAlphaComponent(0.32).setStroke()
                dot.stroke()
            } else {
                AgentActivity.Phase.running.color.setFill()
                dot.fill()
                AgentActivity.Phase.running.color.setStroke()
                dot.lineWidth = 1
                dot.stroke()
            }
            x -= 3
        }
        return right - x + 5
    }

    /// The state as a small dot on the tile's corner, where there is no room for words:
    /// collapsed sidebars and the chips of top and bottom strips.
    private func drawStateDot(_ phase: AgentActivity.Phase?, at tile: NSRect) {
        guard let phase, phase != .ready else { return }
        let rect = NSRect(x: tile.maxX - 5, y: tile.maxY - 5, width: 8, height: 8)
        let shape = NSBezierPath(ovalIn: rect)
        phase.color.setFill()
        shape.fill()
        theme.background.setStroke()
        shape.lineWidth = 1.5
        shape.stroke()
    }

    /// A Signal chip for top and bottom strips: numbered tile and title. The selection
    /// highlight is the bar's sliding indicator, drawn behind this cell.
    private func drawSignalChip(_ tab: RoundedTerminalTabModel.Tab) {
        let theme = theme
        let s = settings
        let sel = selectAmount
        let fg = theme.foreground
        let tint = tabColor ?? theme.accent(s.accent)
        let appear = min(max(appearAmount, 0), 1)
        let context = NSGraphicsContext.current?.cgContext
        context?.saveGState()
        defer { context?.restoreGState() }
        context?.setAlpha(appear)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(8, rect.height / 2)
        let wash = hoverAmount * (1 - sel)
        if wash > 0.01 {
            fg.withAlphaComponent(0.05 * wash).setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
        }

        guard let tile = signalTile else { return }
        let tilePath = NSBezierPath(roundedRect: tile.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        Self.mix(tint.withAlphaComponent(0.11), tint, sel).setFill()
        tilePath.fill()
        Self.mix(tint.withAlphaComponent(0.28), tint, sel).setStroke()
        tilePath.lineWidth = 1
        tilePath.stroke()
        if s.showNumbers {
            drawText(SignalText.ordinal(index), in: tile, font: SignalFont.mono(10, .bold),
                     color: Self.mix(tint, theme.background, sel), centered: true)
        }
        drawStateDot(tab.activity.primary, at: tile)

        let left = tile.maxX + 8
        let right = closeButton.isHidden ? bounds.width - 10 : closeButton.frame.minX - 5
        let title = appear < 1 ? Self.scrambled(tab.displayTitle, progress: appear) : tab.displayTitle
        drawText(title, in: NSRect(x: left, y: 0, width: max(0, right - left), height: bounds.height),
                 font: Self.chipFont, color: Self.mix(fg.withAlphaComponent(0.58 + 0.2 * hoverAmount), fg, sel))
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        guard let tab else { return }
        if isSignalCard { drawSignalCard(tab); return }
        if isSignalChip { drawSignalChip(tab); return }
        let theme = theme
        let s = settings
        let sel = selectAmount
        let rest = Self.mix(palette(selected: false, hover: false).fill, palette(selected: false, hover: true).fill, hoverAmount)
        let restBorder = palette(selected: false, hover: false).border
        let on = palette(selected: true, hover: false)
        let fill = Self.mix(rest, on.fill, sel)
        let border = Self.mix(restBorder.usingColorSpace(.sRGB) ?? .clear, on.border.usingColorSpace(.sRGB) ?? .clear, sel)

        let rect = bounds.insetBy(dx: 0.5, dy: 0.5)
        let radius = min(s.cornerRadius(height: rect.height), rect.height / 2)
        let shape = NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius)
        fill.setFill()
        shape.fill()

        let m = metrics()
        let fonts = Self.fonts(height: bounds.height)
        let color = tabColor
        if let cap = m.cap, let color {
            // Muted cap for other tabs, solid for the selected one; clipped to the capsule.
            let rest = color.withAlphaComponent(0.24 + 0.12 * hoverAmount)
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            Self.mix(rest, color.withAlphaComponent(1), sel).setFill()
            cap.fill()
            NSGraphicsContext.restoreGraphicsState()
        }
        if border.alphaComponent > 0.001 {
            shape.lineWidth = 1
            border.setStroke()
            shape.stroke()
        }
        if let dot = m.dot, let color {
            color.setFill()
            NSBezierPath(ovalIn: dot).fill()
        }
        if let numberRect = m.number {
            let numberColor: NSColor
            let style = s.colorStyle
            if let color, m.cap != nil {
                numberColor = Self.mix(color, theme.background, sel)
            } else if let color, style == .tint || style == .both {
                numberColor = Self.mix(color.withAlphaComponent(0.75), color, sel)
            } else {
                numberColor = Self.mix(theme.foreground.withAlphaComponent(0.35), theme.accent(s.accent), sel)
            }
            drawText("\(index + 1)", in: numberRect, font: fonts.number, color: numberColor,
                     centered: m.cap != nil)
        }
        let textAlpha = 0.6 + 0.25 * hoverAmount
        let titleColor = Self.mix(theme.foreground.withAlphaComponent(textAlpha), theme.foreground, sel)
        drawText(tab.title, in: m.title, font: sel > 0.5 ? fonts.selected : fonts.title, color: titleColor)
    }

    private func drawText(_ string: String, in rect: NSRect, font: NSFont, color: NSColor, centered: Bool = false) {
        guard !string.isEmpty, rect.width >= 1, rect.height >= 1 else { return }
        let text = NSAttributedString(string: string, attributes: [
            .font: font, .foregroundColor: color,
            .paragraphStyle: centered ? SignalText.truncatingCentered : SignalText.truncating,
        ])
        let height = ceil(font.ascender - font.descender + font.leading)
        let line = NSRect(x: rect.minX, y: (rect.midY - height / 2).rounded(), width: rect.width, height: height)
        text.safeDraw(with: line, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    }

    // MARK: Mouse

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect], owner: self, userInfo: nil)
        addTrackingArea(area); tracking = area
    }
    override func mouseEntered(with event: NSEvent) {
        hovered = true
        updateCloseVisibility()
        animate { $0.hoverAmount = 1 }
    }
    override func mouseExited(with event: NSEvent) {
        hovered = false
        updateCloseVisibility()
        animate { $0.hoverAmount = 0 }
    }
    override func mouseDown(with event: NSEvent) { selectTab() }

    @objc private func selectTab() { if let tab { owner?.model.select(tab) } }
    @objc private func closeTab() { if let tab { owner?.model.close(tab) } }
    @objc private func renameTab() { if let tab { owner?.model.rename(tab) } }
    @objc private func moveTabBack() { if let tab { owner?.model.move(tab, by: -1) } }
    @objc private func moveTabForward() { if let tab { owner?.model.move(tab, by: 1) } }
    @objc private func detachTab() { if let tab { owner?.model.detach(tab) } }
    @objc private func setColor(_ sender: NSMenuItem) {
        guard let tab, let color = TerminalTabColor(rawValue: sender.tag) else { return }
        owner?.model.setColor(color, for: tab)
    }

    override func menu(for event: NSEvent) -> NSMenu? {
        let menu = NSMenu()
        let vertical = owner?.isVertical == true
        for (title, action, enabled) in [
            ("Rename Tab…", #selector(renameTab), true),
            (vertical ? "Move Tab Up" : "Move Tab Left", #selector(moveTabBack), index > 0),
            (vertical ? "Move Tab Down" : "Move Tab Right", #selector(moveTabForward), index < count - 1),
            ("Move Tab to New Window", #selector(detachTab), count > 1),
        ] {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
            item.target = self; item.isEnabled = enabled; menu.addItem(item)
        }
        let colors = NSMenu()
        for color in TerminalTabColor.allCases {
            let item = NSMenuItem(title: color.localizedName, action: #selector(setColor(_:)), keyEquivalent: "")
            item.tag = color.rawValue; item.target = self
            item.state = tab?.color == color ? .on : .off
            colors.addItem(item)
        }
        let colorMenu = NSMenuItem(title: "Tab Color", action: nil, keyEquivalent: "")
        colorMenu.submenu = colors; menu.addItem(colorMenu)
        menu.addItem(.separator())
        owner?.addTabBarItems(to: menu)
        menu.addItem(.separator())
        let close = NSMenuItem(title: "Close Tab", action: #selector(closeTab), keyEquivalent: "")
        close.target = self; menu.addItem(close)
        return menu
    }

    // MARK: Drag reorder

    private func beginTabDrag(_ event: NSEvent) {
        guard !dragging, let tab else { return }
        let item = NSPasteboardItem()
        item.setString(String(describing: tab.id), forType: Self.dragType)
        let draggingItem = NSDraggingItem(pasteboardWriter: item)
        let image = NSImage(size: bounds.size)
        if let rep = bitmapImageRepForCachingDisplay(in: bounds) {
            cacheDisplay(in: bounds, to: rep)
            image.addRepresentation(rep)
        }
        draggingItem.setDraggingFrame(bounds, contents: image)
        dragging = true
        beginDraggingSession(with: [draggingItem], event: event, source: self)
    }
    func draggingSession(_ session: NSDraggingSession, sourceOperationMaskFor context: NSDraggingContext) -> NSDragOperation { .move }
    func draggingSession(_ session: NSDraggingSession, endedAt screenPoint: NSPoint, operation: NSDragOperation) { dragging = false }
    override func draggingEntered(_ sender: NSDraggingInfo) -> NSDragOperation {
        guard let id = sender.draggingPasteboard.string(forType: Self.dragType),
              owner?.model.tabs.contains(where: { String(describing: $0.id) == id }) == true else { return [] }
        return .move
    }
    override func performDragOperation(_ sender: NSDraggingInfo) -> Bool {
        guard let id = sender.draggingPasteboard.string(forType: Self.dragType), let tab else { return false }
        return owner?.model.reorder([id], before: tab) ?? false
    }
}
