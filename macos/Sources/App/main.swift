import AppKit
import Cocoa
import GhosttyKit

// Ghostty X: started from another Ghostty's shell (directly, or through `open`), this app
// inherits that app's resources directory and would load its shell integration, prompt
// and themes instead of its own. Keep the variable only when it points inside this bundle.
if let inherited = getenv("GHOSTTY_RESOURCES_DIR") {
    let path = String(cString: inherited)
    if SignalDemo.isRequested || !path.hasPrefix(Bundle.main.bundlePath) {
        unsetenv("GHOSTTY_RESOURCES_DIR")
    }
}

// Initialize Ghostty global state. We do this once right away because the
// CLI APIs require it and it lets us ensure it is done immediately for the
// rest of the app.
if ghostty_init(UInt(CommandLine.argc), CommandLine.unsafeArgv) != GHOSTTY_SUCCESS {
    Ghostty.logger.critical("ghostty_init failed")

    // We also write to stderr if this is executed from the CLI or zig run
    switch Ghostty.launchSource {
    case .cli, .zig_run:
        let stderrHandle = FileHandle.standardError
        stderrHandle.write(
            "Ghostty failed to initialize! If you're executing Ghostty from the command line\n" +
            "then this is usually because an invalid action or multiple actions were specified.\n" +
            "Actions start with the `+` character.\n\n" +
            "View all available actions by running `ghostty +help`.\n")
        exit(1)

    case .app:
        // For the app we exit immediately. We should handle this case more
        // gracefully in the future.
        exit(1)
    }
}

// This will run the CLI action and exit if one was specified. A CLI
// action is a command starting with a `+`, such as `ghostty +boo`.
ghostty_cli_try_action()

_ = NSApplicationMain(CommandLine.argc, CommandLine.unsafeArgv)
