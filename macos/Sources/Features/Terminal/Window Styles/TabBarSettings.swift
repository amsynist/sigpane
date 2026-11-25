import AppKit
import Combine
import GhosttyKit

/// Appearance of the Ghostty X tab strip. Set from the Tab Bar settings window and stored
/// in the app's own defaults (not the Ghostty config), so changes apply live to every window.
struct TabBarSettings: Codable, Equatable {
    enum Position: String, Codable, CaseIterable, Identifiable {
        case top, bottom, left, right
        var id: Self { self }
        var isVertical: Bool { self == .left || self == .right }
        var title: String {
            switch self {
            case .top: "Top"
            case .bottom: "Bottom"
            case .left: "Left"
            case .right: "Right"
            }
        }
    }

    enum Style: String, Codable, CaseIterable, Identifiable {
        case filled, outline, minimal
        var id: Self { self }
        var title: String {
            switch self {
            case .filled: "Filled"
            case .outline: "Outline"
            case .minimal: "Minimal"
            }
        }
    }

    enum Width: String, Codable, CaseIterable, Identifiable {
        case fit, equal
        var id: Self { self }
        var title: String { self == .fit ? "Fit title" : "Equal" }
    }

    enum Alignment: String, Codable, CaseIterable, Identifiable {
        case leading, center
        var id: Self { self }
        var title: String { self == .leading ? "Leading" : "Centered" }
    }

    enum CloseButton: String, Codable, CaseIterable, Identifiable {
        case hover, always, never
        var id: Self { self }
        var title: String {
            switch self {
            case .hover: "On hover"
            case .always: "Always"
            case .never: "Never"
            }
        }
    }

    /// Accent colors come from the active theme's palette so they always match it.
    enum Accent: String, Codable, CaseIterable, Identifiable {
        case blue, magenta, cyan, green, yellow, mono
        var id: Self { self }
        var title: String { rawValue.capitalized }
        /// Index into the 16-color palette, or nil for the foreground color.
        var paletteIndex: Int? {
            switch self {
            case .blue: 4
            case .magenta: 5
            case .cyan: 6
            case .green: 2
            case .yellow: 3
            case .mono: nil
            }
        }
    }

    enum TabColors: String, Codable, CaseIterable, Identifiable {
        case off, random
        var id: Self { self }
        var title: String { self == .off ? "Off" : "Random" }
    }

    /// How a tab's color (random, or picked by hand) is drawn on its capsule.
    enum ColorStyle: String, Codable, CaseIterable, Identifiable {
        case cap, tint, dot, both
        var id: Self { self }
        var title: String {
            switch self {
            case .cap: "Cap"
            case .tint: "Tint"
            case .dot: "Dot"
            case .both: "Both"
            }
        }
    }

    /// The overall look. `signal` is the Signal interface: session cards with a sliding
    /// selection in sidebars, chrome tinted by the selected tab, framed panes with headers,
    /// a trace from the selected tab to the focused pane, and a status line.
    enum Design: String, Codable, CaseIterable, Identifiable {
        case classic, signal
        var id: Self { self }
        var title: String { self == .classic ? "Classic" : "Signal" }
    }

    /// The look of the prompt being typed at.
    enum PromptStyle: String, Codable, CaseIterable, Identifiable {
        case rail, capsule, dock, hud, card
        var id: Self { self }
        var title: String {
            switch self {
            case .rail: "Breadcrumb Rail"
            case .capsule: "Command Capsule"
            case .dock: "Tabbed Dock"
            case .hud: "HUD Brackets"
            case .card: "Card"
            }
        }
    }

    /// Theme palette entries random tab colors are drawn from: blue, magenta, cyan,
    /// green, yellow, red.
    static let randomPaletteIndices = [4, 5, 6, 2, 3, 1]

    static let heightRange: ClosedRange<Double> = 22...36
    static let spacingRange: ClosedRange<Double> = 2...14
    static let sidebarWidthRange: ClosedRange<Double> = 160...320
    static let gutterRange: ClosedRange<Double> = 4...16
    static let paneRadiusRange: ClosedRange<Double> = 0...16
    static let foldRange: ClosedRange<Double> = 5...100
    /// Where the settings are saved in the app's defaults.
    static let storageKey = "GhosttyXTabBarSettings"

    /// Height of a session card in a Signal sidebar.
    static let signalRowHeight: CGFloat = 54
    /// Width of a collapsed Signal sidebar: just the numbered tiles.
    static let collapsedSidebarWidth: CGFloat = 76
    /// Height of the strip above each pane in Signal windows.
    static let paneHeaderHeight: CGFloat = 24
    /// Height of the status line under the terminal in Signal windows.
    static let statusBarHeight: CGFloat = 24

    var position: Position = .top
    var style: Style = .filled
    var width: Width = .fit
    var alignment: Alignment = .leading
    var closeButton: CloseButton = .hover
    var accent: Accent = .blue
    var tabHeight: Double = 28
    var spacing: Double = 6
    /// 0 is square corners, 1 is a full capsule.
    var roundness: Double = 1
    var sidebarWidth: Double = 200
    var showNumbers = true
    var showBackground = true
    var showWithSingleTab = true
    var tabColors: TabColors = .random
    var colorStyle: ColorStyle = .cap

    // Signal interface
    var design: Design = .signal
    /// The chrome (selection, focus outline, trace, status) takes the selected tab's color.
    var tintFollowsTab = true
    /// Sliding selection, new-tab entrance, focus sweep and the moving trace pulse.
    var animations = true
    /// Second line of a session card: the tab's working directory.
    var showSubtitle = true
    var showShortcutHints = true
    /// Load average sparkline at the foot of a Signal sidebar.
    var systemLoad = true
    /// Split and command palette buttons in the titlebar.
    var titlebarActions = true
    var paneHeaders = true
    var focusCorners = true
    var focusGlow = true
    var signalTrace = true
    var statusBar = true
    var paneGutter: Double = 8
    var paneRadius: Double = 10
    /// A Signal sidebar shrunk to its numbered tiles.
    var sidebarCollapsed = false
    /// Apply the Signal Void colors over the configured theme.
    var signalColors = true
    /// Draw Ghostty X's own prompt in zsh, in place of a prompt theme such as Starship.
    var signalPrompt = true
    /// Fold long output for you. Off by default: what a command printed stays on the
    /// screen until you fold it yourself, the way a terminal is expected to behave.
    /// (Saved under new names, so the earlier always-on default does not carry over.)
    var autoFold = false
    /// Output longer than this many rows counts as long.
    var autoFoldLines: Double = 20
    /// Fold long output as soon as its command finishes, instead of when the next
    /// command runs.
    var foldNewest = false
    /// Draw a box around each command and its output, with copy and fold buttons.
    var commandBlocks = true
    /// Which look the Signal prompt has.
    var promptStyle = PromptStyle.rail
    /// Control-S shows or hides the sidebar; Control-F folds or opens every block.
    var sidebarKey = true
    var foldAllKey = true
    /// Shift with the up and down arrows picks a command block; Control-C copies it.
    var blockKeys = true
    /// Show the keys worth remembering in the free middle of the status line.
    var statusHints = true

