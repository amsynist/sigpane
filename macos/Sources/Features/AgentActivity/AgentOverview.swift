import AppKit
import Combine
import SwiftUI

/// Every agent session in every tab and window, in one panel (Command-Shift-A). The arrow
/// keys pick one, Return goes to its pane, Escape closes.
@MainActor
final class AgentOverviewController: NSObject, NSWindowDelegate, NSMenuItemValidation {
    static let shared = AgentOverviewController()

    /// One agent session and the pane it runs in.
    struct Entry: Identifiable {
        let id: String
        let number: Int
        let title: String
        let color: NSColor
        let session: AgentActivity.Session
        weak var surface: Ghostty.SurfaceView?
        weak var window: NSWindow?
    }

    final class Model: ObservableObject {
        @Published var entries: [Entry] = []
        @Published var selection = 0
        /// Bumped each second while the panel is open, so turn times count up.
        @Published var tick = 0
    }

    private let model = Model()
    private var panel: Panel?
    private var observers: [NSObjectProtocol] = []
    private var clockHold: AgentClock.Token?

    /// Sessions in tab order, window by window.
    static func entries() -> [Entry] {
        let settings = TabBarSettingsStore.shared.settings
        let theme = RoundedTabTheme.current
        var seen = Set<ObjectIdentifier>()
        var result: [Entry] = []
        for window in NSApp.windows.compactMap({ $0 as? TerminalWindow }) {
            let tabs = window.tabGroup?.windows ?? [window]
            guard let first = tabs.first, seen.insert(ObjectIdentifier(first)).inserted else { continue }
            for (index, tab) in tabs.enumerated() {
                guard let controller = tab.windowController as? BaseTerminalController else { continue }
                let clean = SignalText.chromeSafe(tab.title)
                let directory = RoundedTerminalTabModel.directory(of: tab)
                let title = RoundedTerminalTabModel.shortTitle(clean, directory: directory)
                    ?? (clean.isEmpty ? "Terminal" : clean)
                for surface in controller.surfaceTree {
                    for session in surface.agentActivity.summary.sessions {
                        result.append(Entry(
                            id: "\(ObjectIdentifier(surface).hashValue)-\(session.provider.rawValue)",
                            number: index, title: title,
                            color: theme.signal(for: tab, settings: settings),
                            session: session, surface: surface, window: tab))
                    }
                }
            }
        }
        return result
    }

    /// Brings a session's tab forward and gives its pane the keyboard.
    static func go(to entry: Entry) {
        guard let window = entry.window else { return }
        window.tabGroup?.selectedWindow = window
        window.makeKeyAndOrderFront(nil)
        if let surface = entry.surface { Ghostty.moveFocus(to: surface) }
    }

    // MARK: Menu actions

    @objc func toggle(_ sender: Any?) {
        if panel?.isVisible == true { close() } else { show() }
    }

    /// Goes to the next session that is waiting for an answer, after the pane in use.
    @objc func nextApproval(_ sender: Any?) {
        let all = Self.entries()
        let waiting = all.indices.filter { all[$0].session.phase == .approval }
        guard !waiting.isEmpty else { return }
        let key = NSApp.keyWindow
        let focused = (key?.windowController as? BaseTerminalController)?.focusedSurface
        let here = all.firstIndex { $0.surface === focused } ?? -1
        Self.go(to: all[waiting.first { $0 > here } ?? waiting[0]])
    }

