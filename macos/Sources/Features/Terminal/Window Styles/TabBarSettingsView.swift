import AppKit
import SwiftUI

/// The "Tab Bar" settings window: controls on the left, a live preview on the right.
/// Every change is written to `TabBarSettingsStore.shared`, which open windows follow live.
@MainActor
final class TabBarSettingsController: NSWindowController, NSWindowDelegate {
    static let shared = TabBarSettingsController()

    private let previewModel = PreviewTabModel()

    private init() {
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 940, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: true)
        window.title = "Sigpane Settings"
        window.isReleasedWhenClosed = false
        window.minSize = NSSize(width: 820, height: 520)
        window.setFrameAutosaveName("GhosttyXTabBarSettings")
        super.init(window: window)
        window.delegate = self
        window.contentViewController = NSHostingController(
            rootView: TabBarSettingsView(store: .shared, model: previewModel))
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    func show() {
        guard let window else { return }
        if !window.isVisible, window.frameAutosaveName.isEmpty || !window.setFrameUsingName(window.frameAutosaveName) {
            window.center()
        }
        previewModel.refresh()
        showWindow(nil)
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}

/// Sample tabs for the preview. Clicking, closing, adding, reordering and coloring all work.
@MainActor
final class PreviewTabModel: RoundedTerminalTabModel {
    private final class Item {
        var title: String
        var color: TerminalTabColor
        var slot: Int?
        var activity: AgentActivity.Summary
        init(_ title: String, activity: AgentActivity.Session? = nil) {
            self.title = title
            self.color = .none
            self.activity = .init(sessions: activity.map { [$0] } ?? [])
        }
    }

    private var items: [Item] = [
        Item("zsh"), Item("npm run dev"), Item("logs"),
        Item("api-service", activity: .init(
            provider: .claude, phase: .running, tool: "Edit", target: "routes.swift",
            subagents: [.init(id: "1", type: "Explore"), .init(id: "2", type: "Plan", done: true)], context: 62)),
        Item("release-tools", activity: .init(provider: .codex, phase: .approval, tool: "Bash", target: "git push")),
    ]
    private var selected = 0
    private var counter = 2
    /// Sample directories for the second line of a Signal session card.
    private static let directories = ["~", "web/app", "projects/api", "var/log", "~/notes", "work/tools"]

    init() {
        super.init(hostWindow: nil)
        publish()
    }

    override func refresh() { publish() }

    private func publish() {
        for (index, item) in items.enumerated() where item.slot == nil {
            let before = index > 0 ? items[index - 1].slot : nil
            let after = index + 1 < items.count ? items[index + 1].slot : nil
            item.slot = Self.randomColorSlot(avoiding: [before, after])
        }
        tabs = items.enumerated().map { index, item in
            Tab(id: ObjectIdentifier(item), window: Weak(nil), title: item.title,
                color: item.color, selected: index == selected, autoColor: item.slot,
                subtitle: Self.directories[index % Self.directories.count], activity: item.activity)
        }
    }

    override func shuffleColors() {
        var previous: Int?
        for item in items {
            item.slot = Self.randomColorSlot(avoiding: [previous])
            previous = item.slot
        }
        publish()
    }

    private func index(of tab: Tab) -> Int? { items.firstIndex { ObjectIdentifier($0) == tab.id } }

    override func select(_ tab: Tab) {
        guard let index = index(of: tab) else { return }
        selected = index
        publish()
    }

    override func close(_ tab: Tab) {
        guard items.count > 1, let index = index(of: tab) else { return }
        items.remove(at: index)
        if selected > index || selected >= items.count { selected = max(0, selected - 1) }
        publish()
    }

    override func move(_ tab: Tab, by offset: Int) {
        guard let index = index(of: tab) else { return }
        let destination = min(max(index + offset, 0), items.count - 1)
        guard destination != index else { return }
        let current = items[selected]
        items.insert(items.remove(at: index), at: destination)
        selected = items.firstIndex { $0 === current } ?? 0
        publish()
    }

    override func reorder(_ identifiers: [String], before destination: Tab) -> Bool {
        guard let id = identifiers.first,
              let source = tabs.first(where: { String(describing: $0.id) == id }),
              let from = index(of: source), let to = index(of: destination) else { return false }
        let current = items[selected]
        items.insert(items.remove(at: from), at: to)
        selected = items.firstIndex { $0 === current } ?? 0
        publish()
        return true
    }

    override func newTab() {
        items.append(Item("zsh \(counter)"))
        counter += 1
        selected = items.count - 1
        publish()
    }