    init() {}

    /// A Signal sidebar that is currently collapsed to its tiles.
    var isSidebarCollapsed: Bool { usesSessionCards && sidebarCollapsed }

    var isSignal: Bool { design == .signal }

    /// Signal sidebars show fixed-height session cards instead of capsules.
    var usesSessionCards: Bool { isSignal && position.isVertical }

    /// Gap between split panes (and around them).
    var gutter: CGFloat { isSignal ? CGFloat(paneGutter) : 6 }

    /// Corner radius of a framed pane.
    var paneCornerRadius: CGFloat { isSignal ? CGFloat(paneRadius) : 8 }

    var showsStatusBar: Bool { isSignal && statusBar }

    /// Rows of output a command may print before it is folded; zero when folding is off.
    var foldThreshold: UInt32 { isSignal && commandBlocks && autoFold ? UInt32(max(1, autoFoldLines.rounded())) : 0 }
    /// Whether long output folds as soon as its command finishes.
    var foldsNewest: Bool { isSignal && commandBlocks && autoFold && foldNewest }
    var showsPaneHeaders: Bool { isSignal && paneHeaders }
    var showsCommandBlocks: Bool { isSignal && commandBlocks }

    /// Corner radius for a capsule of the given height.
    func cornerRadius(height: CGFloat) -> CGFloat {
        height / 2 * CGFloat(min(max(roundness, 0), 1))
    }

    /// The bar's size across its main axis when it sits beside the terminal.
    var edgeThickness: CGFloat {
        if isSidebarCollapsed { return Self.collapsedSidebarWidth }
        return position.isVertical ? CGFloat(sidebarWidth) : CGFloat(tabHeight) + 16
    }

    // Tolerate missing or unknown keys so older or newer saved values never reset everything.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ fallback: T) -> T {
            (try? c.decodeIfPresent(T.self, forKey: key)) ?? fallback
        }
        let d = TabBarSettings()
        position = value(.position, d.position)
        style = value(.style, d.style)
        width = value(.width, d.width)
        alignment = value(.alignment, d.alignment)
        closeButton = value(.closeButton, d.closeButton)
        accent = value(.accent, d.accent)
        tabHeight = min(max(value(.tabHeight, d.tabHeight), Self.heightRange.lowerBound), Self.heightRange.upperBound)
        spacing = min(max(value(.spacing, d.spacing), Self.spacingRange.lowerBound), Self.spacingRange.upperBound)
        roundness = min(max(value(.roundness, d.roundness), 0), 1)
        sidebarWidth = min(max(value(.sidebarWidth, d.sidebarWidth), Self.sidebarWidthRange.lowerBound),
                           Self.sidebarWidthRange.upperBound)
        showNumbers = value(.showNumbers, d.showNumbers)
        showBackground = value(.showBackground, d.showBackground)
        showWithSingleTab = value(.showWithSingleTab, d.showWithSingleTab)
        tabColors = value(.tabColors, d.tabColors)
        colorStyle = value(.colorStyle, d.colorStyle)
        design = value(.design, d.design)
        tintFollowsTab = value(.tintFollowsTab, d.tintFollowsTab)
        animations = value(.animations, d.animations)
        showSubtitle = value(.showSubtitle, d.showSubtitle)
        showShortcutHints = value(.showShortcutHints, d.showShortcutHints)
        systemLoad = value(.systemLoad, d.systemLoad)
        titlebarActions = value(.titlebarActions, d.titlebarActions)
        paneHeaders = value(.paneHeaders, d.paneHeaders)
        focusCorners = value(.focusCorners, d.focusCorners)
        focusGlow = value(.focusGlow, d.focusGlow)
        signalTrace = value(.signalTrace, d.signalTrace)
        statusBar = value(.statusBar, d.statusBar)
        sidebarCollapsed = value(.sidebarCollapsed, d.sidebarCollapsed)
        signalColors = value(.signalColors, d.signalColors)
        signalPrompt = value(.signalPrompt, d.signalPrompt)
        autoFold = value(.autoFold, d.autoFold)
        commandBlocks = value(.commandBlocks, d.commandBlocks)
        foldNewest = value(.foldNewest, d.foldNewest)
        promptStyle = value(.promptStyle, d.promptStyle)
        sidebarKey = value(.sidebarKey, d.sidebarKey)
        foldAllKey = value(.foldAllKey, d.foldAllKey)
        blockKeys = value(.blockKeys, d.blockKeys)
        statusHints = value(.statusHints, d.statusHints)
        autoFoldLines = min(max(value(.autoFoldLines, d.autoFoldLines), Self.foldRange.lowerBound),
                            Self.foldRange.upperBound)
        paneGutter = min(max(value(.paneGutter, d.paneGutter), Self.gutterRange.lowerBound), Self.gutterRange.upperBound)
        paneRadius = min(max(value(.paneRadius, d.paneRadius), Self.paneRadiusRange.lowerBound),
                         Self.paneRadiusRange.upperBound)
    }
}

/// Ghostty X: terminal config the Signal look applies over the user's own config. The app
/// writes it to a cache file and loads it last, so the user's config file is never edited
/// and turning the options off brings their own colors and prompt straight back.
enum SignalColors {
    /// Signal Void: the dark palette the chrome was designed around. Tab colors come from
    /// palette entries 4, 5, 6, 2, 3 and 1.
    static let colors = """
    background = #0a0c13
    foreground = #dde3f0
    cursor-color = #5ab8ff
    cursor-text = #06070c
    selection-background = #1b2740
    selection-foreground = #dde3f0
    palette = 0=#161a25
    palette = 1=#ff6f91
    palette = 2=#5fe3a8
    palette = 3=#ffc35a
    palette = 4=#5ab8ff
    palette = 5=#9d8cff
    palette = 6=#4fe3c1
    palette = 7=#b9c0d4
    palette = 8=#4b5268
    palette = 9=#ff8fa9
    palette = 10=#86efbf
    palette = 11=#ffd27f
    palette = 12=#84ccff
    palette = 13=#b8abff
    palette = 14=#7aeed5
    palette = 15=#f1f4fb
    unfocused-split-opacity = 0.62

    """