    func validateMenuItem(_ menuItem: NSMenuItem) -> Bool {
        // While nothing is waiting the key goes to the terminal as always.
        if menuItem.action == #selector(nextApproval(_:)) {
            return Self.entries().contains { $0.session.phase == .approval }
        }
        return true
    }

    // MARK: Panel

    private final class Panel: NSPanel {
        var onKey: ((UInt16) -> Bool)?
        override var canBecomeKey: Bool { true }
        override func keyDown(with event: NSEvent) {
            if onKey?(event.keyCode) != true { super.keyDown(with: event) }
        }
        override func cancelOperation(_ sender: Any?) { close() }
    }

    private func show() {
        model.entries = Self.entries()
        model.selection = model.entries.firstIndex { $0.session.phase == .approval } ?? 0

        let panel = Panel(
            contentRect: NSRect(x: 0, y: 0, width: 540, height: 320),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered, defer: true)
        panel.isMovableByWindowBackground = true
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = true
        panel.isReleasedWhenClosed = false
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.delegate = self
        panel.setAccessibilityLabel("Agents")
        let theme = RoundedTabTheme.current
        let host = NSHostingView(rootView: AgentOverviewView(
            model: model, foreground: Color(nsColor: theme.foreground),
            background: Color(nsColor: theme.background)
        ) { [weak self] entry in
            self?.close()
            Self.go(to: entry)
        })
        panel.contentView = host
        panel.setContentSize(host.fittingSize)
        panel.onKey = { [weak self] code in self?.handle(key: code) ?? false }
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            let frame = parent.frame
            panel.setFrameOrigin(NSPoint(
                x: (frame.midX - panel.frame.width / 2).rounded(),
                y: (frame.maxY - panel.frame.height - min(120, frame.height * 0.18)).rounded()))
        } else {
            panel.center()
        }
        self.panel = panel

        let center = NotificationCenter.default
        observers = [
            center.addObserver(forName: AgentActivityChannel.didChange, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            },
            center.addObserver(forName: AgentClock.didTick, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.model.tick += 1 }
            },
        ]
        clockHold = AgentClock.shared.hold()
        panel.makeKeyAndOrderFront(nil)
    }

    private func reload() {
        model.entries = Self.entries()
        model.selection = min(model.selection, max(0, model.entries.count - 1))
        if let panel, let host = panel.contentView {
            // Keep the top edge where it is while the list grows or shrinks.
            let top = panel.frame.maxY
            panel.setContentSize(host.fittingSize)
            panel.setFrameTopLeftPoint(NSPoint(x: panel.frame.minX, y: top))
        }
    }

    private func handle(key code: UInt16) -> Bool {
        let count = model.entries.count
        switch code {
        case 125 where count > 0: model.selection = (model.selection + 1) % count
        case 126 where count > 0: model.selection = (model.selection + count - 1) % count
        case 36, 76:
            guard model.entries.indices.contains(model.selection) else { return true }
            let entry = model.entries[model.selection]
            close()
            Self.go(to: entry)
        case 53: close()
        default: return false
        }
        return true
    }

    private func close() {
        panel?.close()
    }

    func windowDidResignKey(_ notification: Notification) {
        close()
    }

    func windowWillClose(_ notification: Notification) {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        clockHold = nil
        model.entries = []
        panel = nil
    }
}