    override func rename(_ tab: Tab) { select(tab) }
    override func detach(_ tab: Tab) {}

    override func setColor(_ color: TerminalTabColor, for tab: Tab) {
        guard let index = index(of: tab) else { return }
        items[index].color = color
        publish()
    }

    var selectedTitle: String { items.indices.contains(selected) ? items[selected].title : "" }
}

// MARK: - SwiftUI

struct TabBarSettingsView: View {
    @ObservedObject var store: TabBarSettingsStore
    @ObservedObject var model: PreviewTabModel
    @State private var theme = RoundedTabTheme.current

    private var settings: Binding<TabBarSettings> { $store.settings }

    var body: some View {
        HStack(spacing: 0) {
            controls
                .frame(width: 320)
            Divider()
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Live preview").font(.headline)
                    Spacer()
                    Text("Click tabs, close them, or press + to add one")
                        .font(.caption).foregroundStyle(.secondary)
                }
                TabBarPreview(store: store, model: model, theme: theme)
                Text("Changes apply to every open window as you make them.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 820, minHeight: 520)
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyConfigDidChange)) { note in
            if note.object == nil { theme = RoundedTabTheme.current }
        }
    }

    private var controls: some View {
        Form {
            Section("Design") {
                Picker("Look", selection: settings.design) {
                    ForEach(TabBarSettings.Design.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.settings.isSignal {
                    Toggle("Tint follows the selected tab", isOn: settings.tintFollowsTab)
                    Toggle("Animations", isOn: settings.animations)
                }
            }
            if store.settings.isSignal {
                AgentActivitySettings(
                    groupSessions: settings.groupAgentSessions,
                    showApprovalShortcut: settings.showApprovalShortcut,
                    toolDetails: settings.agentToolDetails)
                Section("Terminal") {
                    Toggle("Signal Void colors", isOn: settings.signalColors)
                        .help("Applies the dark Signal palette over your theme. Your config file is not changed.")
                    Toggle("Signal prompt (zsh)", isOn: settings.signalPrompt)
                        .help("Sigpane draws its own prompt in new zsh sessions, in place of a prompt theme such as Starship.")
                    if store.settings.signalPrompt {
                        Picker("Prompt style", selection: settings.promptStyle) {
                            ForEach(TabBarSettings.PromptStyle.allCases) { style in
                                Text(style.title).tag(style)
                            }
                        }
                        .help("How the line you type on looks. Open shells switch at their next prompt.")
                    }
                    Toggle("Command blocks", isOn: settings.commandBlocks)
                        .help("Draws a box around each command and its output, with buttons to copy the output and to fold or open it. Needs shell integration.")
                    Toggle("Fold long output for me", isOn: settings.autoFold)
                        .help("Off: output stays on screen until you fold it yourself with a block's button. On: when you run a command, the one before it folds into its command line if its output was longer than the limit. The line you are typing on never moves (the space is filled by lines coming back from the scrollback), so nothing is folded until the scrollback holds that many lines. The output of a command that failed is left open.")
                        .disabled(!store.settings.commandBlocks)
                    if store.settings.autoFold && store.settings.commandBlocks {
                        slider("Fold after lines", value: settings.autoFoldLines, in: TabBarSettings.foldRange, step: 1)
                        Toggle("Fold the newest output too", isOn: settings.foldNewest)
                            .help("Fold long output as soon as its command finishes, without waiting for the next command.")
                    }
                    Toggle("\u{2303}F folds or opens every block", isOn: settings.foldAllKey)
                        .help("Control-F at a prompt folds every command's output, or opens every fold when there is nothing left to fold. While a program is running the key goes to it as usual (it pages forward in vim and less).")
                        .disabled(!store.settings.commandBlocks)
                    Toggle("\u{21E7}\u{2191} \u{21E7}\u{2193} pick a block, \u{2303}C copies it", isOn: settings.blockKeys)
                        .help("At a prompt, Shift with the up and down arrows moves from one finished command to the next, and Control-C copies the picked one's output (its command if it printed nothing). Escape or any other key lets go of it. With nothing picked, Control-C is the usual interrupt.")
                        .disabled(!store.settings.commandBlocks)
                    Toggle("\u{2303}S shows or hides the sidebar", isOn: settings.sidebarKey)
                        .help("Control-S shrinks the sidebar to its tiles and brings it back. Only with the tab bar at the left or right, and not while an editor or a pager has the screen: there the key goes to it.")
                }
            }
            Section("Layout") {
                Picker("Position", selection: settings.position) {
                    ForEach(TabBarSettings.Position.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.settings.position.isVertical {
                    slider("Sidebar width", value: settings.sidebarWidth, in: TabBarSettings.sidebarWidthRange, step: 10)
                } else {
                    Picker("Alignment", selection: settings.alignment) {
                        ForEach(TabBarSettings.Alignment.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Picker("Tab width", selection: settings.width) {
                        ForEach(TabBarSettings.Width.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
                if store.settings.position != .top {
                    Toggle("Show with one tab", isOn: settings.showWithSingleTab)
                }
            }
            if store.settings.usesSessionCards {
                // Signal sidebars draw fixed session cards, so capsule shape controls do not apply.
                Section("Session cards") {
                    slider("Spacing", value: settings.spacing, in: TabBarSettings.spacingRange, step: 1)
                    Picker("Close button", selection: settings.closeButton) {
                        ForEach(TabBarSettings.CloseButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    Toggle("Collapsed to tiles", isOn: settings.sidebarCollapsed)
                    Toggle("Directory line", isOn: settings.showSubtitle)
                    Toggle("Shortcut hints", isOn: settings.showShortcutHints)
                    Toggle("System load", isOn: settings.systemLoad)
                }
            } else {
                Section(store.settings.isSignal ? "Chips" : "Capsules") {
                    // Signal chips have one shape; style and roundness belong to Classic capsules.
                    if !store.settings.isSignal {
                        Picker("Style", selection: settings.style) {
                            ForEach(TabBarSettings.Style.allCases) { Text($0.title).tag($0) }
                        }
                        .pickerStyle(.segmented)
                    }
                    slider("Height", value: settings.tabHeight, in: TabBarSettings.heightRange, step: 1)
                    slider("Spacing", value: settings.spacing, in: TabBarSettings.spacingRange, step: 1)
                    if !store.settings.isSignal {
                        slider("Roundness", value: settings.roundness, in: 0...1, step: 0.05, percent: true)
                    }
                    Picker("Close button", selection: settings.closeButton) {
                        ForEach(TabBarSettings.CloseButton.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            if store.settings.isSignal {
                Section("Panes") {
                    Toggle("Pane headers", isOn: settings.paneHeaders)
                    Toggle("Focus corners", isOn: settings.focusCorners)
                    Toggle("Focus glow", isOn: settings.focusGlow)
                    slider("Gap", value: settings.paneGutter, in: TabBarSettings.gutterRange, step: 1)
                    slider("Corner radius", value: settings.paneRadius, in: TabBarSettings.paneRadiusRange, step: 1)
                }
                Section("Window") {
                    Toggle("Trace from tab to focused pane", isOn: settings.signalTrace)
                    Toggle("Status line", isOn: settings.statusBar)
                    Toggle("Key hints in the status line", isOn: settings.statusHints)
                        .help("Shows the keys worth remembering in the free middle of the status line: new tab, split, picking and folding blocks, the sidebar. The terminal's keys are read from your configuration, so a key you rebound shows as you bound it. As many are shown as fit.")
                        .disabled(!store.settings.statusBar)
                    Toggle("Titlebar split and command buttons", isOn: settings.titlebarActions)
                }
            }
            Section("Colors") {
                Picker("Tab colors", selection: settings.tabColors) {
                    ForEach(TabBarSettings.TabColors.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                Picker("Shown as", selection: settings.colorStyle) {
                    ForEach(TabBarSettings.ColorStyle.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                if store.settings.tabColors == .random {
                    Button("Shuffle colors") {
                        model.shuffleColors()
                        RoundedTerminalTabModel.shuffleAllColors()
                    }
                }
            }
            Section("Details") {
                Toggle("Tab numbers", isOn: settings.showNumbers)
                if store.settings.position != .top {
                    Toggle("Bar background", isOn: settings.showBackground)
                }
                LabeledContent("Accent") {
                    HStack(spacing: 8) {
                        ForEach(TabBarSettings.Accent.allCases) { accent in
                            swatch(accent)
                        }
                    }
                }
            }
            Section {
                Button("Restore defaults") { store.reset() }
            }
        }
        .formStyle(.grouped)
    }

    private func slider(_ title: String, value: Binding<Double>, in range: ClosedRange<Double>,
                        step: Double, percent: Bool = false) -> some View {
        LabeledContent(title) {
            HStack(spacing: 8) {
                // Round in the binding rather than `step:`, which draws tick marks.
                Slider(value: Binding(
                    get: { value.wrappedValue },
                    set: { value.wrappedValue = ($0 / step).rounded() * step }
                ), in: range)
                Text(percent ? "\(Int((value.wrappedValue * 100).rounded()))%" : "\(Int(value.wrappedValue.rounded()))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .frame(width: 36, alignment: .trailing)
            }
        }
    }

    private func swatch(_ accent: TabBarSettings.Accent) -> some View {
        let selected = store.settings.accent == accent
        return Button {
            store.settings.accent = accent
        } label: {
            Circle()
                .fill(Color(nsColor: theme.accent(accent)))
                .frame(width: 18, height: 18)
                .overlay(Circle().strokeBorder(Color.primary, lineWidth: selected ? 2 : 0).padding(-3))
        }
        .buttonStyle(.plain)
        .help(accent.title)
        .accessibilityLabel("\(accent.title) accent")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }
}

/// A mock terminal window using the real tab strip component.
struct TabBarPreview: View {
    @ObservedObject var store: TabBarSettingsStore
    @ObservedObject var model: PreviewTabModel
    let theme: RoundedTabTheme

    private var s: TabBarSettings { store.settings }

    var body: some View {
        VStack(spacing: 0) {
            titlebar
            content
        }
        .background(Color(nsColor: theme.background))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
            .strokeBorder(Color(nsColor: theme.foreground).opacity(0.12), lineWidth: 1))
        .shadow(color: .black.opacity(0.3), radius: 16, y: 8)
        .environment(\.colorScheme, .dark)
    }

    private var titlebar: some View {
        HStack(spacing: 8) {
            ForEach([Color(red: 1, green: 0.37, blue: 0.34), Color(red: 1, green: 0.74, blue: 0.18),
                     Color(red: 0.16, green: 0.78, blue: 0.25)], id: \.self) { color in
                Circle().fill(color).frame(width: 12, height: 12)
            }
            if s.position == .top {
                PreviewStrip(model: model, store: store)
                    .padding(.leading, 18)
            } else {
                Text(model.selectedTitle)
                    .font(.system(size: 12, weight: .medium))
                    .foregroundStyle(Color(nsColor: theme.foreground).opacity(0.55))
                    .frame(maxWidth: .infinity)
                    .padding(.trailing, 56)
            }
        }
        .padding(.leading, 14)
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            if s.position != .top {
                Rectangle().fill(Color(nsColor: theme.foreground).opacity(0.06)).frame(height: 1)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch s.position {
        case .top:
            terminal
        case .bottom:
            VStack(spacing: 0) {
                terminal
                PreviewStrip(model: model, store: store).frame(height: s.edgeThickness)
            }
        case .left:
            HStack(spacing: 0) {
                PreviewStrip(model: model, store: store).frame(width: s.edgeThickness)
                terminal
            }
        case .right:
            HStack(spacing: 0) {
                terminal
                PreviewStrip(model: model, store: store).frame(width: s.edgeThickness)
            }
        }
    }

    private var terminal: some View {
        let fg = Color(nsColor: theme.foreground)
        let blue = Color(nsColor: theme.accent(.blue))
        let green = Color(nsColor: theme.accent(.green))
        let dim = fg.opacity(0.45)
        let title = model.selectedTitle
        return VStack(alignment: .leading, spacing: 4) {
            (Text("~/work/").foregroundColor(dim) + Text(title).foregroundColor(blue)
                + Text(" on ").foregroundColor(dim) + Text("main").foregroundColor(green))
            (Text("❯ ").foregroundColor(blue) + Text("git status").foregroundColor(fg))
            Text("On branch main").foregroundColor(fg.opacity(0.8))
            Text("nothing to commit, working tree clean").foregroundColor(fg.opacity(0.8))
            Text(" ")
            (Text("❯ ").foregroundColor(blue) + Text("█").foregroundColor(fg.opacity(0.7)))
        }
        .font(.system(size: 12, design: .monospaced))
        .lineLimit(1)
        .padding(18)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .frame(minHeight: 300)
        .overlay {
            // Signal windows frame every pane in the selected tab's color.
            if s.isSignal {
                RoundedRectangle(cornerRadius: s.paneCornerRadius, style: .continuous)
                    .strokeBorder(blue.opacity(0.42), lineWidth: 1)
            }
        }
        .padding(s.isSignal ? s.gutter : 0)
    }
}

/// The real AppKit strip, driven by the preview's sample tabs.
private struct PreviewStrip: NSViewRepresentable {
    let model: PreviewTabModel
    let store: TabBarSettingsStore

    func makeNSView(context: Context) -> RoundedTerminalTabBar {
        RoundedTerminalTabBar(model: model, placement: .preview, store: store)
    }

    func updateNSView(_ nsView: RoundedTerminalTabBar, context: Context) {
        nsView.needsLayout = true
    }
}