    /// Tells the zsh integration to draw the Signal prompt and where to read its look
    /// from, and gives the prompt its cursor: a thin blinking bar.
    static var prompt: String {
        var text = "env = GHOSTTY_X_PROMPT=1\ncursor-style = bar\ncursor-style-blink = true\n"
        if let file = cacheFile(named: "prompt-style") { text += "env = GHOSTTY_X_STYLE_FILE=\(file.path)\n" }
        return text
    }

    /// Hides the routine core cursor while Signal draws its own animated glowing cursor.
    static let cursor = "cursor-opacity = 0\n"

    /// The config text for these settings; empty when nothing is overridden.
    static func overlay(for settings: TabBarSettings) -> String {
        guard settings.isSignal else { return "" }
        return (settings.signalColors ? colors : "") + (settings.signalPrompt ? prompt : "") + cursor
    }

    /// A file in the app's cache folder. A demo run keeps its own set, so it never
    /// changes what the real app and its shells are reading.
    static func cacheFile(named name: String) -> URL? {
        guard let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else { return nil }
        let folder = caches.appendingPathComponent("com.amsynist.ghosttyx", isDirectory: true)
        return folder.appendingPathComponent(SignalDemo.isRequested ? "demo-" + name : name)
    }

    /// Writes the prompt's look where the shells read it before every prompt, so open
    /// shells follow a change at their next prompt.
    static func writePromptStyle(_ style: TabBarSettings.PromptStyle) {
        guard let file = cacheFile(named: "prompt-style") else { return }
        try? FileManager.default.createDirectory(
            at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? (style.rawValue + "\n").write(to: file, atomically: true, encoding: .utf8)
    }

    /// The settings as last saved. Read from defaults so config loading, which is not tied
    /// to the main actor, does not have to reach into the settings store.
    private static var saved: TabBarSettings {
        guard !SignalDemo.isRequested,
              let data = UserDefaults.standard.data(forKey: TabBarSettings.storageKey),
              let settings = try? JSONDecoder().decode(TabBarSettings.self, from: data) else { return TabBarSettings() }
        return settings
    }

    /// Path of the overlay file to load after the user's config, or nil when nothing is
    /// overridden. The file is rewritten only when its content changes.
    static func overlayPath() -> String? {
        let settings = saved
        let text = overlay(for: settings)
        guard !text.isEmpty, let file = cacheFile(named: "signal-overlay.conf") else { return nil }
        writePromptStyle(settings.promptStyle)
        if (try? String(contentsOf: file, encoding: .utf8)) != text {
            do {
                try FileManager.default.createDirectory(
                    at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
                try text.write(to: file, atomically: true, encoding: .utf8)
            } catch {
                return nil
            }
        }
        return file.path
    }
}

/// Ghostty X: a scripted walk through the Signal chrome, so a build can be checked from
/// outside the app. Launch with `GHOSTTYX_SIGNAL_DEMO=<folder>`: the app opens tabs and a
/// split, runs harmless commands, moves the tab bar through every position, and drops a
/// `<name>.mark` file in the folder each time a state is ready to be photographed.
/// Settings stay in memory during a demo run.
@MainActor
enum SignalDemo {
    nonisolated static var folder: String? {
        guard let value = ProcessInfo.processInfo.environment["GHOSTTYX_SIGNAL_DEMO"], !value.isEmpty else { return nil }
        return value
    }

    nonisolated static var isRequested: Bool { folder != nil }

    private enum Step {
        case wait(TimeInterval)
        /// A Ghostty binding action on the focused pane.
        case action(String)
        /// Type a command into the focused pane and press return.
        case run(String)
        case change((inout TabBarSettings) -> Void)
        /// Fold or open the nearest labeled command block above the focused pane's cursor.
        case fold
        /// Fold or open a block the way its button does: the newest block that has a
        /// button is 0, the one before it 1, and so on.
        case toggle(Int)
        /// Write the latest fold outcomes to the trace under this name.
        case trail(String)
        /// Press the fold button of the topmost folded block in view.
        case pressTopFold
        /// What Control-F does: fold every block, or open every fold.
        case foldAll
        /// What Shift with the up (true) or down arrow does, and what Control-C then does.
        case pick(Bool)
        case copyPicked
        /// Close tabs until this many are left.
        case closeTabs(Int)
        /// Show one look of the prompt under a finished command, with a command typed
        /// but not run, and photograph it under this name.
        case look(TabBarSettings.PromptStyle, String)
        /// Write the app's memory, and how many tabs and block overlays exist, to the trace.
        case memory(String)
        /// Do nothing for this long and write how much processor time the app used.
        case idle(TimeInterval)
        /// Photograph the window under this name.
        case shot(String)
        /// Write what the command reader returns for the focused pane to debug.txt.
        case dump
        /// Photograph the window and announce that this state is ready.
        case mark(String)
        /// Do something, then photograph the window several times in quick succession,
        /// to see the frames of an animation.
        case burst(String, Int, @MainActor () -> Void)
        /// Switch tabs, toggle the sidebar and move the tab bar many times, quickly.
        case stress(Int)
    }

    private static var steps: [Step] = []
    /// Pictures taken by a burst, held until the burst ends and then written out.
    private static var burstFrames: [(Int, NSBitmapImageRep)] = []

    static func runIfRequested() {
        guard isRequested else { return }
        SignalMotion.report = { trace($0) }
        steps = [
            .change { $0 = TabBarSettings(); $0.position = .left },
            .wait(2.5),
            .action("new_split:right"), .wait(1.2),
            .run("print -r -- prompt=$GHOSTTY_X_PROMPT hooks=$precmd_functions"), .wait(0.6),
            // As installed, nothing folds by itself: long output stays where it was printed.
            .run("seq 1 30"), .wait(0.8), .run("ls -la /usr/share | head -20"), .wait(0.8),
            .run("echo signal demo"), .wait(0.6), .run("ls /"), .wait(0.9), .shot("1a-nothing-folds"),
            // Folded and opened by hand, the way a click on the block's button does it.
            .toggle(0), .wait(0.9), .shot("1b-folded-by-hand"), .trail("by hand: fold"),
            .toggle(0), .wait(0.9), .shot("1c-opened-by-hand"), .trail("by hand: open"),
            // Folding for you, turned on. The fold happens when the next command starts
            // and the cursor stays on its row: compare the two pictures.
            .change { $0.autoFold = true; $0.autoFoldLines = 8 },
            .run("seq 1 25"), .wait(0.8), .shot("1d-before-next-command"),
            .run("true"), .wait(0.9), .shot("1e-folded-for-you"), .trail("for you"),
            // Long output of a command that failed stays open when the next one runs.
            .run("seq 1 12; false"), .wait(0.6), .run("echo after a failure"), .wait(0.7),
            .shot("1f-failed-stays-open"), .trail("after a failure"),
            .action("new_tab"), .wait(1.2), .run("seq 1 5"),
            .action("new_tab"), .wait(1.2),
            .action("goto_tab:1"), .wait(1.5),
            .mark("1-left"),
            .dump,
            .fold, .wait(0.9), .shot("1g-expanded"),
            .fold, .wait(0.9), .shot("1h-refolded"),
            .run("seq 1 7"), .wait(0.5), .run("seq 1 6"), .wait(0.5), .run("seq 1 7"), .wait(0.5),
            .run("seq 1 40"), .wait(0.7), .run("date"), .wait(0.9),
            .shot("1i-full"),
            .fold, .wait(0.9), .shot("1j-full-expanded"),
            .fold, .wait(0.9), .shot("1k-full-refolded"),
            // The moment after opening, slowed down, to see the line run down the block.
            .burst("slow", 0) { SignalMotion.slowdown = 6 },
            .burst("1l-opening", 5) {
                if let surface = focusedSurface()?.surface { _ = ghostty_surface_fold_toggle_last(surface) }
            }, .wait(0.5),
            .burst("1m-folding", 4) {
                if let surface = focusedSurface()?.surface { _ = ghostty_surface_fold_toggle_last(surface) }
            }, .wait(0.5),
            .burst("slow", 0) { SignalMotion.slowdown = 1 },
            .mark("2-commands"),
            // Output longer than the screen is folded from its last rows: the command
            // line, up in the scrollback, comes back down into view.
            .run("seq 1 45"), .wait(0.8), .shot("1n-long-output"),
            .toggle(0), .wait(0.8), .shot("1o-folded-from-its-end"), .trail("from its end"),
            // A fold whose command line has scrolled into the scrollback cannot be opened
            // in place, so its button shows the kept output in a panel instead.
            .run("seq 1 50"), .wait(0.8), .action("scroll_page_up"), .wait(0.6),
            .pressTopFold, .wait(0.7), .shot("1p-peek"),
            .action("scroll_to_bottom"), .wait(0.6), .shot("1q-peek-gone"),
            // Control-F: everything folds, and again, everything on the screen opens.
            .foldAll, .wait(0.8), .shot("1r-all-folded"),
            .foldAll, .wait(0.8), .shot("1s-all-opened"),
            .foldAll, .wait(0.8), .shot("1t-all-folded-again"),
            // Shift with the up arrow, three times, then down once, then Control-C.
            .pick(true), .pick(true), .pick(true), .pick(false), .wait(0.3), .shot("1u-picked"),
            .copyPicked, .wait(0.3), .shot("1v-copied"),
            .change { $0.sidebarCollapsed = true }, .wait(0.9), .mark("3-collapsed"),
            // Each look of the prompt, in a folder with a branch and a Python environment,
            // with something typed: the state the designs were drawn in.
            .run("mkdir -p /tmp/Projects/DEMO/REPOS/.git /tmp/Projects/DEMO/REPOS/env/REPOS; cd /tmp/Projects/DEMO/REPOS"),
            .run("print 'ref: refs/heads/feat/blocks' > .git/HEAD; print 'version = 3.12.11' > env/REPOS/pyvenv.cfg"),
            .run("export VIRTUAL_ENV=$PWD/env/REPOS"), .wait(0.4),
            .look(.rail, "q1-rail"), .look(.capsule, "q2-capsule"), .look(.dock, "q3-dock"),
            .look(.hud, "q4-hud"), .look(.card, "q0-card"),
            .change { $0.promptStyle = .rail }, .run("unset VIRTUAL_ENV; cd /tmp; clear"), .wait(0.5),
            .change { $0.sidebarCollapsed = false; $0.position = .top }, .wait(1.2), .mark("4-top"),
            // Memory: the same rush of tabs opened, switched and closed, three times over.
            // What is left afterwards should level off, not climb with every round.
            .closeTabs(2), .wait(1.5), .memory("before the rounds"),
            .stress(70), .wait(1.0), .closeTabs(2), .wait(1.5), .memory("after round 1"),
            .stress(70), .wait(1.0), .closeTabs(2), .wait(1.5), .memory("after round 2"),
            .change { $0.position = .bottom }, .wait(1.2), .mark("5-bottom"),
            .stress(70), .wait(1.0), .closeTabs(2), .wait(1.5), .memory("after round 3"),
            // Left alone: what the app costs while nothing happens, with the command
            // blocks and then without them, to see what they add.
            .idle(5),
            .change { $0.commandBlocks = false }, .idle(4), .change { $0.commandBlocks = true },
            .change { $0.position = .right }, .wait(1.2), .mark("6-right"),
            .change { $0.position = .left }, .wait(1.0),
            // At real speed, with nothing else going on, to time the frames.
            .burst("timed", 0) { TabBarSettingsStore.shared.settings.sidebarCollapsed = true }, .wait(0.6),
            .burst("timed", 0) { TabBarSettingsStore.shared.settings.sidebarCollapsed = false }, .wait(0.6),
            .burst("timed", 0) { _ = focusedSurface()?.surfaceModel?.perform(action: "new_tab") }, .wait(1.0),
            .burst("timed", 0) { _ = focusedSurface()?.surfaceModel?.perform(action: "goto_tab:1") }, .wait(0.8),
            // Slowed down, to photograph the frames in between.
            .burst("slow", 0) { SignalMotion.slowdown = 6 },
            .burst("8-collapse", 6) { TabBarSettingsStore.shared.settings.sidebarCollapsed = true }, .wait(0.6),
            .burst("9-expand", 6) { TabBarSettingsStore.shared.settings.sidebarCollapsed = false }, .wait(0.6),
            .burst("11-switch", 6) { _ = focusedSurface()?.surfaceModel?.perform(action: "goto_tab:2") }, .wait(1.4),
            .burst("slow", 0) { SignalMotion.slowdown = 1 },
            .stress(70), .wait(1.2), .shot("12-after-stress"),
            .action("goto_tab:2"), .wait(0.12), .mark("7-switching"),
        ]
        play(0)
    }

    /// The memory the app is charged with (what Activity Monitor shows), in megabytes.
    private static func footprint() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        return result == KERN_SUCCESS ? Double(info.phys_footprint) / 1_048_576 : -1
    }

    private static func memoryReport(_ name: String) -> String {
        let tabs = currentWindow()?.tabGroup?.windows.count ?? 1
        return String(
            format: "memory (%@): %.1f MB, %d tabs, %d block overlays",
            name, footprint(), tabs, SignalBlockView.liveCount)
    }

    /// The latest fold outcomes, oldest first: "[code a b c]" each (see fold.zig).
    private static func trail(last: UInt32) -> String {
        let recorded = ghostty_fold_trail(0xffff, 0)
        var report = ""
        for back in (0..<min(recorded, last)).reversed() {
            let index = recorded - 1 - back
            let values = (0..<4).map { String(ghostty_fold_trail(index, UInt32($0))) }
            report += " [" + values.joined(separator: " ") + "]"
        }
        return report
    }

    /// The terminal window currently showing (the selected tab of the front tab group).
    private static func currentWindow() -> NSWindow? {
        let terminals = NSApp.orderedWindows.filter { $0.windowController is BaseTerminalController }
        let front = [NSApp.keyWindow, NSApp.mainWindow].compactMap { $0 }
            .first { $0.windowController is BaseTerminalController } ?? terminals.first
        return front?.tabGroup?.selectedWindow ?? front
    }

    /// Appends a line to trace.txt in the demo folder. Does nothing outside a demo run.
    static func trace(_ text: @autoclosure () -> String) {
        guard let folder else { return }
        let line = text().unicodeScalars.map { $0.value >= 32 && $0.value < 127 ? String($0) : String(format: "<%X>", $0.value) }
            .joined() + "\n"
        let path = folder + "/trace.txt"
        if let handle = FileHandle(forWritingAtPath: path) {
            handle.seekToEndOfFile()
            handle.write(Data(line.utf8))
            handle.closeFile()
        } else {
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            FileManager.default.createFile(atPath: path, contents: Data(line.utf8))
        }
    }

    private static func focusedSurface() -> Ghostty.SurfaceView? {
        guard let controller = currentWindow()?.windowController as? BaseTerminalController else { return nil }
        return controller.focusedSurface ?? controller.surfaceTree.root?.leaves().last
    }

    /// Writes a picture of a window's own views (titlebar included) as a PNG. This needs no
    /// screen recording permission, but the terminal text itself is drawn by Metal and
    /// stays blank in it; the chrome around it is what this is for.
    private static func snapshot(_ window: NSWindow, to path: String) {
        guard let frame = window.contentView?.superview, frame.bounds.width > 1, frame.bounds.height > 1,
              let rep = frame.bitmapImageRepForCachingDisplay(in: frame.bounds) else { return }
        frame.cacheDisplay(in: frame.bounds, to: rep)
        guard let data = rep.representation(using: .png, properties: [:]) else { return }
        try? data.write(to: URL(fileURLWithPath: path))
    }

    private static func play(_ index: Int) {
        guard let folder, steps.indices.contains(index) else { return }
        var delay: TimeInterval = 0.4
        switch steps[index] {
        case .wait(let seconds):
            delay = seconds
        case .action(let action):
            _ = focusedSurface()?.surfaceModel?.perform(action: action)
        case .run(let command):
            // `text:` takes Zig string escapes; \x0d is the return key.
            _ = focusedSurface()?.surfaceModel?.perform(action: "text:" + command + "\\x0d")
        case .change(let change):
            change(&TabBarSettingsStore.shared.settings)
        case .fold:
            if let surface = focusedSurface()?.surface {
                let changed = ghostty_surface_fold_toggle_last(surface)
                trace("fold toggle changed=\(changed)" + trail(last: 4))
            }
        case .toggle(let back):
            if let surface = focusedSurface()?.surface {
                var buffer = [ghostty_block_s](repeating: ghostty_block_s(), count: 64)
                var geometry = ghostty_block_geometry_s()
                let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
                    guard let base = pointer.baseAddress else { return 0 }
                    return Int(ghostty_surface_blocks(surface, base, UInt32(pointer.count), &geometry))
                }
                // Bit 8: the block has a fold button.
                let able = Array(buffer.prefix(count).filter { $0.flags & (1 << 8) != 0 })
                let index = able.count - 1 - back
                if able.indices.contains(index) {
                    let block = able[index]
                    let row = UInt32(max(0, block.head >= 0 ? block.head : block.top))
                    let changed = ghostty_surface_block_toggle(surface, row)
                    trace("block toggle row=\(row) changed=\(changed)" + trail(last: 3))
                } else {
                    trace("block toggle: no block \(back) among \(able.count) with a button")
                }
            }
        case .trail(let name):
            trace("fold trail (\(name)):" + trail(last: 6))
        case .foldAll:
            if let surface = focusedSurface()?.surface {
                trace("fold all: \(ghostty_surface_fold_toggle_all(surface)) changed" + trail(last: 2))
            }
        case .pick(let up):
            if let surfaceView = focusedSurface() {
                trace("pick \(up ? "up" : "down"): taken=\(SignalBlockView.moveSelection(of: surfaceView, up: up))")
            }
        case .copyPicked:
            if let surfaceView = focusedSurface() {
                // The demo checks the clipboard and then puts back what you had on it.
                let before = NSPasteboard.general.string(forType: .string)
                let taken = SignalBlockView.copySelection(of: surfaceView)
                let copied = NSPasteboard.general.string(forType: .string) ?? ""
                trace("copy picked: taken=\(taken) clipboard has \(copied.count) characters,"
                    + " \(copied.split(separator: "\n").count) lines")
                if let before { SignalText.copy(before) }
            }
        case .look(let style, let name):
            TabBarSettingsStore.shared.settings.promptStyle = style
            let surface = focusedSurface()?.surfaceModel
            // \x0d is the return key, \x15 clears the line again afterwards.
            _ = surface?.perform(action: "text:clear\\x0d")
            let after: [(TimeInterval, @MainActor () -> Void)] = [
                (0.35, { _ = surface?.perform(action: "text:echo On branch feat/blocks\\x0d") }),
                (0.8, { _ = surface?.perform(action: "text:git status") }),
                (1.3, { if let window = currentWindow() { snapshot(window, to: folder + "/" + name + "-self.png") } }),
                (1.45, { _ = surface?.perform(action: "text:\\x15") }),
            ]
            for (at, work) in after {
                DispatchQueue.main.asyncAfter(deadline: .now() + at) { MainActor.assumeIsolated { work() } }
            }
            delay = 1.7
        case .closeTabs(let keep):
            let extra = max(0, (currentWindow()?.tabGroup?.windows.count ?? 1) - keep)
            for turn in 0..<extra {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(turn) * 0.3) {
                    MainActor.assumeIsolated {
                        _ = focusedSurface()?.surfaceModel?.perform(action: "close_tab")
                    }
                }
            }
            delay = 0.4 + Double(extra) * 0.3
        case .memory(let name):
            trace(memoryReport(name))
        case .idle(let seconds):
            let cpu = clock()
            let started = ProcessInfo.processInfo.systemUptime
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                MainActor.assumeIsolated {
                    // clock() counts millionths of a second of processor time.
                    let used = Double(clock() - cpu) / 1_000_000
                    let wall = ProcessInfo.processInfo.systemUptime - started
                    trace(String(
                        format: "idle for %.1f s: %.0f ms of processor time, %.1f%% of one core",
                        wall, used * 1000, used / wall * 100))
                }
            }
            delay = seconds + 0.2
        case .pressTopFold:
            if let surfaceView = focusedSurface() {
                trace("top fold pressed, peek shown=\(SignalBlockView.pressTopFold(of: surfaceView))")
            }
        case .shot(let name):
            if let window = currentWindow() { snapshot(window, to: folder + "/" + name + "-self.png") }
        case .dump:
            let status = ghostty_fold_last_status()
            var report = "fold threshold \(TabBarSettingsStore.shared.settings.foldThreshold)"
                + " last status \(status & 0xff) rows \(status >> 8)\n"
            let recorded = ghostty_fold_trail(0xffff, 0)
            report += "fold outcomes \(recorded) (code first last cursor):\n"
            for index in 0..<min(recorded, 16) {
                let values = (0..<4).map { String(ghostty_fold_trail(UInt32(index), UInt32($0))) }
                report += "  " + values.joined(separator: " ") + "\n"
            }
            if let surface = focusedSurface() {
                for back in 0..<5 {
                    let output = surface.commandText(back: back)
                    let input = surface.commandText(back: back, input: true)
                    let lines = output.map { $0.split(separator: "\n", omittingEmptySubsequences: false).count } ?? -1
                    let first = output.flatMap { $0.split(separator: "\n").first }.map { String($0) } ?? "nil"
                    report += "back \(back): input=[\(input ?? "nil")] lines=\(lines) first=[\(first)]\n"
                }
            }
            try? report.write(toFile: folder + "/debug.txt", atomically: true, encoding: .utf8)
        case .burst(let name, let count, let change):
            change()
            // Pictures are taken first and written afterwards, so encoding them does not
            // stall the animation being photographed.
            burstFrames = []
            let spacing = SignalMotion.slowdown > 1 ? 0.28 : 0.06
            for frame in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02 + Double(frame) * spacing) {
                    MainActor.assumeIsolated {
                        guard let window = currentWindow(), let view = window.contentView?.superview,
                              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return }
                        view.cacheDisplay(in: view.bounds, to: rep)
                        burstFrames.append((frame, rep))
                        guard frame == count - 1 else { return }
                        let frames = burstFrames
                        burstFrames = []
                        for (number, rep) in frames {
                            let data = rep.representation(using: .jpeg, properties: [.compressionFactor: 0.6])
                            try? data?.write(to: URL(fileURLWithPath: folder + "/" + name + "-\(number).jpg"))
                        }
                    }
                }
            }
            delay = 0.3 + Double(count) * spacing
        case .stress(let count):
            for turn in 0..<count {
                DispatchQueue.main.asyncAfter(deadline: .now() + Double(turn) * 0.035) {
                    MainActor.assumeIsolated {
                        if turn % 9 == 4 {
                            TabBarSettingsStore.shared.settings.sidebarCollapsed.toggle()
                        } else if turn % 17 == 8 {
                            let positions: [TabBarSettings.Position] = [.left, .top, .right, .bottom]
                            TabBarSettingsStore.shared.settings.position = positions[(turn / 17) % 4]
                        } else if turn % 23 == 11 {
                            _ = focusedSurface()?.surfaceModel?.perform(action: "new_tab")
                        } else {
                            _ = focusedSurface()?.surfaceModel?.perform(action: "goto_tab:\(turn % 4 + 1)")
                        }
                        if turn == count - 1 {
                            TabBarSettingsStore.shared.settings.sidebarCollapsed = false
                            TabBarSettingsStore.shared.settings.position = .left
                            trace("stress finished after \(count) turns")
                        }
                    }
                }
            }
            delay = 0.3 + Double(count) * 0.035
        case .mark(let name):
            trace("fonts AppKit could not give so far: \(SignalFont.misses)")
            trace(memoryReport("at " + name))
            // Focus chrome needs the app to be frontmost, as it is in real use.
            NSApp.activate(ignoringOtherApps: true)
            try? FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
            if let window = currentWindow() { snapshot(window, to: folder + "/" + name + "-self.png") }
            FileManager.default.createFile(atPath: folder + "/" + name + ".mark", contents: nil)
            delay = 1.8
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            MainActor.assumeIsolated { play(index + 1) }
        }
    }
}