private struct AgentOverviewView: View {
    @ObservedObject var model: AgentOverviewController.Model
    let foreground: Color
    let background: Color
    let open: (AgentOverviewController.Entry) -> Void

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(verbatim: "AGENTS · \(model.entries.count)")
                    .kerning(1.6)
                Spacer()
                Text(verbatim: "↑↓  ⏎  esc")
            }
            .font(.system(size: 10, weight: .medium, design: .monospaced))
            .foregroundColor(foreground.opacity(0.34))
            .padding(.horizontal, 14)
            .padding(.vertical, 11)
            Rectangle().fill(foreground.opacity(0.09)).frame(height: 1)
            if model.entries.isEmpty {
                Text("No agent sessions. Start one with claude or codex in any pane.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundColor(foreground.opacity(0.45))
                    .padding(18)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(Array(model.entries.enumerated()), id: \.element.id) { index, entry in
                            row(entry, selected: index == model.selection)
                                .contentShape(Rectangle())
                                .onTapGesture { open(entry) }
                            if index < model.entries.count - 1 {
                                Rectangle().fill(foreground.opacity(0.06)).frame(height: 1)
                            }
                        }
                    }
                }
                .frame(maxHeight: 420)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(width: 540)
        .background(background.opacity(0.97))
        .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(foreground.opacity(0.14), lineWidth: 1))
    }

    private func row(_ entry: AgentOverviewController.Entry, selected: Bool) -> some View {
        let session = entry.session
        let phase = session.phase
        let tint = Color(nsColor: entry.color)
        let state = phase == .ready ? foreground.opacity(0.45) : Color(nsColor: phase.color)
        // Reading the tick makes the row count the turn's time up each second.
        let elapsed = model.tick >= 0 ? session.elapsed() : nil
        let running = session.subagents.filter { !$0.done }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 11) {
                ZStack {
                    if let percent = session.context {
                        ContextFrame(radius: 10)
                            .stroke(foreground.opacity(0.1), lineWidth: 1.5)
                        ContextFrame(radius: 10)
                            .trim(from: 0, to: CGFloat(percent) / 100)
                            .stroke(AgentActivity.Session.contextColor(percent).map { Color(nsColor: $0) } ?? tint,
                                    style: StrokeStyle(lineWidth: 1.8, lineCap: .round))
                    }
                    Text(verbatim: SignalText.ordinal(entry.number))
                        .font(.system(size: 10.5, weight: .bold, design: .monospaced))
                        .foregroundColor(tint)
                        .frame(width: 26, height: 26)
                        .background(tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                }
                .frame(width: 34, height: 34)
                VStack(alignment: .leading, spacing: 4) {
                    Text(verbatim: entry.title)
                        .font(.system(size: 12.5, weight: .semibold, design: .monospaced))
                        .foregroundColor(foreground)
                        .lineLimit(1)
                    HStack(spacing: 6) {
                        Text(verbatim: phase.glyph).fontWeight(.bold).foregroundColor(state)
                        Text(verbatim: session.activity)
                            .foregroundColor(phase == .approval ? state : foreground.opacity(0.55))
                            .lineLimit(1)
                        if let elapsed {
                            Text(verbatim: elapsed).foregroundColor(foreground.opacity(0.34))
                        }
                    }
                    .font(.system(size: 10.5, design: .monospaced))
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 4) {
                    Text(verbatim: [session.provider.shortName, session.model].compactMap { $0 }.joined(separator: " · "))
                    Text(verbatim: usage(session))
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(foreground.opacity(0.4))
                .lineLimit(1)
                .fixedSize()
            }
            if !session.subagents.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(running.prefix(6)) { agent in
                        HStack(spacing: 8) {
                            Text(verbatim: "▸").foregroundColor(Color(nsColor: AgentActivity.Phase.running.color))
                            Text(verbatim: agent.type).foregroundColor(foreground.opacity(0.6))
                            Text(verbatim: agent.tool ?? "")
                        }
                    }
                    let finished = session.subagents.count - running.count
                    let hidden = max(0, running.count - 6)
                    if finished + hidden > 0 {
                        Text(verbatim: [hidden > 0 ? "\(hidden) more running" : nil,
                                        finished > 0 ? "✓ \(finished) finished" : nil]
                            .compactMap { $0 }.joined(separator: " · "))
                    }
                }
                .font(.system(size: 10.5, design: .monospaced))
                .foregroundColor(foreground.opacity(0.34))
                .lineLimit(1)
                .padding(.leading, 45)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? tint.opacity(0.1) : Color.clear)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    private func usage(_ session: AgentActivity.Session) -> String {
        var parts: [String] = []
        if let percent = session.context { parts.append("\(percent)%") }
        if let tokens = session.tokensLabel { parts.append(tokens) }
        if let cost = session.cost { parts.append(String(format: "$%.2f", cost)) }
        return parts.isEmpty ? "context n/a" : parts.joined(separator: " · ")
    }
}

/// The outline around a session's tile, drawn from its top left corner clockwise, so a
/// trimmed stroke fills the way the sidebar's context frame does.
private struct ContextFrame: Shape {
    var radius: CGFloat

    func path(in rect: CGRect) -> Path {
        let rect = rect.insetBy(dx: 1, dy: 1)
        let radius = min(radius, rect.width / 2, rect.height / 2)
        var path = Path()
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
        return path
    }
}
