import AppKit
import Testing
@testable import Ghostty

/// The "agent is working" bar is moved by Core Animation, not by a timer. These check
/// that it really is moving when it should be, and at rest when it should not.
@MainActor
@Suite(.serialized)
struct AgentActivityTrackTests {
    /// A small window that is really on screen: the bar only travels in a window that
    /// can be seen.
    private func visibleWindow(holding view: NSView) async throws -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(x: 40, y: 40, width: 160, height: 40),
            styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: NSRect(x: 0, y: 0, width: 160, height: 40))
        window.contentView = content
        view.frame = NSRect(x: 20, y: 18, width: 64, height: 4)
        content.addSubview(view)
        window.orderFrontRegardless()
        for _ in 0..<40 where !window.occlusionState.contains(.visible) {
            try await Task.sleep(for: .milliseconds(50))
        }
        content.layoutSubtreeIfNeeded()
        return window
    }

    @Test func travelsOnlyWhileItShould() async throws {
        let track = AgentActivityTrackView()
        let window = try await visibleWindow(holding: track)
        defer { window.close() }
        try #require(window.occlusionState.contains(.visible), "the test window never came on screen")
        let reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion

        #expect(track.isTravelling == !reduceMotion)

        // Laying out again must not restart a travel that already fits.
        track.needsLayout = true
        track.layoutSubtreeIfNeeded()
        #expect(track.isTravelling == !reduceMotion)

        track.animates = false
        #expect(!track.isTravelling)

        track.animates = true
        #expect(track.isTravelling == !reduceMotion)

        // Too small to show anything.
        track.frame.size.width = 1
        track.layoutSubtreeIfNeeded()
        #expect(!track.isTravelling)

        track.frame.size.width = 64
        track.layoutSubtreeIfNeeded()
        track.removeFromSuperview()
        #expect(!track.isTravelling)
    }

    @Test func staysStillOutsideAWindow() {
        let track = AgentActivityTrackView(frame: NSRect(x: 0, y: 0, width: 64, height: 4))
        track.layoutSubtreeIfNeeded()
        #expect(!track.isTravelling)
    }
}