/// Ghostty X: runs one short animation by stepping a progress value on a timer.
///
/// The Signal chrome moves real geometry (frames, constraint constants, a drawing
/// progress) rather than leaning on implicit layer animations, which do nothing in a
/// window that is not on screen yet and never show the in-between states to a snapshot.
/// A motion costs nothing while idle: the timer exists only while it runs.
@MainActor
final class SignalMotion {
    enum Curve {
        /// Fast start, gentle stop.
        case easeOut
        /// Runs a little past the end and settles back.
        case spring
    }

    /// Stretches every motion, so a demo run can photograph the frames in between.
    static var slowdown: Double = 1
    /// Receives one line about each named motion as it ends: how many frames it drew and
    /// the longest any of them took. Only a demo run sets this.
    static var report: ((String) -> Void)?

    /// What the motion is called in reports.
    var name = ""

    private var timer: Timer?
    private var finish: (() -> Void)?

    var isRunning: Bool { timer != nil }

    /// Calls `step` with eased progress from 0 to 1 over `duration`, ending exactly on 1.
    /// A motion that is already running is cut short at its end value first.
    ///
    /// With a `delay` the motion holds at its start for that long first. A window that
    /// has just been made is busy for a moment; a motion that waits it out is seen whole.
    func run(
        duration: TimeInterval,
        curve: Curve = .easeOut,
        delay: TimeInterval = 0,
        step: @escaping (CGFloat) -> Void
    ) {
        stop()
        let duration = duration * Self.slowdown
        finish = { step(1) }
        step(0)
        // The clock starts after the first step. That step often does the one expensive
        // thing (a relayout, a terminal resize), and counting it would skip the start of
        // the motion.
        let started = ProcessInfo.processInfo.systemUptime + delay
        var frames = 0
        var last = ProcessInfo.processInfo.systemUptime
        var longestGap: TimeInterval = 0
        var longestStep: TimeInterval = 0
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self, self.timer === timer else { timer.invalidate(); return }
                let now = ProcessInfo.processInfo.systemUptime
                guard now >= started else { last = now; return }
                let elapsed = now - started
                longestGap = max(longestGap, now - last)
                last = now
                frames += 1
                if elapsed >= duration {
                    self.stop()
                    if let report = Self.report, !self.name.isEmpty {
                        report(String(
                            format: "motion %@: %d frames in %.0f ms, longest gap %.1f ms, longest step %.1f ms",
                            self.name, frames, elapsed * 1000, longestGap * 1000, longestStep * 1000))
                    }
                } else {
                    step(Self.ease(CGFloat(elapsed / duration), curve))
                    longestStep = max(longestStep, ProcessInfo.processInfo.systemUptime - now)
                }
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    /// Ends the motion at its final value.
    func stop() {
        timer?.invalidate()
        timer = nil
        let finish = self.finish
        self.finish = nil
        finish?()
    }

    static func ease(_ t: CGFloat, _ curve: Curve) -> CGFloat {
        let back = t - 1
        switch curve {
        case .easeOut: return 1 + back * back * back
        case .spring:
            let overshoot: CGFloat = 1.6
            return 1 + (overshoot + 1) * back * back * back + overshoot * back * back
        }
    }
}

extension NSWindow {
    /// Whether this is the window being looked at: on screen, and the selected tab of its
    /// tab group. Every tab is a window of its own, and the ones behind also count as
    /// visible, so chrome that animates asks this instead.
    var isFrontTab: Bool {
        guard isVisible else { return false }
        if let selected = tabGroup?.selectedWindow { return selected === self }
        return true
    }
}

/// Small text helpers shared by the Signal chrome (sidebar cards, pane headers, status line).
enum SignalText {
    /// "~" for the home directory, otherwise the last `components` path components.
    static func abbreviate(path: String, components: Int = 2) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        let parts = path.split(separator: "/")
        guard parts.count > components else {
            return path.hasPrefix(home + "/") ? "~/" + String(path.dropFirst(home.count + 1)) : path
        }
        return parts.suffix(components).joined(separator: "/")
    }

