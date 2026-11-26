import SwiftUI

struct AgentActivitySettings: View {
    @Binding var groupSessions: Bool
    @Binding var showApprovalShortcut: Bool
    @Binding var toolDetails: Bool
    @State private var enabled: [AgentActivity.Provider: Bool] = [:]
    /// Whether Claude Code's status line is wrapped, which is where context and cost come from.
    @State private var usage: Bool?
    @State private var working = false
    @State private var failure: String?

    var body: some View {
        Section("Agent Activity") {
            Toggle("Group sidebar sessions by agent", isOn: $groupSessions)
            Toggle("Show Next Approval in the sidebar", isOn: $showApprovalShortcut)
            ForEach(AgentActivity.Provider.allCases) { provider in
                LabeledContent(provider.name) {
                    if let isEnabled = enabled[provider] {
                        Button(isEnabled ? "Disable" : "Enable") {
                            Task { await refresh(changing: provider) }
                        }
                        .accessibilityLabel("\(isEnabled ? "Disable" : "Enable") \(provider.name) activity")
                    } else if working {
                        ProgressView().controlSize(.small)
                    }
                }
                .disabled(working)
            }
            LabeledContent("Context and cost") {
                if let usage {
                    Button(usage ? "Disable" : "Enable") {
                        Task { await refresh(usage: usage ? "usage-disable" : "usage-enable") }
                    }
                    .accessibilityLabel("\(usage ? "Disable" : "Enable") context and cost")
                } else if working {
                    ProgressView().controlSize(.small)
                }
            }
            .disabled(working)
            .help("Claude Code gives these numbers only to its status line command. Sigpane records them and then runs the status line you already had.")
            Toggle("Show the tool and file an agent is using", isOn: $toolDetails)
                .help("A file's name or a command's first word, never a path, a full command or a prompt. Applies to panes opened from now on.")
            Text("Start a new CLI session after enabling, and enable again after updating Sigpane: new versions follow more events. For Codex, review and trust the hooks in /hooks.")
                .font(.caption)
                .foregroundStyle(.secondary)
            if let failure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                Button("Check Again") { Task { await refresh() } }
                    .disabled(working)
            }
        }
        .task { await refresh() }
    }

    @MainActor
    private func refresh(changing provider: AgentActivity.Provider? = nil, usage change: String? = nil) async {
        guard !working else { return }
        working = true
        failure = nil
        defer { working = false }

        let action = provider.map { enabled[$0] == true ? "disable" : "enable" }
        do {
            let result: ([AgentActivity.Provider: Bool], Bool) = try await Task.detached(priority: .userInitiated) {
                if let provider, let action {
                    _ = try AgentActivityHookSetup.run(action, provider: provider)
                }
                if let change {
                    _ = try AgentActivityHookSetup.run(change, provider: .claude)
                }
                var result: [AgentActivity.Provider: Bool] = [:]
                for provider in AgentActivity.Provider.allCases {
                    result[provider] = try AgentActivityHookSetup.run("status", provider: provider) == "enabled"
                }
                return (result, try AgentActivityHookSetup.run("usage-status", provider: .claude) == "enabled")
            }.value
            enabled = result.0
            usage = result.1
        } catch {
            failure = error.localizedDescription
        }
    }
}

private enum AgentActivityHookSetup {
    struct Failure: LocalizedError {
        var errorDescription: String?
    }

    static func run(_ action: String, provider: AgentActivity.Provider) throws -> String {
        guard let script = Bundle.main.url(forResource: "agent-activity", withExtension: "py") else {
            throw Failure(errorDescription: "This app build is missing the agent hook script.")
        }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let searchPaths = path.split(separator: ":").filter { $0.hasPrefix("/") && $0 != "/usr/bin" }.map(String.init)
            + ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]

        guard let python = searchPaths.lazy.map({ $0 + "/python3" })
            .first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw Failure(errorDescription: "Python 3.9 or newer is required to set up agent hooks.")
        }

        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: python)
        process.arguments = [script.path, action, provider.rawValue]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = (String(bytes: data, encoding: .utf8) ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        guard process.terminationStatus == 0 else {
            let firstLine = output.split(separator: "\n").first.map(String.init)
            throw Failure(errorDescription: firstLine ?? "Could not update \(provider.name) hooks.")
        }
        return output
    }
}
