import AppKit
import Combine

enum AgentActivity {
    enum Provider: String, CaseIterable, Identifiable {
        case claude, codex

        var id: Self { self }
        var name: String { self == .claude ? "Claude Code" : "Codex" }
        var shortName: String { self == .claude ? "Claude" : "Codex" }
        var glyph: String { self == .claude ? "✦" : "‹/›" }
    }

    /// Most urgent first: `Summary.primary` is the first of these any session is in.
    enum Phase: String, Codable, CaseIterable {
        case approval, error, running, compacting, complete, ready

        var label: String {
            switch self {
            case .approval: "Needs approval"
            case .error: "Stopped on error"
            case .running: "Running"
            case .compacting: "Compacting"
            case .complete: "Done"
            case .ready: "Ready"
            }
        }

        /// The state as one character, so it never depends on color alone.
        var glyph: String {
            switch self {
            case .approval: "!"
            case .error: "×"
            case .running: "▸"
            case .compacting: "⟳"
            case .complete: "✓"
            case .ready: "·"
            }
        }

        var shortLabel: String {
            switch self {
            case .approval: "waiting"
            case .error: "stopped"
            case .running, .compacting: "running"
            case .complete: "done"
            case .ready: "ready"
            }
        }

        var color: NSColor {
            switch self {
            case .approval: NSColor(srgbRed: 1, green: 0.76, blue: 0.36, alpha: 1)
            case .error: NSColor(srgbRed: 1, green: 0.44, blue: 0.57, alpha: 1)
            case .running: NSColor(srgbRed: 0.34, green: 0.83, blue: 0.98, alpha: 1)
            case .compacting: NSColor(srgbRed: 0.62, green: 0.55, blue: 1, alpha: 1)
            case .complete: NSColor(srgbRed: 0.43, green: 0.88, blue: 0.64, alpha: 1)
            case .ready: .secondaryLabelColor
            }
        }

        /// Whether a turn is in progress, so its time is worth counting.
        var isWorking: Bool { self == .running || self == .compacting || self == .approval }
    }

    struct Subagent: Equatable, Identifiable {
        let id: String
        var type: String
        var done = false
        /// What it is doing, when the hook said.
        var tool: String?
    }

    struct Session: Identifiable, Equatable {
        var id: Provider { provider }
        let provider: Provider
        var phase: Phase
        /// The tool in use and a word about its target ("Edit", "TabBar.swift").
        var tool: String?
        var target: String?
        var turnStarted: Date?
        var model: String?
        var mode: String?
        var subagents: [Subagent] = []
        var tasksDone = 0
        var tasksTotal = 0
        /// Share of the context window in use, 0 to 100. Only known once the status
        /// line has been wrapped (Settings ▸ Agent Activity).
        var context: Int?
        var tokens: Int?
        var cost: Double?
        var linesAdded: Int?
        var linesRemoved: Int?
        /// How many different files the session has changed.
        var filesEdited = 0

        /// What the session is doing, in a few words: the tool and its target while it
        /// works or waits on one, else the state's name.
        var activity: String {
            guard phase == .running || phase == .approval, let tool else { return phase.label }
            return target.map { "\(tool) \($0)" } ?? tool
        }

        var runningSubagents: Int { subagents.count { !$0.done } }

        /// The permission mode in words, once an event has said what it is.
        var modeLabel: String? {
            switch mode {
            case "acceptEdits": "accept edits"
            case "bypassPermissions": "bypass permissions"
            case "plan": "plan mode"
            case "dontAsk": "don't ask"
            default: mode
            }
        }

        /// Modes in which the agent changes things without asking: shown in a warmer color.
        var modeIsPermissive: Bool {
            mode == "acceptEdits" || mode == "bypassPermissions" || mode == "auto" || mode == "dontAsk"
        }

        /// What the session has changed: "3 files", then lines added and removed.
        var filesLabel: String? {
            filesEdited > 0 ? "\(filesEdited) \(filesEdited == 1 ? "file" : "files")" : nil
        }

        var tokensLabel: String? {
            guard let tokens else { return nil }
            return tokens >= 1000 ? "\(tokens / 1000)k" : "\(tokens)"
        }

        /// How long the turn has been going: "0:48", "12:05", "1:04:10".
        func elapsed(at now: Date = Date()) -> String? {
            guard phase.isWorking, let turnStarted else { return nil }
            let seconds = max(0, Int(now.timeIntervalSince(turnStarted)))
            return seconds >= 3600
                ? String(format: "%d:%02d:%02d", seconds / 3600, seconds / 60 % 60, seconds % 60)
                : String(format: "%d:%02d", seconds / 60, seconds % 60)
        }