    /// The text without control, private-use and unassigned characters. Titles come from
    /// whatever the shell or a program sets, and the chrome's fonts cannot draw those.
    static func printable(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .privateUse, .surrogate, .unassigned, .lineSeparator, .paragraphSeparator:
                continue
            default:
                scalars.append(scalar)
            }
        }
        return String(scalars)
    }

    /// `printable` text without emoji, for strings the chrome draws itself. Its labels are
    /// set in the monospaced system font, where an emoji comes from another font and
    /// breaks the even rhythm, so they are left out. (This was first added in the belief
    /// that emoji caused a Core Text crash. That crash was a label with no font: see
    /// `SignalFont`.)
    static func chromeSafe(_ text: String) -> String {
        var scalars = String.UnicodeScalarView()
        for scalar in printable(text).unicodeScalars {
            let properties = scalar.properties
            if properties.isEmojiPresentation || properties.isEmojiModifier { continue }
            if properties.isEmoji, scalar.value > 0x2000 { continue }
            // Joiners and variation selectors that only exist to build emoji.
            if scalar.value == 0x200D || (0xFE00...0xFE0F).contains(scalar.value) { continue }
            scalars.append(scalar)
        }
        return String(scalars).trimmingCharacters(in: .whitespaces)
    }

    /// Paragraph styles shared by every single-line label the chrome draws.
    static let truncating: NSParagraphStyle = paragraph(.natural)
    static let truncatingCentered: NSParagraphStyle = paragraph(.center)

    private static func paragraph(_ alignment: NSTextAlignment) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        style.alignment = alignment
        return style.copy() as? NSParagraphStyle ?? style
    }

    /// The path with the home directory written as "~".
    static func tilde(_ path: String) -> String {
        let home = NSHomeDirectory()
        if path == home { return "~" }
        return path.hasPrefix(home + "/") ? "~" + String(path.dropFirst(home.count)) : path
    }

    /// True when a title is only the directory itself, which is what shells set by default.
    static func isDirectoryTitle(_ title: String, path: String?) -> Bool {
        guard let path, !path.isEmpty else { return false }
        return title == path || title == tilde(path) || title == abbreviate(path: path)
    }

    /// A, B, C… for a pane's position in its window.
    static func paneLetter(_ index: Int) -> String {
        let letters = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ")
        return String(letters[max(0, index) % letters.count])
    }

    /// Puts text on the general pasteboard.
    static func copy(_ text: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
    }

    /// Zero-padded position: 01, 02…
    static func ordinal(_ index: Int) -> String {
        index < 9 ? "0\(index + 1)" : "\(index + 1)"
    }
}

/// Shared, persisted tab bar settings. Every tab strip and window subscribes to `$settings`.
@MainActor
final class TabBarSettingsStore: ObservableObject {
    /// A demo run keeps its settings in memory, so it never changes the saved ones.
    static let shared = TabBarSettingsStore(defaults: SignalDemo.isRequested ? nil : .standard)
    static let defaultsKey = TabBarSettings.storageKey

    @Published var settings: TabBarSettings {
        didSet {
            guard settings != oldValue else { return }
            save()
            ghostty_set_fold_threshold(settings.foldThreshold)
            ghostty_set_fold_latest(settings.foldsNewest)
            if settings.promptStyle != oldValue.promptStyle { SignalColors.writePromptStyle(settings.promptStyle) }
            // Colors and the prompt are applied through the terminal config.
            if SignalColors.overlay(for: settings) != SignalColors.overlay(for: oldValue), defaults != nil {
                (NSApp.delegate as? AppDelegate)?.ghostty.reloadConfig()
            }
        }
    }

    private let defaults: UserDefaults?

    /// Pass nil for an in-memory store (tests and previews).
    init(defaults: UserDefaults? = .standard) {
        self.defaults = defaults
        if let data = defaults?.data(forKey: Self.defaultsKey),
           let decoded = try? JSONDecoder().decode(TabBarSettings.self, from: data) {
            settings = decoded
        } else {
            settings = TabBarSettings()
        }
        ghostty_set_fold_threshold(settings.foldThreshold)
        ghostty_set_fold_latest(settings.foldsNewest)
        SignalShortcuts.install()
    }