        /// The color the context meter takes: a warning from 75%, an alarm from 90%.
        static func contextColor(_ percent: Int) -> NSColor? {
            if percent >= 90 { return Phase.error.color }
            if percent >= 75 { return Phase.approval.color }
            return nil
        }
    }

    struct Summary: Equatable {
        var sessions: [Session] = []

        var primary: Phase? {
            Phase.allCases.first { phase in sessions.contains { $0.phase == phase } }
        }

        /// The session that speaks for a tab or pane: the most urgent one.
        var lead: Session? {
            guard let primary else { return nil }
            return sessions.first { $0.phase == primary }
        }

        var visibleCounts: [(phase: Phase, count: Int)] {
            let phases = primary == .ready ? [.ready] : [Phase.approval, .error, .running, .compacting, .complete]
            return phases.compactMap { phase in
                let count = sessions.count { $0.phase == phase }
                return count == 0 ? nil : (phase, count)
            }
        }

        /// "1 waiting · 2 running · 1 done"
        var sentence: String {
            var counts: [(String, Int)] = []
            for (phase, count) in visibleCounts {
                if let index = counts.firstIndex(where: { $0.0 == phase.shortLabel }) {
                    counts[index].1 += count
                } else {
                    counts.append((phase.shortLabel, count))
                }
            }
            return counts.map { "\($0.1) \($0.0)" }.joined(separator: " · ")
        }

        var description: String {
            sessions.map { "\($0.provider.name) · \($0.activity)" }.joined(separator: ", ")
        }
    }
}

/// One tick a second for the turn times on screen, and only while something shows one.
/// A view takes a token while it is drawing a running turn's time and drops it when it
/// stops; with no tokens there is no timer.
@MainActor
final class AgentClock {
    static let shared = AgentClock()
    nonisolated static let didTick = Notification.Name("GhosttyXAgentClockDidTick")

    private var timer: Timer?
    private var holders = 0

    final class Token {
        fileprivate init() {}
        deinit { DispatchQueue.main.async { MainActor.assumeIsolated { AgentClock.shared.release() } } }
    }

    func hold() -> Token {
        holders += 1
        if timer == nil {
            let timer = Timer(timeInterval: 1, repeats: true) { _ in
                NotificationCenter.default.post(name: Self.didTick, object: nil)
            }
            timer.tolerance = 0.25
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
        return Token()
    }

    private func release() {
        holders -= 1
        guard holders <= 0 else { return }
        holders = 0
        timer?.invalidate()
        timer = nil
    }
}

/// Each terminal surface gives its local child process a private directory. CLI hooks
/// publish small, atomic status updates there, even when the pane is in a hidden tab.
@MainActor
final class AgentActivityChannel: ObservableObject {
    static let didChange = Notification.Name("GhosttyXAgentActivityDidChange")
    static let environmentKey = "GHOSTTY_AGENT_ACTIVITY_DIR"
    /// Set to "0" in a pane's environment when the hooks should report the state alone.
    static let detailsKey = "GHOSTTY_AGENT_ACTIVITY_DETAILS"

    @Published private(set) var summary = AgentActivity.Summary()
    let directory: URL?
    private let watcher: DispatchSourceFileSystemObject?

    /// Status folders are named for the process that made them, so a later launch can
    /// tell which ones were left behind.
    private static let folderPrefix = "ghostty-agent-p"

    /// Removes the folders of copies of the app that are no longer running. A pane removes
    /// its own folder when it closes, but quitting ends the process before the open panes
    /// are let go, so theirs were left in the temporary directory every time. Done once,
    /// off the main thread, the first time a pane is made.
    private static let sweepStaleFolders: Void = {
        let root = FileManager.default.temporaryDirectory
        DispatchQueue.global(qos: .utility).async {
            let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []
            for name in names where name.hasPrefix(folderPrefix) {
                let owner = name.dropFirst(folderPrefix.count).prefix { $0.isNumber }
                // Signal 0 only asks whether the process exists.
                guard let pid = pid_t(owner), pid > 0, kill(pid, 0) != 0, errno == ESRCH else { continue }
                try? FileManager.default.removeItem(at: root.appendingPathComponent(name, isDirectory: true))
            }
        }
    }()

    init() {
        _ = Self.sweepStaleFolders
        let candidate = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "\(Self.folderPrefix)\(ProcessInfo.processInfo.processIdentifier)-\(UUID().uuidString)",
                isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: candidate, withIntermediateDirectories: false,
                                                    attributes: [.posixPermissions: 0o700])
        } catch {
            directory = nil
            watcher = nil
            return
        }
        let fd = open(candidate.path, O_EVTONLY | O_CLOEXEC)
        guard fd >= 0 else {
            try? FileManager.default.removeItem(at: candidate)
            directory = nil
            watcher = nil
            return
        }