    func reset() { settings = TabBarSettings() }

    private func save() {
        guard let defaults, let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: Self.defaultsKey)
    }
}

/// Ghostty X's own keys: Control-S shows or hides the sidebar, Control-F folds every
/// command block or opens every fold, and Shift with the up and down arrows picks a
/// block for Control-C to copy (see `SignalBlockView.handleKey`).
///
/// Both are keys that terminal programs use too (Control-F pages forward in vim and
/// less, Control-S searches or saves in editors). So they are only taken while the
/// shell has the plain screen: with an editor or a pager showing, the key goes to it
/// as always. Control-F is also only taken at a prompt, which is the only time blocks
/// can be folded. One monitor for the whole app, and it does nothing but compare a key.
@MainActor
enum SignalShortcuts {
    private static var monitor: Any?

    static func install() {
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let taken = MainActor.assumeIsolated { handle(event) }
            return taken ? nil : event
        }
    }

    /// True when the key was one of ours and was acted on.
    private static func handle(_ event: NSEvent) -> Bool {
        let settings = TabBarSettingsStore.shared.settings
        guard settings.isSignal, let window = event.window,
              let controller = window.windowController as? BaseTerminalController,
              // Typing in a field (search, a tab's name) is not typing in the terminal.
              !(window.firstResponder is NSText),
              let surfaceView = controller.focusedSurface, let surface = surfaceView.surface else { return false }

        // Picking a block and copying it (Shift with the arrows, then Control-C).
        if settings.blockKeys, settings.showsCommandBlocks, SignalBlockView.handleKey(event, in: surfaceView) {
            return true
        }

        let held = event.modifierFlags.intersection([.control, .command, .option, .shift])
        guard held == .control, let key = event.charactersIgnoringModifiers?.lowercased(),
              key == "s" || key == "f" else { return false }

        if key == "s" {
            guard settings.sidebarKey, settings.usesSessionCards, ghostty_surface_plain_screen(surface) else {
                return false
            }
            TabBarSettingsStore.shared.settings.sidebarCollapsed.toggle()
            return true
        }
        guard settings.foldAllKey, settings.showsCommandBlocks else { return false }
        // -1: a program is running or has the screen, and the key is its own.
        return ghostty_surface_fold_toggle_all(surface) >= 0
    }
}

/// The keys worth remembering, for the free middle of the status line.
///
/// The app's own keys are listed when they are turned on. The terminal's are read from
/// the configuration that is loaded, so a key you rebound shows as you bound it and an
/// action with no key is left out. The list is worked out once and kept until a setting
/// or the configuration changes.
@MainActor
enum SignalHints {
    struct Hint: Equatable {
        var keys: String
        var label: String
    }

    private struct Source: Equatable {
        var pick: Bool
        var foldAll: Bool
        var sidebar: Bool
        var config: ObjectIdentifier?
    }

    private static var kept: (source: Source, hints: [Hint])?

    /// Most useful first: the status line shows as many as fit.
    static func current(_ settings: TabBarSettings) -> [Hint] {
        guard settings.isSignal, settings.statusHints else { return [] }
        let config = (NSApp.delegate as? AppDelegate)?.ghostty.config
        let source = Source(
            pick: settings.blockKeys && settings.showsCommandBlocks,
            foldAll: settings.foldAllKey && settings.showsCommandBlocks,
            sidebar: settings.sidebarKey && settings.usesSessionCards,
            config: config.map { ObjectIdentifier($0) })
        if let kept, kept.source == source { return kept.hints }

        var hints: [Hint] = []
        func bound(_ action: String, _ label: String) {
            guard let keys = config?.keyboardShortcut(for: action)?.keyList, !keys.isEmpty else { return }
            hints.append(Hint(keys: keys.joined(), label: label))
        }
        bound("new_tab", "new tab")
        bound("new_split:right", "split")
        if source.pick { hints.append(Hint(keys: "\u{21E7}\u{2191}\u{2193}", label: "pick block")) }
        if source.foldAll { hints.append(Hint(keys: "\u{2303}F", label: "fold all")) }
        if source.sidebar { hints.append(Hint(keys: "\u{2303}S", label: "sidebar")) }
        bound("goto_split:next", "next pane")
        bound("toggle_split_zoom", "zoom pane")
        bound("clear_screen", "clear")
        bound("close_surface", "close")
        kept = (source, hints)
        return hints
    }
}

/// Fonts for everything the chrome draws itself, made once and kept for good.
///
/// The tab strip used to ask AppKit for a font inside every draw call. While tabs were
/// opened and switched quickly, a label now and then reached Core Text with no font in
/// its attributes (the key was there, the value was nil), Core Text raised an exception
/// from inside `draw`, and that ends the app: it cannot be caught on the way out of Core
/// Text. Which step inside AppKit loses the font was not pinned down; asking afresh
/// thousands of times in a row never returned nil. What is established is that the
/// crash came with fonts being made and dropped on every frame, and that it has not come
/// back since each font is made once and held here. As a second line, the font call
/// goes through a wrapper declared nullable, so a nil from AppKit is handled rather than
/// passed on, and a label is never handed a nil font.
enum SignalFont {
    private enum Kind: Int { case system = 0, mono = 1, digits = 2, titleBar = 3 }

    private struct Key: Hashable {
        var kind: Int
        var size: CGFloat
        var weight: CGFloat
    }

    private static let lock = NSLock()
    private static var made: [Key: NSFont] = [:]
    private static var lastMade: NSFont?
    private static var missed = 0

    /// How many times AppKit had no font to give. For the demo run's report.
    static var misses: Int {
        lock.lock()
        defer { lock.unlock() }
        return missed
    }

    static func system(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(.system, size, weight)
    }

    static func mono(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(.mono, size, weight)
    }

    /// The system font with digits that all take the same width.
    static func digits(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
        font(.digits, size, weight)
    }

    static func titleBar() -> NSFont {
        font(.titleBar, NSFont.systemFontSize, .regular)
    }

    private static func font(_ kind: Kind, _ size: CGFloat, _ weight: NSFont.Weight) -> NSFont {
        let key = Key(kind: kind.rawValue, size: size, weight: weight.rawValue)
        lock.lock()
        defer { lock.unlock() }
        if let font = made[key] { return font }
        if let font = GhosttyChromeFont(kind.rawValue, size, weight.rawValue) {
            made[key] = font
            lastMade = font
            return font
        }
        // Nothing this time. Any font that exists will do for one frame, and the next
        // draw asks again.
        missed += 1
        return lastMade
            ?? GhosttyChromeFont(Kind.system.rawValue, size, NSFont.Weight.regular.rawValue)
            ?? NSFont(name: "Menlo", size: size)
            ?? NSFont(name: "Helvetica", size: size)
            ?? NSFont.systemFont(ofSize: size)
    }
}

/// Drawing and measuring for the chrome's labels, with one last check: a label with no
/// font in its attributes is skipped, because typesetting it would end the app (see
/// `SignalFont`). It is drawn again the next time its view draws.
extension NSAttributedString {
    private var hasFont: Bool {
        length == 0 || attribute(.font, at: 0, effectiveRange: nil) is NSFont
    }

    func safeSize() -> NSSize {
        hasFont ? size() : .zero
    }

    func safeDraw(at point: NSPoint) {
        if hasFont { draw(at: point) }
    }

    func safeDraw(with rect: NSRect, options: NSString.DrawingOptions) {
        if hasFont { draw(with: rect, options: options) }
    }
}