        directory = candidate
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: .write, queue: .main)
        watcher = source
        source.setEventHandler { [weak self] in self?.refresh() }
        source.setCancelHandler { close(fd) }
        source.resume()
    }

    deinit {
        if let keyObserver { NotificationCenter.default.removeObserver(keyObserver) }
        watcher?.cancel()
        if let directory {
            try? FileManager.default.removeItem(at: directory)
        }
    }

    func clear() {
        guard let directory else { return }
        for provider in AgentActivity.Provider.allCases {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(provider.rawValue + ".json"))
        }
        refresh()
    }

    /// The pane's view, so the channel can tell when the pane is being looked at.
    weak var view: NSView?
    /// Whether this is the pane its window has focus in.
    var isFocused = false { didSet { if isFocused != oldValue { settle() } } }
    /// Finished turns that have been seen: their session and when they ended. A turn that
    /// finishes is "done" until its pane is looked at, and "ready" from then on.
    private var seen: [AgentActivity.Provider: String] = [:]
    private var raw: [AgentActivity.Provider: (session: AgentActivity.Session, turn: String)] = [:]
    private var keyObserver: NSObjectProtocol?

    private var isWatched: Bool {
        guard isFocused, let window = view?.window else { return false }
        return window.isKeyWindow && window.occlusionState.contains(.visible)
    }

    private struct Event: Decodable {
        struct Agent: Decodable {
            let id: String
            let type: String?
            let done: Bool?
            let tool: String?
        }
        struct Usage: Decodable {
            let context: Double?
            let tokens: Int?
            let cost: Double?
            let added: Int?
            let removed: Int?
        }
        let session: String?
        let phase: AgentActivity.Phase
        let tool: String?
        let target: String?
        let started: Double?
        let model: String?
        let mode: String?
        let agents: [Agent]?
        let tasks: [String: Bool]?
        let edited: [String]?
        let usage: Usage?
    }

    private func refresh() {
        guard let directory else { return }
        raw = [:]
        for provider in AgentActivity.Provider.allCases {
            let url = directory.appendingPathComponent(provider.rawValue + ".json")
            guard let data = try? Data(contentsOf: url),
                  let event = try? JSONDecoder().decode(Event.self, from: data) else { continue }
            var session = AgentActivity.Session(provider: provider, phase: event.phase)
            session.tool = event.tool
            session.target = event.target
            session.turnStarted = event.started.map(Date.init(timeIntervalSince1970:))
            session.model = event.model
            session.mode = event.mode
            session.subagents = (event.agents ?? []).map {
                .init(id: $0.id, type: $0.type ?? "agent", done: $0.done ?? false, tool: $0.tool)
            }
            session.tasksTotal = event.tasks?.count ?? 0
            session.tasksDone = event.tasks?.values.count { $0 } ?? 0
            session.context = event.usage?.context.map { min(100, max(0, Int($0.rounded()))) }
            session.tokens = event.usage?.tokens
            session.cost = event.usage?.cost
            session.linesAdded = event.usage?.added
            session.linesRemoved = event.usage?.removed
            session.filesEdited = event.edited?.count ?? 0
            // Usage only moves when a turn does, so it tells one finished turn from the next.
            let turn = "\(event.session ?? "")/\(event.usage?.tokens ?? 0)/\(event.usage?.cost ?? 0)"
            raw[provider] = (session, turn)
        }
        if keyObserver == nil, !raw.isEmpty {
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main
            ) { [weak self] note in
                MainActor.assumeIsolated {
                    guard let self, (note.object as? NSWindow) === self.view?.window else { return }
                    self.settle()
                }
            }
        }
        settle()
    }

    /// Publishes the sessions, with a finished turn shown as ready once it has been seen.
    private func settle() {
        let watched = isWatched
        var sessions: [AgentActivity.Session] = []
        for provider in AgentActivity.Provider.allCases {
            guard let entry = raw[provider] else {
                seen[provider] = nil
                continue
            }
            var session = entry.session
            let turn = entry.turn
            if session.phase == .complete {
                if watched { seen[provider] = turn }
                if seen[provider] == turn { session.phase = .ready }
            } else {
                seen[provider] = nil
            }
            sessions.append(session)
        }
        let next = AgentActivity.Summary(sessions: sessions)
        guard next != summary else { return }
        summary = next
        NotificationCenter.default.post(name: Self.didChange, object: self)
    }
}
