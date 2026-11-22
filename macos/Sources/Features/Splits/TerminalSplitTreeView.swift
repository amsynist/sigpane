import GhosttyKit
import SwiftUI

/// A single operation within the split tree.
///
/// Rather than binding the split tree (which is immutable), any mutable operations are
/// exposed via this enum to the embedder to handle.
enum TerminalSplitOperation {
    case resize(Resize)
    case drop(Drop)

    struct Resize {
        let node: SplitTree<Ghostty.SurfaceView>.Node
        let ratio: Double
    }

    struct Drop {
        /// The surface being dragged.
        let payload: Ghostty.SurfaceView

        /// The surface it was dragged onto
        let destination: Ghostty.SurfaceView

        /// The zone it was dropped to determine how to split the destination.
        let zone: TerminalSplitDropZone
    }
}

struct TerminalSplitTreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject private var chrome = TabBarSettingsStore.shared

    let tree: SplitTree<Ghostty.SurfaceView>
    let action: (TerminalSplitOperation) -> Void

    /// Ghostty X: gutter between split panes. It is painted with the terminal background
    /// (same color and opacity as the panes) so a translucent, blurred window reads as one
    /// even surface instead of showing the desktop through the gaps.
    static let gutter: CGFloat = 6
    static let paneRadius: CGFloat = 8

    private var hasSplits: Bool {
        if let root = tree.root, case .split = root { return true }
        return false
    }

    var body: some View {
        if let node = tree.zoomed ?? tree.root {
            let settings = chrome.settings
            // Signal windows frame every pane, a lone or zoomed one included.
            let framed = settings.isSignal || (tree.zoomed == nil && hasSplits)
            let gutter = settings.gutter
            TerminalSplitSubtreeView(
                node: node,
                isRoot: tree.zoomed != nil || node == tree.root,
                order: (tree.root?.leaves() ?? []).map { ObjectIdentifier($0) },
                action: action)
            // This is necessary because we can't rely on SwiftUI's implicit
            // structural identity to detect changes to this view. Due to
            // the tree structure of splits it could result in bad behaviors.
            // See: https://github.com/ghostty-org/ghostty/issues/7546
            .id(node.structuralIdentity)
            .padding(framed ? gutter : 0)
            .background {
                if framed {
                    GutterRing(inset: gutter)
                        .fill(ghostty.config.splitGutterColor, style: FillStyle(eoFill: true))
                        .allowsHitTesting(false)
                }
            }
        }
    }
}

private struct TerminalSplitSubtreeView: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject private var chrome = TabBarSettingsStore.shared

    let node: SplitTree<Ghostty.SurfaceView>.Node
    var isRoot: Bool = false
    /// Every pane of the window in reading order, for the A, B, C… labels.
    let order: [ObjectIdentifier]
    let action: (TerminalSplitOperation) -> Void

    var body: some View {
        switch node {
        case .leaf(let leafView):
            TerminalSplitLeaf(surfaceView: leafView, isSplit: !isRoot, order: order, action: action)

        case .split(let split):
            let splitViewDirection: SplitViewDirection = switch split.direction {
            case .horizontal: .horizontal
            case .vertical: .vertical
            }

            SplitView(
                splitViewDirection,
                .init(get: {
                    CGFloat(split.ratio)
                }, set: {
                    action(.resize(.init(node: node, ratio: $0)))
                }),
                dividerColor: ghostty.config.splitGutterColor,
                dividerAccent: chrome.settings.isSignal ? dividerTint(of: node) : nil,
                dividerSize: chrome.settings.gutter,
                resizeIncrements: .init(width: 1, height: 1),
                left: {
                    TerminalSplitSubtreeView(node: split.left, order: order, action: action)
                },
                right: {
                    TerminalSplitSubtreeView(node: split.right, order: order, action: action)
                },
                onEqualize: {
                    guard let surface = node.leftmostLeaf().surface else { return }
                    ghostty.splitEqualize(surface: surface)
                }
            )
        }
    }
}

private struct TerminalSplitLeaf: View {
    @EnvironmentObject var ghostty: Ghostty.App
    @ObservedObject private var chrome = TabBarSettingsStore.shared

    let surfaceView: Ghostty.SurfaceView
    let isSplit: Bool
    /// Every pane of the window in reading order, for the A, B, C… labels.
    let order: [ObjectIdentifier]
    let action: (TerminalSplitOperation) -> Void

    @Environment(\.ghosttyLastFocusedSurface) private var focusedSurface
    @State private var dropState: DropState = .idle
    @State private var isSelfDragging: Bool = false
    /// 0 → 1 as the focus sweep travels down a pane that just took focus.
    @State private var sweep: CGFloat = 1
    /// Bumped when tab colors are reshuffled, so the tint is read again.
    @State private var colorEpoch = 0

    var body: some View {
        let settings = chrome.settings
        let signal = settings.isSignal
        // Signal windows frame every pane; the classic look only frames panes of a split.
        let framed = isSplit || signal
        let radius: CGFloat = framed ? settings.paneCornerRadius : 0
        let focused = focusedSurface?.value === surfaceView
        let theme = RoundedTabTheme(config: ghostty.config)
        let tint: Color = signal
            ? signalTint(theme, settings, epoch: colorEpoch)
            : Color(red: 0.478, green: 0.635, blue: 0.969)
        let shape = RoundedRectangle(cornerRadius: radius, style: .continuous)

        VStack(spacing: 0) {
            if settings.showsPaneHeaders {
                SignalPaneHeader(
                    surfaceView: surfaceView,
                    tag: SignalText.paneLetter(order.firstIndex(of: ObjectIdentifier(surfaceView)) ?? 0),
                    focused: focused,
                    tint: tint,
                    foreground: Color(nsColor: theme.foreground))
            }
            GeometryReader { geometry in
                Ghostty.InspectableSurface(
                    surfaceView: surfaceView,
                    isSplit: isSplit)
                .background {
                    // If we're dragging ourself, we hide the entire drop zone. This makes
                    // it so that a released drop animates back to its source properly
                    // so it is a proper invalid drop zone.
                    if !isSelfDragging {
                        Color.clear
                            .onDrop(of: [.ghosttySurfaceId], delegate: SplitDropDelegate(
                                dropState: $dropState,
                                viewSize: geometry.size,
                                destinationSurface: surfaceView,
                                action: action
                            ))
                    }
                }
                .overlay {
                    if !isSelfDragging, case .dropping(let zone) = dropState {
                        zone.overlay(in: geometry)
                            .allowsHitTesting(false)
                    }
                }
                .onPreferenceChange(Ghostty.DraggingSurfaceKey.self) { value in
                    isSelfDragging = value == surfaceView.id
                    if isSelfDragging {
                        dropState = .idle
                    }
                }
            }
        }
        .background {
            // Keeps the command-block overlay on this pane's terminal. Draws nothing itself.
            SignalBlockAttachment(
                surfaceView: surfaceView,
                enabled: settings.showsCommandBlocks,
                tint: NSColor(tint),
                foreground: theme.foreground,
                background: theme.background,
                focused: focused)
            .frame(width: 0, height: 0)
            .allowsHitTesting(false)
        }
        .clipShape(shape)
        .background {
            // Fill the corner wedges outside the rounded pane so they match the gutter.
            if framed {
                PaneCorners(radius: radius)
                    .fill(ghostty.config.splitGutterColor, style: FillStyle(eoFill: true))
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if framed {
                shape
                    .strokeBorder(
                        focused ? tint.opacity(signal ? 0.42 : 0.7) : Color.primary.opacity(signal ? 0.08 : 0.12),
                        lineWidth: focused || signal ? 1 : 0.5)
                    .allowsHitTesting(false)
            }
        }
        .overlay {
            if signal && focused {
                SignalFocusChrome(
                    shape: shape, radius: radius, tint: tint, sweep: sweep,
                    glow: settings.focusGlow, corners: settings.focusCorners)
            }
        }
        .onChange(of: focused) { nowFocused in
            guard nowFocused, signal, settings.animations,
                  !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            // Restart from the top on the next runloop turn, so the reset itself is not animated.
            sweep = 0
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.7)) { sweep = 1 }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .ghosttyXTabColorsDidShuffle)) { _ in
            colorEpoch += 1
        }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Terminal pane")
    }

    /// The window's Signal tint. Taking the epoch makes the body depend on it, so a tab
    /// color change re-evaluates the tint.
    private func signalTint(_ theme: RoundedTabTheme, _ settings: TabBarSettings, epoch: Int) -> Color {
        Color(nsColor: theme.signal(for: surfaceView.window, settings: settings))
    }

    private enum DropState: Equatable {
        case idle
        case dropping(TerminalSplitDropZone)
    }

    private struct SplitDropDelegate: DropDelegate {
        @Binding var dropState: DropState
        let viewSize: CGSize
        let destinationSurface: Ghostty.SurfaceView
        let action: (TerminalSplitOperation) -> Void

        func validateDrop(info: DropInfo) -> Bool {
            info.hasItemsConforming(to: [.ghosttySurfaceId])
        }

        func dropEntered(info: DropInfo) {
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
        }

        func dropUpdated(info: DropInfo) -> DropProposal? {
            // For some reason dropUpdated is sent after performDrop is called
            // and we don't want to reset our drop zone to show it so we have
            // to guard on the state here.
            guard case .dropping = dropState else { return DropProposal(operation: .forbidden) }
            dropState = .dropping(.calculate(at: info.location, in: viewSize))
            return DropProposal(operation: .move)
        }

        func dropExited(info: DropInfo) {
            dropState = .idle
        }

        func performDrop(info: DropInfo) -> Bool {
            let zone = TerminalSplitDropZone.calculate(at: info.location, in: viewSize)
            dropState = .idle

            // Load the dropped surface asynchronously using Transferable
            let providers = info.itemProviders(for: [.ghosttySurfaceId])
            guard let provider = providers.first else { return false }

            // Capture action before the async closure
            _ = provider.loadTransferable(type: Ghostty.SurfaceView.self) { [weak destinationSurface] result in
                switch result {
                case .success(let sourceSurface):
                    DispatchQueue.main.async {
                        // Don't allow dropping on self
                        guard let destinationSurface else { return }
                        guard sourceSurface !== destinationSurface else { return }
                        action(.drop(.init(payload: sourceSurface, destination: destinationSurface, zone: zone)))
                    }

                case .failure:
                    break
                }
            }

            return true
        }
    }
}

enum TerminalSplitDropZone: String, Equatable {
    case top
    case bottom
    case left
    case right

    /// Determines which drop zone the cursor is in based on proximity to edges.
    ///
    /// Divides the view into four triangular regions by drawing diagonals from
    /// corner to corner. The drop zone is determined by which edge the cursor
    /// is closest to, creating natural triangular hit regions for each side.
    static func calculate(at point: CGPoint, in size: CGSize) -> TerminalSplitDropZone {
        let relX = point.x / size.width
        let relY = point.y / size.height

        let distToLeft = relX
        let distToRight = 1 - relX
        let distToTop = relY
        let distToBottom = 1 - relY

        let minDist = min(distToLeft, distToRight, distToTop, distToBottom)

        if minDist == distToLeft { return .left }
        if minDist == distToRight { return .right }
        if minDist == distToTop { return .top }
        return .bottom
    }

    @ViewBuilder
    func overlay(in geometry: GeometryProxy) -> some View {
        let overlayColor = Color.accentColor.opacity(0.3)

        switch self {
        case .top:
            VStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
                Spacer()
            }
        case .bottom:
            VStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(height: geometry.size.height / 2)
            }
        case .left:
            HStack(spacing: 0) {
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
                Spacer()
            }
        case .right:
            HStack(spacing: 0) {
                Spacer()
                Rectangle()
                    .fill(overlayColor)
                    .frame(width: geometry.size.width / 2)
            }
        }
    }
}

/// The tint of the window a subtree lives in, for the divider handle.
@MainActor
private func dividerTint(of node: SplitTree<Ghostty.SurfaceView>.Node) -> Color {
    let settings = TabBarSettingsStore.shared.settings
    return Color(nsColor: RoundedTabTheme.current.signal(for: node.leftmostLeaf().window, settings: settings))
}

/// Ghostty X: the strip above a pane in Signal windows — its letter, title, directory and
/// size in cells. While the pointer is over it: copy the last command's output, list recent
/// commands, split, and close.
///
/// The surface publishes on every pointer move, so this view does not observe it as a
/// whole. It subscribes to the three values it shows and ignores repeats.
private struct SignalPaneHeader: View {
    @EnvironmentObject var ghostty: Ghostty.App

    let surfaceView: Ghostty.SurfaceView
    let tag: String
    let focused: Bool
    let tint: Color
    let foreground: Color

    @State private var title = ""
    @State private var path = ""
    @State private var size = ""
    @State private var hovered = false
    @State private var copied = false

    var body: some View {
        HStack(spacing: 9) {
            Text(verbatim: tag)
                .fontWeight(.bold)
                .foregroundColor(focused ? tint : foreground.opacity(0.5))
            // A title that is only the directory is shown once, as the directory.
            let titleIsDirectory = SignalText.isDirectoryTitle(title, path: path)
            let directory = path.isEmpty ? "" : SignalText.abbreviate(path: path, components: 3)
            Text(verbatim: titleIsDirectory ? directory : title)
                .foregroundColor(foreground.opacity(focused ? 0.9 : 0.4))
                .lineLimit(1)
                .truncationMode(.middle)
                .layoutPriority(1)
            if !directory.isEmpty, !titleIsDirectory {
                Text(verbatim: directory)
                    .foregroundColor(foreground.opacity(0.3))
                    .lineLimit(1)
                    .truncationMode(.head)
            }
            Spacer(minLength: 4)
            if !size.isEmpty {
                Text(verbatim: size)
                    .foregroundColor(foreground.opacity(0.3))
                    .lineLimit(1)
                    .fixedSize()
            }
            // Copying the last output stays visible on the focused pane, so it can be found.
            if focused || hovered {
                control(copied ? "checkmark" : "doc.on.doc", label: "Copy the last command's output") {
                    copyLastOutput()
                }
            }
            if hovered {
                control("rectangle.split.2x1", label: "Split right") {
                    guard let surface = surfaceView.surface else { return }
                    ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_RIGHT)
                }
                control("rectangle.split.1x2", label: "Split down") {
                    guard let surface = surfaceView.surface else { return }
                    ghostty.split(surface: surface, direction: GHOSTTY_SPLIT_DIRECTION_DOWN)
                }
                control("xmark", label: "Close pane") {
                    guard let surface = surfaceView.surface else { return }
                    ghostty.requestClose(surface: surface)
                }
            }
        }
        .font(.system(size: 10.5, design: .monospaced))
        .padding(.leading, 13)
        .padding(.trailing, 7)
        .frame(maxWidth: .infinity)
        .frame(height: TabBarSettings.paneHeaderHeight)
        .background(ghostty.config.splitGutterColor)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(foreground.opacity(0.07))
                .frame(height: 1)
        }
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .onReceive(surfaceView.$title.removeDuplicates()) { title = SignalText.printable($0) }
        .onReceive(surfaceView.$pwd.removeDuplicates()) { path = $0 ?? "" }
        .onReceive(surfaceView.$surfaceSize.map(Self.describe).removeDuplicates()) { size = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Pane \(tag)")
    }

    nonisolated private static func describe(_ size: ghostty_surface_size_s?) -> String {
        guard let size else { return "" }
        return "\(size.columns)×\(size.rows)"
    }

    private func control(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 9.5, weight: .semibold))
                .foregroundColor(foreground.opacity(0.7))
                .frame(width: 18, height: 16)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(label)
        .accessibilityLabel(label)
    }

    private func copyLastOutput() {
        guard let text = surfaceView.commandText(back: 0), !text.isEmpty else {
            NSSound.beep()
            return
        }
        SignalText.copy(text)
        copied = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { copied = false }
    }
}

extension Ghostty.SurfaceView {
    /// Ghostty X: text of a recent command, found through the prompt marks that shell
    /// integration leaves. `back` 0 is the most recent command with output. Returns nil
    /// when there is no such command (or no shell integration). Output that was folded
    /// comes back whole.
    ///
    /// This walks the scrollback, so call it when the user asks, not while drawing.
    func commandText(back: Int, input: Bool = false) -> String? {
        guard let surface, back >= 0 else { return nil }
        var text = ghostty_text_s()
        guard ghostty_surface_read_command(surface, UInt32(back), input ? 1 : 0, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }
        return String(cString: text.text)
    }
}

/// Ghostty X: what marks the focused pane in Signal windows — a soft glow on its outline,
/// bright corner brackets, and a sweep that runs down the pane when it takes focus.
private struct SignalFocusChrome: View {
    let shape: RoundedRectangle
    let radius: CGFloat
    let tint: Color
    let sweep: CGFloat
    let glow: Bool
    let corners: Bool

    var body: some View {
        ZStack {
            if glow {
                shape
                    .stroke(tint.opacity(0.55), lineWidth: 2)
                    .blur(radius: 7)
            }
            if sweep < 1 {
                GeometryReader { geometry in
                    LinearGradient(
                        colors: [tint.opacity(0), tint.opacity(0.14), tint.opacity(0.6)],
                        startPoint: .top, endPoint: .bottom)
                    .frame(height: 70)
                    .offset(y: -70 + sweep * (geometry.size.height + 70))
                    .opacity(Double(1 - sweep))
                }
                .clipShape(shape)
            }
            if corners {
                PaneCornerBrackets(radius: radius, length: 13)
                    .stroke(tint, style: StrokeStyle(lineWidth: 2, lineCap: .round, lineJoin: .round))
                    .shadow(color: tint.opacity(0.9), radius: 3)
            }
        }
        .allowsHitTesting(false)
    }
}

/// Short arcs at a pane's four corners.
private struct PaneCornerBrackets: Shape {
    let radius: CGFloat
    let length: CGFloat

    func path(in rect: CGRect) -> Path {
        // Inset by half the stroke so the brackets sit on the pane's outline.
        let rect = rect.insetBy(dx: 1, dy: 1)
        let r = max(0, min(radius - 1, rect.width / 2, rect.height / 2))
        let l = min(max(length, r), rect.width / 2, rect.height / 2)
        var path = Path()
        // Top left
        path.move(to: CGPoint(x: rect.minX, y: rect.minY + l))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.minY + r))
        path.addQuadCurve(to: CGPoint(x: rect.minX + r, y: rect.minY), control: CGPoint(x: rect.minX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.minX + l, y: rect.minY))
        // Top right
        path.move(to: CGPoint(x: rect.maxX - l, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX - r, y: rect.minY))
        path.addQuadCurve(to: CGPoint(x: rect.maxX, y: rect.minY + r), control: CGPoint(x: rect.maxX, y: rect.minY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + l))
        // Bottom right
        path.move(to: CGPoint(x: rect.maxX, y: rect.maxY - l))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY - r))
        path.addQuadCurve(to: CGPoint(x: rect.maxX - r, y: rect.maxY), control: CGPoint(x: rect.maxX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.maxX - l, y: rect.maxY))
        // Bottom left
        path.move(to: CGPoint(x: rect.minX + l, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX + r, y: rect.maxY))
        path.addQuadCurve(to: CGPoint(x: rect.minX, y: rect.maxY - r), control: CGPoint(x: rect.minX, y: rect.maxY))
        path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY - l))
        return path
    }
}

/// The outer gutter around the split panes: the full rect minus an inset rect (even-odd).
private struct GutterRing: Shape {
    let inset: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRect(rect.insetBy(dx: inset, dy: inset))
        return path
    }
}

/// The area of a pane's rect outside its rounded corners (even-odd).
private struct PaneCorners: Shape {
    let radius: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(in: rect, cornerSize: CGSize(width: radius, height: radius), style: .continuous)
        return path
    }
}

extension Ghostty.Config {
    /// Terminal background at the configured opacity, for the gaps between split panes.
    var splitGutterColor: Color {
        backgroundColor.opacity(min(max(backgroundOpacity, 0), 1))
    }
}

// MARK: - Command blocks

/// Ghostty X: keeps a `SignalBlockView` over a pane's terminal while command blocks are on.
/// It draws nothing itself. The overlay is an AppKit view placed beside the surface view,
/// so a click that misses its buttons reaches the terminal exactly as before.
private struct SignalBlockAttachment: NSViewRepresentable {
    let surfaceView: Ghostty.SurfaceView
    let enabled: Bool
    let tint: NSColor
    let foreground: NSColor
    let background: NSColor
    let focused: Bool

    func makeNSView(context: Context) -> NSView { NSView(frame: .zero) }

    func updateNSView(_ nsView: NSView, context: Context) {
        guard enabled else {
            SignalBlockView.remove(from: surfaceView)
            return
        }
        let view = SignalBlockView.attach(to: surfaceView)
        view.colors = .init(tint: tint, foreground: foreground, background: background, focused: focused)
    }
}

/// Ghostty X: draws a box around each command and its output, with a copy button and a
/// fold chevron on the command line, and the command deck: the prompt being typed at, as a
/// card in the window's color the way the selected session card is.
///
/// The terminal core says which rows each command block covers (it knows from the prompt
/// marks shell integration leaves). This view asks for the blocks in view and draws over
/// them. It asks often while the terminal is changing and rarely while it is still, and
/// not at all while its window is off screen.
final class SignalBlockView: NSView {
    struct Colors: Equatable {
        var tint: NSColor = .controlAccentColor
        var foreground: NSColor = .white
        var background: NSColor = .black
        /// Whether this pane has the keyboard. Only then is the command deck colored.
        var focused = true
    }

    /// One block as the core reports it, in viewport rows.
    private struct Block: Equatable {
        var top: Int
        var bottom: Int
        var head: Int
        var lines: Int
        var flags: UInt32

        func has(_ flag: UInt32) -> Bool { flags & flag != 0 }
    }

    /// Mirrors the flag bits in ghostty.h.
    private enum Flag {
        static let clippedTop: UInt32 = 1 << 0
        static let clippedBottom: UInt32 = 1 << 1
        static let folded: UInt32 = 1 << 2
        static let hasOutput: UInt32 = 1 << 3
        static let live: UInt32 = 1 << 4
        static let padAbove: UInt32 = 1 << 5
        static let padBelow: UInt32 = 1 << 6
        static let running: UInt32 = 1 << 7
        static let canToggle: UInt32 = 1 << 8
        static let empty: UInt32 = 1 << 10
        static let pointer: UInt32 = 1 << 11
        static let failed: UInt32 = 1 << 12
    }

    /// One chip of the prompt being typed at: its row and its first and last column.
    private struct Chip: Equatable {
        var row: Int
        var start: Int
        var end: Int
        /// 1 directory, 2 git branch, 3 environment, 4 key hint.
        var kind: Int
    }

    /// What the prompt being typed at marked: which look it was laid out for, where its
    /// pointer goes, and its chips.
    private struct Prompt: Equatable {
        /// 0 card, 1 rail, 2 capsule, 3 dock, 4 brackets.
        var style = 0
        var pointerRow = -1
        var pointerCol = -1
        var failed = false
        var chips: [Chip] = []
    }

    /// The Signal palette, for what is drawn over text the shell colors from it.
    private enum Ink {
        static let blue = NSColor(srgbRed: 0.353, green: 0.722, blue: 1, alpha: 1)
        static let violet = NSColor(srgbRed: 0.616, green: 0.549, blue: 1, alpha: 1)
        static let yellow = NSColor(srgbRed: 1, green: 0.765, blue: 0.353, alpha: 1)
        static let red = NSColor(srgbRed: 1, green: 0.435, blue: 0.569, alpha: 1)
        static let green = NSColor(srgbRed: 0.373, green: 0.89, blue: 0.659, alpha: 1)
    }

    /// Where the grid sits in the view, in points.
    private struct Metrics: Equatable {
        var cellWidth: CGFloat = 0
        var cellHeight: CGFloat = 0
        var left: CGFloat = 0
        var top: CGFloat = 0
        var right: CGFloat = 0
        var size: CGSize = .zero
    }

    private enum Action: Equatable { case copy, toggle }

    private struct Hit: Equatable {
        var block: Int
        var action: Action
    }

    /// A block laid out: its box and its buttons. The command deck has no buttons.
    private struct Item {
        var block: Block
        var box: NSRect
        var copy: NSRect
        var toggle: NSRect?
        var isDeck = false
    }

    /// Every overlay with the surface it belongs to. A plain list, gone through on
    /// each change, so an overlay whose surface has gone is dropped for good and not
    /// kept alive by the list (a map with weak keys keeps such entries until it happens
    /// to be resized).
    private struct Entry {
        weak var surfaceView: Ghostty.SurfaceView?
        let view: SignalBlockView
    }
    private static var entries: [Entry] = []

    private static func overlay(of surfaceView: Ghostty.SurfaceView) -> SignalBlockView? {
        entries.first { $0.surfaceView === surfaceView }?.view
    }

    /// Overlays that exist right now, for the demo run's memory report.
    static var liveCount: Int { entries.count }
    private static let fastInterval: TimeInterval = 1.0 / 60
    private static let slowInterval: TimeInterval = 0.25
    /// How long the view keeps asking quickly after the last change it saw.
    private static let settleTime: TimeInterval = 1.2
    private static let maxBlocks = 64

    var colors = Colors() { didSet { if colors != oldValue { needsDisplay = true } } }

    private weak var surfaceView: Ghostty.SurfaceView?
    private var buffer = [ghostty_block_s](repeating: ghostty_block_s(), count: SignalBlockView.maxBlocks)
    private var blocks: [Block] = []
    private var metrics = Metrics()
    private var prompt = Prompt()
    /// The block that was just folded or opened shows it for a moment, so the eye finds
    /// what changed and which way it went: the row of its command line, how much of the
    /// moment is left (1 down to 0), whether it was opened, and the count from the core
    /// that says a change happened.
    private var flashRow = -1
    private var flashAmount: CGFloat = 0
    private var flashOpening = false
    private var flashSerial: UInt32?
    private let flashMotion = SignalMotion()
    /// The block picked with the keyboard (Shift with the up and down arrows), as the
    /// screen row of its command line: the row in view plus where the view starts, which
    /// stays the same while the view scrolls.
    private var selectedRow: Int?
    /// Where the view starts, as a screen row, and whether the shell is at a prompt.
    private var viewTop = 0
    private var ready = false
    /// A move that had to scroll first: its direction, and how many more looks it waits
    /// for the block it is after to come into view.
    private var pendingMove = 0
    private var pendingLooks = 0
    /// The peek that is open, and the row of the command line it belongs to.
    private var peekView: SignalPeekView?
    private var peekHead = -1
    private var items: [Item] = []
    private var hover: Hit?
    private var hoverBlock: Int?
    private var pressed: Hit?
    /// The block whose copy button shows a check mark, by the row of its command line.
    private var copiedHead: Int?
    private var timer: Timer?
    private var interval: TimeInterval = 0
    private var lastChange = Date.distantPast
    private var observers: [NSObjectProtocol] = []

    // MARK: Attaching

    /// The overlay for a surface, created and placed over it if it has none.
    static func attach(to surfaceView: Ghostty.SurfaceView) -> SignalBlockView {
        if let view = overlay(of: surfaceView) {
            view.place()
            return view
        }
        let view = SignalBlockView(surfaceView: surfaceView)
        // Overlays of surfaces that have since closed are let go here too.
        for stale in entries where stale.surfaceView == nil { stale.view.teardown() }
        entries.append(Entry(surfaceView: surfaceView, view: view))
        view.place()
        return view
    }

    static func remove(from surfaceView: Ghostty.SurfaceView) {
        overlay(of: surfaceView)?.teardown()
    }

    private init(surfaceView: Ghostty.SurfaceView) {
        self.surfaceView = surfaceView
        super.init(frame: surfaceView.frame)
        wantsLayer = true
        layerContentsRedrawPolicy = .onSetNeedsDisplay
        addTrackingArea(NSTrackingArea(
            rect: .zero,
            options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
            owner: self))

        let center = NotificationCenter.default
        // The surface view moves inside its scroll view as the scrollback scrolls.
        observers.append(center.addObserver(
            forName: NSView.frameDidChangeNotification, object: surfaceView, queue: nil
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.wake(now: true) }
        })
        observers.append(center.addObserver(
            forName: NSWindow.didChangeOcclusionStateNotification, object: nil, queue: nil
        ) { [weak self] note in
            MainActor.assumeIsolated {
                guard let self else { return }
                // A surface that has gone away takes its overlay with it.
                guard self.surfaceView != nil else { self.teardown(); return }
                if (note.object as? NSWindow) === self.window { self.wake(now: true) }
            }
        })
        Self.watchEvents()
    }

    /// One monitor for every overlay, installed once and kept. (One per overlay meant a
    /// call into each of them for every key, and the system's leak checker counted each
    /// removed monitor as a small leak.)
    private static var eventMonitor: Any?

    private static func watchEvents() {
        guard eventMonitor == nil else { return }
        // Keys, clicks and scrolling are when the terminal is about to change.
        eventMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.keyDown, .scrollWheel, .leftMouseUp, .leftMouseDown, .rightMouseDown]
        ) { event in
            guard let window = event.window else { return event }
            var taken = false
            for entry in entries where entry.view.window === window {
                if entry.view.noticed(event) { taken = true }
            }
            return taken ? nil : event
        }
    }

    /// An event in this overlay's window. True if the event was for the overlay alone
    /// and must not reach the terminal.
    private func noticed(_ event: NSEvent) -> Bool {
        if peekView != nil, putsPeekAway(event) {
            closePeek()
            // Escape was for the peek, not for the shell.
            if event.type == .keyDown, event.keyCode == 53 { return true }
        }
        if event.type == .leftMouseDown || event.type == .rightMouseDown {
            clearSelection()
        } else if event.type == .keyDown, !hasKeyboard {
            // A key goes to one pane. The others keep their slow pace.
        } else {
            wake()
        }
        return false
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }
    override var isOpaque: Bool { false }
    override var acceptsFirstResponder: Bool { false }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        wake(now: true)
    }

    /// Puts the overlay directly above the surface view, in the same parent.
    private func place() {
        guard let surfaceView, let host = surfaceView.superview else { return }
        if superview !== host || host.subviews.last !== self {
            host.addSubview(self, positioned: .above, relativeTo: surfaceView)
        }
        if frame != surfaceView.frame { frame = surfaceView.frame }
        wake(now: true)
    }

    private func teardown() {
        timer?.invalidate()
        timer = nil
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers = []
        flashMotion.stop()
        closePeek()
        removeFromSuperview()
        Self.entries.removeAll { $0.view === self || $0.surfaceView == nil }
    }

    /// For the demo run: presses the fold button of the topmost folded block in view.
    static func pressTopFold(of surfaceView: Ghostty.SurfaceView) -> Bool {
        guard let view = overlay(of: surfaceView) else { return false }
        view.refresh()
        guard let item = view.items.first(where: {
            !$0.isDeck && $0.toggle != nil && $0.block.has(Flag.folded)
        }) else { return false }
        view.run(.toggle, on: item.block)
        return view.peekView != nil
    }

    /// Whether this overlay's pane is the one keys go to.
    private var hasKeyboard: Bool {
        guard let surfaceView, let controller = window?.windowController as? BaseTerminalController else {
            return true
        }
        return controller.focusedSurface === surfaceView
    }

    // MARK: Picking a block with the keyboard

    /// Gives a key to the overlay of the pane that has the keyboard. True if it was used.
    static func handleKey(_ event: NSEvent, in surfaceView: Ghostty.SurfaceView) -> Bool {
        overlay(of: surfaceView)?.handleKey(event) ?? false
    }

    /// For the demo run: what Shift with an arrow does, and what Control-C then does.
    static func moveSelection(of surfaceView: Ghostty.SurfaceView, up: Bool) -> Bool {
        guard let view = overlay(of: surfaceView) else { return false }
        view.refresh()
        return view.moveSelection(up: up)
    }

    static func copySelection(of surfaceView: Ghostty.SurfaceView) -> Bool {
        overlay(of: surfaceView)?.copySelection() ?? false
    }

    /// Shift with the up and down arrows moves from one finished command to the next,
    /// Control-C copies the one picked, Escape lets go of it, and any other key lets go
    /// of it and is typed as usual. Only at a prompt: a running program keeps its keys.
    private func handleKey(_ event: NSEvent) -> Bool {
        let held = event.modifierFlags.intersection([.control, .command, .option, .shift])
        if held == .shift, event.keyCode == 126 || event.keyCode == 125 {
            return moveSelection(up: event.keyCode == 126)
        }
        guard selectedRow != nil else { return false }
        // Control-C, and Command-C as anywhere else on a Mac.
        if held == .control || held == .command, event.charactersIgnoringModifiers?.lowercased() == "c" {
            return copySelection()
        }
        clearSelection()
        // Escape was for the selection, not for the shell.
        return held.isEmpty && event.keyCode == 53
    }

    /// The finished commands in view that can be told apart: those whose command line
    /// is in view. Top to bottom.
    private func candidates(in blocks: [Block]) -> [Block] {
        blocks.filter { $0.head >= 0 && !$0.has(Flag.live) && !$0.has(Flag.running) && !$0.has(Flag.empty) }
    }

    private func isSelected(_ block: Block) -> Bool {
        guard let selectedRow, block.head >= 0 else { return false }
        return viewTop + block.head == selectedRow
    }

    private func clearSelection() {
        guard selectedRow != nil || pendingMove != 0 else { return }
        selectedRow = nil
        pendingMove = 0
        needsDisplay = true
    }

    private func moveSelection(up: Bool) -> Bool {
        guard ready, let surfaceView else { return false }
        let found = candidates(in: blocks)
        guard let current = selectedRow else {
            // Nothing picked yet: up picks the newest finished command in view.
            guard up, let last = found.last else { return false }
            selectedRow = viewTop + last.head
            needsDisplay = true
            return true
        }
        let rows = found.map { viewTop + $0.head }
        if let next = up ? rows.last(where: { $0 < current }) : rows.first(where: { $0 > current }) {
            selectedRow = next
            needsDisplay = true
            return true
        }
        // Past the newest one, back at the prompt, nothing is picked.
        if !up, blocks.contains(where: { $0.has(Flag.live) }) {
            clearSelection()
            return true
        }
        // The next one is out of view: scroll a prompt that way, then pick it.
        pendingMove = up ? -1 : 1
        pendingLooks = 8
        _ = surfaceView.surfaceModel?.perform(action: up ? "jump_to_prompt:-1" : "jump_to_prompt:1")
        wake(now: true)
        return true
    }

    /// Called with every fresh list of blocks: finishes a move that scrolled, and lets
    /// go of a block that is no longer there (the screen changed under it).
    private func settleSelection(in next: [Block]) {
        guard let current = selectedRow else { return }
        let rows = candidates(in: next).map { viewTop + $0.head }
        if pendingMove != 0 {
            let target = pendingMove < 0 ? rows.last(where: { $0 < current }) : rows.first(where: { $0 > current })
            if let target {
                selectedRow = target
                pendingMove = 0
                needsDisplay = true
            } else {
                pendingLooks -= 1
                if pendingLooks <= 0 { pendingMove = 0 }
            }
            return
        }
        if !ready { clearSelection() }
    }

    /// Copies the picked block's output (its command if it printed nothing), says so on
    /// the block, and lets go of it.
    private func copySelection() -> Bool {
        guard let block = blocks.first(where: { isSelected($0) }) else {
            clearSelection()
            return false
        }
        run(.copy, on: block)
        clearSelection()
        return true
    }

    // MARK: Asking the core

    /// Starts asking quickly: something is about to change, or just did. `now` also asks
    /// straight away, for changes that have already happened.
    private func wake(now: Bool = false) {
        lastChange = Date()
        schedule(Self.fastInterval)
        if now { refresh() }
    }

    private func schedule(_ wanted: TimeInterval) {
        guard timer == nil || interval != wanted else { return }
        timer?.invalidate()
        interval = wanted
        let timer = Timer(timeInterval: wanted, repeats: true) { [weak self] timer in
            MainActor.assumeIsolated {
                guard let self else { timer.invalidate(); return }
                self.refresh()
            }
        }
        timer.tolerance = wanted * 0.3
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private func refresh() {
        guard let surfaceView else {
            teardown()
            return
        }
        guard let host = surfaceView.superview else {
            // Between parents: the pane's view puts the overlay back when it has one.
            timer?.invalidate()
            timer = nil
            return
        }
        if superview !== host {
            host.addSubview(self, positioned: .above, relativeTo: surfaceView)
        }
        if frame != surfaceView.frame { frame = surfaceView.frame }

        // Nothing to draw for a window nobody can see: stop until it comes back.
        guard let window, window.occlusionState.contains(.visible), let surface = surfaceView.surface else {
            timer?.invalidate()
            timer = nil
            return
        }

        var geometry = ghostty_block_geometry_s()
        let count = buffer.withUnsafeMutableBufferPointer { pointer -> Int in
            guard let base = pointer.baseAddress else { return 0 }
            return Int(ghostty_surface_blocks(surface, base, UInt32(pointer.count), &geometry))
        }
        let scale = max(1, window.backingScaleFactor)
        let nextMetrics = Metrics(
            cellWidth: CGFloat(geometry.cell_width) / scale,
            cellHeight: CGFloat(geometry.cell_height) / scale,
            left: CGFloat(geometry.padding_left) / scale,
            top: CGFloat(geometry.padding_top) / scale,
            right: CGFloat(geometry.padding_right) / scale,
            size: bounds.size)
        var next: [Block] = []
        next.reserveCapacity(count)
        for index in 0..<min(count, buffer.count) {
            let raw = buffer[index]
            next.append(Block(
                top: Int(raw.top), bottom: Int(raw.bottom), head: Int(raw.head),
                lines: Int(raw.lines), flags: raw.flags))
        }

        let marked = geometry.prompt.chips
        let nextPrompt = Prompt(
            style: Int(geometry.prompt.style),
            pointerRow: Int(geometry.prompt.pointer_row), pointerCol: Int(geometry.prompt.pointer_col),
            failed: geometry.prompt.failed != 0,
            chips: [marked.0, marked.1, marked.2, marked.3, marked.4, marked.5]
                .prefix(Int(min(geometry.prompt.count, 6)))
                .map { Chip(row: Int($0.row), start: Int($0.start), end: Int($0.end), kind: Int($0.kind)) })

        // A fold or an opening since the last look: light that block briefly. The first
        // look only learns the count, so nothing flashes when a pane appears.
        let serial = geometry.prompt.changed_serial
        if let seen = flashSerial, seen != serial, geometry.prompt.changed_row >= 0,
           !RoundedTerminalTabBar.reduceMotion {
            flashRow = Int(geometry.prompt.changed_row)
            flashOpening = next.contains { $0.head == flashRow && $0.has(Flag.hasOutput) }
            flashMotion.run(duration: flashOpening ? 0.46 : 0.5) { [weak self] progress in
                guard let self else { return }
                self.flashAmount = 1 - progress
                self.needsDisplay = true
            }
        }
        flashSerial = serial

        viewTop = Int(geometry.prompt.view_top)
        ready = geometry.prompt.ready != 0
        settleSelection(in: next)

        // A peek belongs to one folded command line on one row. When that is no longer
        // what is there (the view scrolled, the pane was resized, the block was opened),
        // the peek goes.
        if peekView != nil,
           nextMetrics != metrics || !next.contains(where: { $0.head == peekHead && $0.has(Flag.folded) }) {
            closePeek()
        }

        if next != blocks || nextMetrics != metrics || nextPrompt != prompt {
            blocks = next
            metrics = nextMetrics
            prompt = nextPrompt
            layoutBlocks()
            lastChange = Date()
            needsDisplay = true
        }
        // Still for a while: ask rarely until something wakes the view.
        let wanted = Date().timeIntervalSince(lastChange) > Self.settleTime ? Self.slowInterval : Self.fastInterval
        schedule(wanted)
    }

    // MARK: Layout

    private func layoutBlocks() {
        items.removeAll(keepingCapacity: true)
        guard metrics.cellHeight > 0 else { return }
        let cell = metrics.cellHeight
        let x0 = max(2, metrics.left - 10)
        let x1 = metrics.size.width - max(2, metrics.right - 10)
        guard x1 - x0 > 80 else { return }
        // A blank row separates blocks. Each box takes under a third of it, which leaves
        // a clear gap between one box and the next.
        let pad = (cell * 0.3).rounded()
        let side = min(22, cell)

        for block in blocks where block.has(Flag.live) || !block.has(Flag.empty) {
            // The command deck is roomier than a finished block.
            let inner = block.has(Flag.live) ? (cell * 0.38).rounded() : pad
            var y0 = metrics.top + CGFloat(block.top) * cell - (block.has(Flag.padAbove) ? inner : 1)
            var y1 = metrics.top + CGFloat(block.bottom + 1) * cell + (block.has(Flag.padBelow) ? inner : 1)
            // A block that runs past the view has no edge there.
            if block.has(Flag.clippedTop) { y0 = -12 }
            if block.has(Flag.clippedBottom) { y1 = metrics.size.height + 12 }
            let box = NSRect(x: x0, y: y0, width: x1 - x0, height: y1 - y0)
            if block.has(Flag.live) {
                // Only the card look has a box here. The others are drawn from the marks.
                if prompt.style == 0 {
                    items.append(Item(block: block, box: box, copy: .zero, toggle: nil, isDeck: true))
                }
                continue
            }

            // Buttons sit on the command line, or on the first row in view when the
            // command line has scrolled off the top.
            let row = block.head >= 0 ? block.head : block.top
            let rowY = metrics.top + CGFloat(row) * cell + ((cell - side) / 2).rounded()
            let toggleRect = NSRect(x: x1 - 6 - side, y: rowY, width: side, height: side)
            let showsToggle = block.has(Flag.canToggle)
            let copyRect = showsToggle ? toggleRect.offsetBy(dx: -(side + 2), dy: 0) : toggleRect
            items.append(Item(block: block, box: box, copy: copyRect, toggle: showsToggle ? toggleRect : nil))
        }
        updateHover(at: mouseLocation())
    }

    private func mouseLocation() -> NSPoint? {
        guard let window else { return nil }
        let point = convert(window.mouseLocationOutsideOfEventStream, from: nil)
        return bounds.contains(point) ? point : nil
    }

    private func hit(at point: NSPoint) -> Hit? {
        for (index, item) in items.enumerated() where !item.isDeck {
            if item.copy.contains(point) { return Hit(block: index, action: .copy) }
            if let toggle = item.toggle, toggle.contains(point) { return Hit(block: index, action: .toggle) }
        }
        return nil
    }

    private func updateHover(at point: NSPoint?) {
        let nextButton = point.flatMap { hit(at: $0) }
        let nextBlock = point.flatMap { point in items.firstIndex { !$0.isDeck && $0.box.contains(point) } }
        guard nextButton != hover || nextBlock != hoverBlock else { return }
        hover = nextButton
        hoverBlock = nextBlock
        needsDisplay = true
    }

    // MARK: Mouse

    /// Only the buttons take clicks. Everywhere else the terminal underneath gets them.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard let superview else { return nil }
        let local = convert(point, from: superview)
        // An open peek takes the pointer over its own area, so it can be scrolled.
        if let peekView, peekView.frame.contains(local) { return super.hitTest(point) ?? peekView }
        return hit(at: local) == nil ? nil : self
    }

    override func mouseMoved(with event: NSEvent) {
        updateHover(at: convert(event.locationInWindow, from: nil))
    }

    override func mouseExited(with event: NSEvent) {
        updateHover(at: nil)
    }

    override func mouseDown(with event: NSEvent) {
        pressed = hit(at: convert(event.locationInWindow, from: nil))
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        let released = hit(at: convert(event.locationInWindow, from: nil))
        defer {
            pressed = nil
            needsDisplay = true
        }
        guard let released, released == pressed, items.indices.contains(released.block) else { return }
        run(released.action, on: items[released.block].block)
    }

    private func run(_ action: Action, on block: Block) {
        guard let surfaceView, let surface = surfaceView.surface else { return }
        let row = UInt32(max(0, block.head >= 0 ? block.head : block.top))
        switch action {
        case .toggle:
            if peekView != nil, peekHead == block.head {
                closePeek()
            } else if ghostty_surface_block_toggle(surface, row) {
                closePeek()
                wake(now: true)
            } else if !block.has(Flag.folded) || !openPeek(for: block, row: row, surface: surface) {
                NSSound.beep()
            }
        case .copy:
            // The output, or the command itself when it printed nothing.
            let hasOutput = block.has(Flag.hasOutput) || block.has(Flag.folded)
            var text = ghostty_text_s()
            guard ghostty_surface_block_read(surface, row, hasOutput ? 0 : 1, &text) else {
                NSSound.beep()
                return
            }
            defer { ghostty_surface_free_text(surface, &text) }
            SignalText.copy(String(cString: text.text))
            copiedHead = block.head
            needsDisplay = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) { [weak self] in
                self?.copiedHead = nil
                self?.needsDisplay = true
            }
        }
    }

    // MARK: Peek

    private func isPeeking(_ block: Block) -> Bool {
        peekView != nil && peekHead == block.head
    }

    /// Shows a folded block's kept output in a panel by its command line. This is for a
    /// block that cannot be opened in place: rows can only be put back on the screen
    /// itself, not into the scrollback above it. Returns false if there is nothing to show.
    private func openPeek(for block: Block, row: UInt32, surface: ghostty_surface_t) -> Bool {
        var text = ghostty_text_s()
        guard ghostty_surface_block_read(surface, row, 0, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }
        let string = String(cString: text.text)
        let cell = metrics.cellHeight
        guard !string.isEmpty, cell > 0,
              let item = items.first(where: { !$0.isDeck && $0.block.head == block.head }) else { return false }
        closePeek()

        // Under the command line when a good part fits there, else above it.
        let rows = CGFloat(min(max(block.lines, 1), 18))
        let wanted = rows * cell + SignalPeekView.chrome
        let below = bounds.height - item.box.maxY - 10
        let above = item.box.minY - 10
        let least = min(wanted, 5 * cell + SignalPeekView.chrome)
        let height: CGFloat
        let y: CGFloat
        if below >= least || below >= above {
            height = min(wanted, below)
            y = item.box.maxY + 4
        } else {
            height = min(wanted, above)
            y = item.box.minY - 4 - height
        }
        guard height >= 2 * cell + SignalPeekView.chrome else { return false }

        let view = SignalPeekView(
            text: string, lines: block.lines, cellWidth: metrics.cellWidth, cellHeight: cell, colors: colors)
        view.frame = NSRect(x: item.box.minX, y: y.rounded(), width: item.box.width, height: height.rounded())
        addSubview(view)
        peekView = view
        peekHead = block.head
        needsDisplay = true
        return true
    }

    private func closePeek() {
        guard let view = peekView else { return }
        view.removeFromSuperview()
        peekView = nil
        peekHead = -1
        needsDisplay = true
    }

    /// Whether this event means the peek is done with: any key, a click anywhere but on
    /// the peek or a block's buttons (those decide for themselves), or scrolling the
    /// terminal rather than the peek.
    private func putsPeekAway(_ event: NSEvent) -> Bool {
        guard let peekView else { return false }
        switch event.type {
        case .keyDown:
            return true
        case .leftMouseDown, .rightMouseDown, .scrollWheel:
            let point = convert(event.locationInWindow, from: nil)
            if peekView.frame.contains(point) { return false }
            return event.type == .scrollWheel || hit(at: point) == nil
        default:
            return false
        }
    }

    // MARK: Drawing

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        defer { drawPromptMarks() }
        guard !items.isEmpty else { return }
        let line = colors.foreground
        let green = NSColor(srgbRed: 0.37, green: 0.89, blue: 0.66, alpha: 1)

        for (index, item) in items.enumerated() where item.box.insetBy(dx: -24, dy: -24).intersects(dirtyRect) {
            if item.isDeck {
                drawDeck(item.box)
                continue
            }
            let hovered = hoverBlock == index
            let running = item.block.has(Flag.running)

            let box = NSBezierPath(roundedRect: item.box.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
            line.withAlphaComponent(hovered ? 0.034 : 0.018).setFill()
            box.fill()
            let stroke: NSColor
            if running {
                stroke = colors.tint.withAlphaComponent(0.5)
            } else if hovered {
                stroke = (line.withAlphaComponent(0.12).blended(withFraction: 0.45, of: colors.tint) ?? colors.tint)
                    .withAlphaComponent(0.34)
            } else {
                stroke = line.withAlphaComponent(0.1)
            }
            stroke.setStroke()
            box.lineWidth = 1
            box.stroke()
            if item.block.has(Flag.failed) { drawFailure(of: item, outline: box) }
            let picked = isSelected(item.block)
            if picked { drawSelection(of: item, outline: box) }
            drawTags(of: item, picked: picked)
            if flashAmount > 0.01, item.block.head == flashRow {
                drawChange(of: item, outline: box)
            }
            if isPeeking(item.block) {
                colors.tint.withAlphaComponent(0.45).setStroke()
                box.stroke()
            }

            // Under the pointer the buttons get a backing, so text beneath cannot muddle them.
            if hovered {
                let group = item.toggle.map { item.copy.union($0) } ?? item.copy
                colors.background.withAlphaComponent(0.86).setFill()
                NSBezierPath(roundedRect: group.insetBy(dx: -3, dy: 0), xRadius: 6, yRadius: 6).fill()
            }

            let copied = copiedHead == item.block.head
            drawButton(
                Hit(block: index, action: .copy), in: item.copy, hovered: hovered,
                color: copied ? green : line, icon: copied ? .check : .copy)
            if let toggle = item.toggle {
                drawButton(
                    Hit(block: index, action: .toggle), in: toggle, hovered: hovered,
                    color: line, icon: item.block.has(Flag.hasOutput) || isPeeking(item.block) ? .open : .folded)
            }
        }
    }

    /// A command that failed says so on its own block: a red edge down the left, a red
    /// outline, and a tag by the buttons (see `drawTags`). The prompt you type at next
    /// stays as it is; the failure belongs to the command that failed.
    private func drawFailure(of item: Item, outline: NSBezierPath) {
        let red = Ink.red
        red.withAlphaComponent(0.035).setFill()
        outline.fill()
        red.withAlphaComponent(0.42).setStroke()
        outline.stroke()

        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        red.withAlphaComponent(0.9).setFill()
        NSRect(x: item.box.minX, y: item.box.minY, width: 2.5, height: item.box.height).fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// The block picked with the keyboard: outlined and edged in the window's color.
    private func drawSelection(of item: Item, outline: NSBezierPath) {
        let tint = colors.tint
        tint.withAlphaComponent(0.07).setFill()
        outline.fill()
        tint.withAlphaComponent(0.9).setStroke()
        outline.lineWidth = 1.5
        outline.stroke()
        outline.lineWidth = 1
        guard !item.block.has(Flag.failed) else { return }
        NSGraphicsContext.saveGraphicsState()
        outline.addClip()
        tint.setFill()
        NSRect(x: item.box.minX, y: item.box.minY, width: 2.5, height: item.box.height).fill(using: .sourceOver)
        NSGraphicsContext.restoreGraphicsState()
    }

    /// Small tags on the command line, left of the buttons, each on a backing of its own
    /// so a long command under it does not muddle it: that the command failed, and
    /// either that the block was just copied or, while it is picked, how to copy it.
    private func drawTags(of item: Item, picked: Bool) {
        guard item.block.head >= 0 else { return }
        var edge = item.copy.minX - 10
        func tag(_ text: String, _ color: NSColor) {
            let label = smallLabel(text, color: color, kern: 1.4)
            let size = label.safeSize()
            guard size.width > 0 else { return }
            let pill = NSRect(x: edge - size.width - 12, y: item.copy.midY - 8, width: size.width + 12, height: 16)
            guard pill.minX > item.box.minX + 60 else { return }
            let backing = NSBezierPath(roundedRect: pill, xRadius: 4, yRadius: 4)
            colors.background.withAlphaComponent(0.9).setFill()
            backing.fill()
            color.withAlphaComponent(0.14).setFill()
            backing.fill()
            label.safeDraw(at: NSPoint(x: pill.minX + 6.5, y: (pill.midY - size.height / 2).rounded()))
            edge = pill.minX - 6
        }
        if item.block.has(Flag.failed) { tag("FAILED", Ink.red) }
        if copiedHead == item.block.head {
            tag("COPIED TO CLIPBOARD", Ink.green)
        } else if picked {
            tag("CTRL+C COPIES", colors.tint)
        }
    }

    /// The moment after a block is folded or opened.
    ///
    /// Opened: a bright line runs down from the command line to the end of the output,
    /// and the rows it has not reached yet are dimmed, so the output reads as unrolling
    /// out of its command line even though the terminal put it all there at once.
    /// Folded: the single row that is left glows and settles.
    private func drawChange(of item: Item, outline: NSBezierPath) {
        let left = flashAmount
        let tint = colors.tint
        tint.withAlphaComponent((flashOpening ? 0.06 : 0.14) * left).setFill()
        outline.fill()
        tint.withAlphaComponent(0.7 * left).setStroke()
        outline.stroke()

        guard flashOpening, metrics.cellHeight > 0 else { return }
        let start = metrics.top + CGFloat(item.block.head + 1) * metrics.cellHeight
        let end = min(item.box.maxY - 1, bounds.maxY)
        guard end - start > metrics.cellHeight else { return }
        let y = (start + (end - start) * (1 - left)).rounded()
        // The line is at full strength for most of the way and fades out as it arrives.
        let strength = min(1, left * 4)

        NSGraphicsContext.saveGraphicsState()
        defer { NSGraphicsContext.restoreGraphicsState() }
        outline.addClip()
        colors.background.withAlphaComponent(0.6 * left).setFill()
        NSRect(x: item.box.minX, y: y, width: item.box.width, height: end - y + 2).fill(using: .sourceOver)
        let trail = min(28, y - start)
        if trail > 1 {
            NSGradient(starting: tint.withAlphaComponent(0), ending: tint.withAlphaComponent(0.2 * strength))?
                .draw(in: NSRect(x: item.box.minX, y: y - trail, width: item.box.width, height: trail), angle: 90)
        }
        tint.withAlphaComponent(0.9 * strength).setFill()
        NSRect(x: item.box.minX, y: y - 1, width: item.box.width, height: 1).fill(using: .sourceOver)
    }

    /// The command deck: the card around the prompt being typed at. In the focused pane it
    /// carries the window's color (a lit edge, a wash that fades to the right, a bright bar
    /// down its left side) and two small labels set into its top edge. Elsewhere it is a
    /// plain outline. Nothing is drawn around the cursor: the terminal draws that itself.
    private func drawDeck(_ rect: NSRect) {
        let box = rect.insetBy(dx: 0.5, dy: 0.5)
        let path = NSBezierPath(roundedRect: box, xRadius: 9, yRadius: 9)
        guard colors.focused else {
            colors.foreground.withAlphaComponent(0.1).setStroke()
            path.lineWidth = 1
            path.stroke()
            return
        }
        let tint = colors.tint

        // The wash: strongest by the pointer, gone before the right edge.
        NSGraphicsContext.saveGraphicsState()
        path.addClip()
        NSGradient(colorsAndLocations:
            (tint.withAlphaComponent(0.11), 0),
            (tint.withAlphaComponent(0.03), 0.58),
            (tint.withAlphaComponent(0), 1)
        )?.draw(in: box, angle: 0)
        NSGraphicsContext.restoreGraphicsState()

        // Labels sit in gaps in the top edge. The gaps are cut out of the stroke rather
        // than painted over it, so a translucent or blurred window shows through them.
        let font = SignalFont.mono(8.5, .semibold)
        let left = NSAttributedString(string: "CMD", attributes: [.font: font, .foregroundColor: tint, .kern: 1.5])
        let right = NSAttributedString(
            string: "\u{23CE} RUN",
            attributes: [.font: font, .foregroundColor: colors.foreground.withAlphaComponent(0.38), .kern: 1.1])
        let leftSize = left.safeSize()
        let rightSize = right.safeSize()
        let labeled = box.width > leftSize.width + rightSize.width + 90
        let leftNotch = NSRect(x: box.minX + 12, y: box.minY - 6, width: leftSize.width + 22, height: 12)
        let rightNotch = NSRect(
            x: box.maxX - 12 - rightSize.width - 12, y: box.minY - 6, width: rightSize.width + 12, height: 12)

        // The edge, with a soft glow under it.
        NSGraphicsContext.saveGraphicsState()
        if labeled {
            let around = NSBezierPath(rect: rect.insetBy(dx: -40, dy: -40))
            around.appendRect(leftNotch)
            around.appendRect(rightNotch)
            around.windingRule = .evenOdd
            around.addClip()
        }
        let glow = NSShadow()
        glow.shadowColor = tint.withAlphaComponent(0.55)
        glow.shadowBlurRadius = 9
        glow.shadowOffset = .zero
        glow.set()
        (colors.foreground.withAlphaComponent(0.1).blended(withFraction: 0.5, of: tint) ?? tint)
            .withAlphaComponent(0.6).setStroke()
        path.lineWidth = 1
        path.stroke()

        // A bright bar down the left edge and a short one on the bottom edge.
        tint.setFill()
        let inset = min(10, box.height / 4)
        NSBezierPath(
            roundedRect: NSRect(x: box.minX - 0.5, y: box.minY + inset, width: 2, height: box.height - inset * 2),
            xRadius: 1, yRadius: 1).fill()
        NSBezierPath(rect: NSRect(x: box.maxX - 44, y: box.maxY - 0.5, width: 34, height: 1)).fill()
        NSGraphicsContext.restoreGraphicsState()

        guard labeled else { return }
        tint.setFill()
        NSBezierPath(ovalIn: NSRect(x: leftNotch.minX + 6, y: leftNotch.midY - 2.5, width: 5, height: 5)).fill()
        left.safeDraw(at: NSPoint(x: leftNotch.minX + 16, y: leftNotch.midY - leftSize.height / 2))
        right.safeDraw(at: NSPoint(x: rightNotch.minX + 6, y: rightNotch.midY - rightSize.height / 2))
    }

    // MARK: The prompt's graphics

    /// Draws what the Signal prompt leaves cells for. The shell prints only text and marks
    /// where things go; which look to draw comes from those marks, so a shell that has not
    /// yet reached its next prompt is still drawn the way its text was laid out.
    private func drawPromptMarks() {
        guard metrics.cellHeight > 0, metrics.cellWidth > 0 else { return }
        drawCarets()
        guard let live = blocks.first(where: { $0.has(Flag.live) }), live.top >= 0 else { return }
        switch prompt.style {
        case 1: drawRail(live)
        case 2: drawCapsule(live)
        case 3: drawDock(live)
        case 4: drawBrackets(live)
        default: drawCardMarks(live)
        }
    }

    private func rowY(_ row: Int) -> CGFloat { metrics.top + CGFloat(row) * metrics.cellHeight }
    private func colX(_ col: Int) -> CGFloat { metrics.left + CGFloat(col) * metrics.cellWidth }
    /// The left and right edge that boxes in a pane keep to.
    private var edges: (left: CGFloat, right: CGFloat) {
        (max(2, metrics.left - 10), metrics.size.width - max(2, metrics.right - 10))
    }
    /// The prompt's color: the window's, red after a command that failed, plain in a
    /// pane without the keyboard.
    private var accent: NSColor {
        guard colors.focused else { return colors.foreground.withAlphaComponent(0.3) }
        return prompt.failed ? Ink.red : colors.tint
    }
    /// A pane without the keyboard shows its prompt dimmed, as its text is.
    private var dim: CGFloat { colors.focused ? 1 : 0.55 }
    private var pointerCell: (row: Int, col: Int)? {
        prompt.pointerRow >= 0 && prompt.pointerCol >= 0 ? (prompt.pointerRow, prompt.pointerCol) : nil
    }

    private func smallLabel(_ text: String, color: NSColor, kern: CGFloat = 1.4) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: SignalFont.mono(8.5, .semibold),
            .foregroundColor: color, .kern: kern,
        ])
    }

    private func chevron(at origin: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 2.4
        path.move(to: NSPoint(x: origin.x + 2, y: origin.y + 1.5))
        path.line(to: NSPoint(x: origin.x + 7, y: origin.y + 6))
        path.line(to: NSPoint(x: origin.x + 2, y: origin.y + 10.5))
        color.setStroke()
        path.stroke()
    }

    private func arrow(at origin: NSPoint, color: NSColor) {
        let path = NSBezierPath()
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        path.lineWidth = 2.2
        path.move(to: NSPoint(x: origin.x + 1.5, y: origin.y + 6))
        path.line(to: NSPoint(x: origin.x + 12.5, y: origin.y + 6))
        path.move(to: NSPoint(x: origin.x + 8.5, y: origin.y + 1.75))
        path.line(to: NSPoint(x: origin.x + 12.75, y: origin.y + 6))
        path.line(to: NSPoint(x: origin.x + 8.5, y: origin.y + 10.25))
        color.setStroke()
        path.stroke()
    }

    /// The caret that starts every finished command: on the first row of the command
    /// (one typed over several rows has its buttons on the last), red when it failed.
    private func drawCarets() {
        let cell = metrics.cellHeight
        for block in blocks where block.has(Flag.pointer) && block.head >= 0
            && !block.has(Flag.live) && !block.has(Flag.empty) && !block.has(Flag.clippedTop) {
            chevron(
                at: NSPoint(x: metrics.left, y: rowY(block.top) + ((cell - 12) / 2).rounded()),
                color: (block.has(Flag.failed) ? Ink.red : Ink.blue).withAlphaComponent(dim))
        }
    }

    /// An icon in the two cells after a chip's first, in the chip's color.
    /// An icon in a chip's first cell (its mark), with the text one cell after it.
    private func drawTightIcon(for chip: Chip, color: NSColor) {
        let size: CGFloat = 12
        let origin = NSPoint(
            x: colX(chip.start) + 1, y: rowY(chip.row) + ((metrics.cellHeight - size) / 2).rounded())
        drawChipIcon(chip.kind, at: origin, size: size, color: color)
    }

    private func drawChipIcon(for chip: Chip, color: NSColor) {
        let size: CGFloat = 12
        let cell = metrics.cellHeight
        let origin = NSPoint(x: colX(chip.start) + 7, y: rowY(chip.row) + ((cell - size) / 2).rounded())
        drawChipIcon(chip.kind, at: origin, size: size, color: color)
    }

    private func dot(in chip: Chip, color: NSColor) {
        let cell = metrics.cellHeight
        glowingDot(
            at: NSPoint(x: colX(chip.start) + metrics.cellWidth * 1.5, y: rowY(chip.row) + cell / 2), color: color)
    }

    /// The "environment is active" dot: six points across, with a soft halo of its color.
    private func glowingDot(at center: NSPoint, color: NSColor) {
        color.withAlphaComponent(color.alphaComponent * 0.14).setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 5.5, y: center.y - 5.5, width: 11, height: 11)).fill()
        color.setFill()
        NSBezierPath(ovalIn: NSRect(x: center.x - 3, y: center.y - 3, width: 6, height: 6)).fill()
    }

    private func chipColor(_ kind: Int) -> NSColor {
        kind == 2 ? Ink.violet : kind == 3 ? Ink.yellow : Ink.blue
    }

    // MARK: Card

    /// The card look: an outline and an icon for each chip, and the arrow pointer. The
    /// card itself is drawn with the blocks.
    private func drawCardMarks(_ live: Block) {
        let cell = metrics.cellHeight
        let width = metrics.cellWidth
        for chip in prompt.chips where chip.end > chip.start && chip.kind != 4 {
            let color = chipColor(chip.kind)
            let height = min(20, cell - 2)
            let frame = NSRect(
                x: colX(chip.start), y: rowY(chip.row) + ((cell - height) / 2).rounded(),
                width: CGFloat(chip.end - chip.start + 1) * width, height: height)
            let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: 6, yRadius: 6)
            color.withAlphaComponent(0.1 * dim).setFill()
            outline.fill()
            color.withAlphaComponent(0.3 * dim).setStroke()
            outline.lineWidth = 1
            outline.stroke()
            drawChipIcon(for: chip, color: color.withAlphaComponent(dim))
        }
        let at = pointerCell ?? (row: live.head, col: 0)
        let color = colors.focused ? (prompt.failed ? Ink.red : Ink.blue) : colors.foreground.withAlphaComponent(0.4)
        arrow(at: NSPoint(x: colX(at.col) + 1, y: rowY(at.row) + ((cell - 12) / 2).rounded()), color: color)
    }

    // MARK: Breadcrumb Rail

    /// No box. A rail in the window's color runs down the left and ends in a node on the
    /// line you type on; a hairline closes the prompt underneath.
    private func drawRail(_ live: Block) {
        let cell = metrics.cellHeight
        let top = rowY(live.top)
        let typed = rowY(live.bottom)
        let middle = typed + cell / 2
        let x = metrics.left + 6

        // The rail, fading in from the top, and the node it ends in.
        if live.bottom > live.top {
            let rail = NSRect(x: x - 1, y: top + 4, width: 2, height: max(0, middle - 8 - top - 4))
            // This view is flipped, so 90 degrees runs from the top down.
            NSGradient(starting: accent.withAlphaComponent(0.15), ending: accent)?
                .draw(in: NSBezierPath(roundedRect: rail, xRadius: 1, yRadius: 1), angle: 90)
        }
        let node = NSBezierPath(ovalIn: NSRect(x: x - 6, y: middle - 6, width: 12, height: 12))
        node.lineWidth = 2
        accent.setStroke()
        node.stroke()

        // The pointer: two chevrons, the second the brighter.
        if let at = pointerCell {
            let origin = NSPoint(x: colX(at.col), y: rowY(at.row) + ((cell - 12) / 2).rounded())
            chevron(at: origin, color: accent.withAlphaComponent(0.7))
            chevron(at: NSPoint(x: origin.x + 7, y: origin.y), color: accent)
        }

        for chip in prompt.chips {
            // The branch icon in its mark's cell, a point in; the environment's dot in
            // the middle of its two marks.
            if chip.kind == 2 { drawTightIcon(for: chip, color: Ink.violet.withAlphaComponent(dim)) }
            if chip.kind == 3 {
                glowingDot(
                    at: NSPoint(x: colX(chip.start) + metrics.cellWidth, y: rowY(chip.row) + cell / 2),
                    color: Ink.green.withAlphaComponent(dim))
            }
        }

        // The hairline, with a short lit start in the focused pane.
        let line = NSRect(x: colX(2), y: (typed + cell).rounded() + 3, width: max(0, edges.right - colX(2)), height: 1)
        colors.foreground.withAlphaComponent(0.085).setFill()
        line.fill(using: .sourceOver)
        if colors.focused {
            NSGradient(starting: accent, ending: accent.withAlphaComponent(0))?
                .draw(in: NSRect(x: line.minX, y: line.minY, width: min(110, line.width), height: 1), angle: 0)
        }
    }

    // MARK: Command Capsule

    /// One row inside a capsule. The round badge at its head is the environment when one
    /// is active and the directory otherwise; a key cap closes the row.
    private func drawCapsule(_ live: Block) {
        let cell = metrics.cellHeight
        let row = live.bottom
        let frame = NSRect(
            x: edges.left, y: rowY(row) - 7, width: edges.right - edges.left, height: cell + 14)
        let radius = frame.height / 2
        let outline = NSBezierPath(roundedRect: frame.insetBy(dx: 0.5, dy: 0.5), xRadius: radius, yRadius: radius)
        colors.foreground.withAlphaComponent(0.028).setFill()
        outline.fill()
        if colors.focused {
            // The edge is brightest at the head of the capsule and eases off along it.
            // It is painted as a ring (the capsule less a capsule one point smaller), so
            // the light can fade smoothly.
            let ring = NSBezierPath(roundedRect: frame, xRadius: radius, yRadius: radius)
            ring.appendRoundedRect(frame.insetBy(dx: 1, dy: 1), xRadius: radius - 1, yRadius: radius - 1)
            ring.windingRule = .evenOdd
            NSGraphicsContext.saveGraphicsState()
            ring.addClip()
            NSGradient(colorsAndLocations:
                (accent, 0), (accent.withAlphaComponent(0.3), 0.4), (accent.withAlphaComponent(0.3), 1)
            )?.draw(in: frame, angle: 0)
            NSGraphicsContext.restoreGraphicsState()
        } else {
            outline.lineWidth = 1
            accent.withAlphaComponent(0.5).setStroke()
            outline.stroke()
        }

        for chip in prompt.chips where chip.row == row {
            switch chip.kind {
            case 1, 3:
                // The badge, at the capsule's head: as far from its end as from its top.
                let size = min(30, frame.height - 10)
                let center = NSPoint(x: frame.minX + frame.height / 2, y: rowY(row) + cell / 2)
                let fill = !colors.focused ? colors.foreground.withAlphaComponent(0.3)
                    : prompt.failed ? Ink.red : chip.kind == 3 ? Ink.yellow : colors.tint
                fill.setFill()
                NSBezierPath(ovalIn: NSRect(
                    x: center.x - size / 2, y: center.y - size / 2, width: size, height: size)).fill()
                drawChipIcon(
                    chip.kind, at: NSPoint(x: center.x - 7, y: center.y - 7), size: 14, color: colors.background)
            case 2:
                drawTightIcon(for: chip, color: Ink.violet.withAlphaComponent(dim))
            case 4:
                // The return key, as a key cap at the capsule's tail: as far from its end
                // as from its top. (The cells the shell keeps free are where it stands.)
                let inset = (frame.height - 26) / 2
                let cap = NSRect(x: frame.maxX - inset - 34, y: frame.minY + inset, width: 34, height: 26)
                let path = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 13, yRadius: 13)
                colors.foreground.withAlphaComponent(0.03).setFill()
                path.fill()
                colors.foreground.withAlphaComponent(0.14).setStroke()
                path.lineWidth = 1
                path.stroke()
                let key = NSAttributedString(string: "\u{23CE}", attributes: [
                    .font: SignalFont.system(11, .regular),
                    .foregroundColor: colors.foreground.withAlphaComponent(0.5),
                ])
                let size = key.safeSize()
                key.safeDraw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2))
            default:
                break
            }
        }
        if let at = pointerCell {
            chevron(at: NSPoint(x: colX(at.col), y: rowY(at.row) + ((cell - 12) / 2).rounded()), color: accent)
        }
    }

    // MARK: Tabbed Dock

    /// The row you type on is a dock; the chips above it are tabs on the dock's top edge,
    /// built like the session tabs. The first tab is lit and joins the dock.
    private func drawDock(_ live: Block) {
        let cell = metrics.cellHeight
        let width = metrics.cellWidth
        let typed = live.bottom
        // The dock takes the row that is typed on and the same margin above and below
        // it, so the text sits in its middle. The tabs take the row above, less that
        // margin at each end, so their text sits in their middle too.
        let margin: CGFloat = 3
        let dock = NSRect(
            x: edges.left, y: rowY(typed) - margin, width: edges.right - edges.left, height: cell + margin * 2)
        let edge = colors.focused ? accent.withAlphaComponent(0.45) : colors.foreground.withAlphaComponent(0.14)

        // The dock: square at its top-left, where the lit tab stands on it.
        let box = dock.insetBy(dx: 0.5, dy: 0.5)
        let shape = NSBezierPath()
        shape.move(to: NSPoint(x: box.minX, y: box.minY))
        shape.appendArc(from: NSPoint(x: box.maxX, y: box.minY), to: NSPoint(x: box.maxX, y: box.maxY), radius: 10)
        shape.appendArc(from: NSPoint(x: box.maxX, y: box.maxY), to: NSPoint(x: box.minX, y: box.maxY), radius: 10)
        shape.appendArc(from: NSPoint(x: box.minX, y: box.maxY), to: NSPoint(x: box.minX, y: box.minY), radius: 10)
        shape.close()
        if colors.focused {
            NSGraphicsContext.saveGraphicsState()
            shape.addClip()
            NSGradient(starting: accent.withAlphaComponent(0.1), ending: accent.withAlphaComponent(0.02))?
                .draw(in: box, angle: 90)
            NSGraphicsContext.restoreGraphicsState()
        }

        // Tabs. Each is open at the bottom; the lit one also takes the dock's fill.
        var lit: NSRect?
        for chip in prompt.chips where chip.row < typed && chip.kind != 4 {
            let first = chip.kind == 1
            let left = first ? dock.minX : colX(chip.start)
            // The first tab starts at the dock's edge, which is further out than the
            // text, so it gets as much room after its text as it has before its icon.
            let right = colX(chip.end + 1) + (first ? 6 : 4.5)
            let tab = NSRect(
                x: left, y: rowY(chip.row) + margin, width: right - left,
                height: dock.minY - rowY(chip.row) - margin)
            let inset = tab.insetBy(dx: 0.5, dy: 0)
            let path = NSBezierPath()
            path.move(to: NSPoint(x: inset.minX, y: inset.maxY))
            path.appendArc(from: NSPoint(x: inset.minX, y: inset.minY + 0.5), to: NSPoint(x: inset.maxX, y: inset.minY + 0.5), radius: 7)
            path.appendArc(from: NSPoint(x: inset.maxX, y: inset.minY + 0.5), to: NSPoint(x: inset.maxX, y: inset.maxY), radius: 7)
            path.line(to: NSPoint(x: inset.maxX, y: inset.maxY))
            let fill = NSBezierPath()
            fill.append(path)
            fill.close()
            if first && colors.focused {
                accent.withAlphaComponent(0.1).setFill()
                fill.fill()
                edge.setStroke()
                lit = tab
            } else {
                colors.foreground.withAlphaComponent(0.02).setFill()
                fill.fill()
                colors.foreground.withAlphaComponent(0.09).setStroke()
            }
            path.lineWidth = 1
            path.stroke()
            switch chip.kind {
            case 3: dot(in: chip, color: Ink.green.withAlphaComponent(dim))
            case 2: drawChipIcon(for: chip, color: Ink.violet.withAlphaComponent(dim))
            default:
                // In the first tab the icon sits over the two cells before the text.
                let color = (colors.focused ? Ink.blue : colors.foreground).withAlphaComponent(dim)
                if first {
                    drawChipIcon(
                        chip.kind,
                        at: NSPoint(x: colX(chip.start) - 3, y: rowY(chip.row) + ((cell - 12) / 2).rounded()),
                        size: 12, color: color)
                } else {
                    drawChipIcon(for: chip, color: color)
                }
            }
        }

        // The dock's edge, left open under the lit tab so the two read as one shape.
        NSGraphicsContext.saveGraphicsState()
        if let lit {
            let around = NSBezierPath(rect: dock.insetBy(dx: -20, dy: -20))
            around.appendRect(NSRect(x: lit.minX + 1, y: dock.minY - 1, width: lit.width - 2, height: 2.5))
            around.windingRule = .evenOdd
            around.addClip()
        }
        edge.setStroke()
        shape.lineWidth = 1
        shape.stroke()
        NSGraphicsContext.restoreGraphicsState()

        // "READY", small, at the dock's right end, where the shell keeps cells free.
        if prompt.chips.contains(where: { $0.kind == 4 && $0.row == typed }) {
            let label = smallLabel("READY", color: colors.foreground.withAlphaComponent(0.3 * dim), kern: 1.4)
            let size = label.safeSize()
            let x = dock.maxX - 12 - size.width
            label.safeDraw(at: NSPoint(x: x, y: (dock.midY - size.height / 2).rounded()))
            Ink.green.withAlphaComponent(dim).setFill()
            NSBezierPath(ovalIn: NSRect(x: x - 12, y: dock.midY - 3, width: 6, height: 6)).fill()
        }

        // The pointer: a solid tile with the arrow cut out of it.
        if let at = pointerCell {
            // Three cells wide, with the text starting on the fifth: about as much room
            // between the tile and the text as between the tile and the dock's edge.
            let tile = NSRect(x: colX(at.col), y: rowY(at.row) + ((cell - 22) / 2).rounded(), width: max(24, width * 3), height: 22)
            accent.setFill()
            NSBezierPath(roundedRect: tile, xRadius: 6, yRadius: 6).fill()
            arrow(at: NSPoint(x: tile.midX - 7.5, y: tile.midY - 6), color: colors.background)
        }
    }

    // MARK: HUD Brackets

    /// No fill and no box: four corner brackets, as on the focused pane, a label and a
    /// meter on the top edge, and a color bar and label before each tag.
    private func drawBrackets(_ live: Block) {
        let cell = metrics.cellHeight
        let frame = NSRect(
            x: edges.left, y: rowY(live.top) - 8, width: edges.right - edges.left,
            height: rowY(live.bottom) + cell + 7 - (rowY(live.top) - 8))
        let box = frame.insetBy(dx: 1, dy: 1)
        let arm: CGFloat = 11
        let corners = NSBezierPath()
        corners.lineWidth = 2
        corners.lineCapStyle = .round
        corners.lineJoinStyle = .round
        for (corner, dx, dy) in [
            (NSPoint(x: box.minX, y: box.minY), arm, arm), (NSPoint(x: box.maxX, y: box.minY), -arm, arm),
            (NSPoint(x: box.minX, y: box.maxY), arm, -arm), (NSPoint(x: box.maxX, y: box.maxY), -arm, -arm),
        ] {
            corners.move(to: NSPoint(x: corner.x + dx, y: corner.y))
            corners.appendArc(from: corner, to: NSPoint(x: corner.x, y: corner.y + dy), radius: 4)
            corners.line(to: NSPoint(x: corner.x, y: corner.y + dy))
        }
        accent.setStroke()
        corners.stroke()

        // The label on the top edge, with a small meter before it.
        let heights: [CGFloat] = [4, 8, 5, 9]
        accent.setFill()
        for (index, height) in heights.enumerated() {
            NSRect(x: box.minX + 24 + CGFloat(index) * 4, y: box.minY + 4 - height, width: 2, height: height)
                .fill(using: .sourceOver)
        }
        let title = smallLabel(prompt.failed ? "FAILED" : "INPUT", color: accent, kern: 1.6)
        title.safeDraw(at: NSPoint(x: box.minX + 46, y: box.minY - title.safeSize().height / 2 - 1))

        // Each tag: a color bar in its first cell, a small label in the cells after it.
        for chip in prompt.chips {
            let y = rowY(chip.row)
            if chip.kind == 4 {
                // Key hints, set against the right end of the room left for them.
                let hint = NSMutableAttributedString()
                hint.append(smallLabel("\u{21B5}", color: colors.foreground.withAlphaComponent(0.55 * dim)))
                hint.append(smallLabel(" RUN   ", color: colors.foreground.withAlphaComponent(0.3 * dim)))
                hint.append(smallLabel("\u{21E5}", color: colors.foreground.withAlphaComponent(0.55 * dim)))
                hint.append(smallLabel(" COMPLETE", color: colors.foreground.withAlphaComponent(0.3 * dim)))
                let size = hint.safeSize()
                // Against the frame's right side, with the room the tags have on the left.
                hint.safeDraw(at: NSPoint(x: box.maxX - 16 - size.width, y: y + (cell - size.height) / 2))
                continue
            }
            let color = colors.focused ? chipColor(chip.kind) : colors.foreground.withAlphaComponent(0.3)
            color.setFill()
            NSBezierPath(
                roundedRect: NSRect(x: colX(chip.start) + 2, y: y + ((cell - 13) / 2).rounded(), width: 3, height: 13),
                xRadius: 1, yRadius: 1).fill()
            let name = smallLabel(
                chip.kind == 2 ? "GIT" : chip.kind == 3 ? "ENV" : "DIR",
                color: colors.foreground.withAlphaComponent(0.34 * dim))
            name.safeDraw(at: NSPoint(x: colX(chip.start) + 10, y: y + (cell - name.safeSize().height) / 2))
        }

        // The pointer: a solid triangle.
        if let at = pointerCell {
            let origin = NSPoint(x: colX(at.col), y: rowY(at.row) + ((cell - 11) / 2).rounded())
            let triangle = NSBezierPath()
            triangle.move(to: origin)
            triangle.line(to: NSPoint(x: origin.x + 8, y: origin.y + 5.5))
            triangle.line(to: NSPoint(x: origin.x, y: origin.y + 11))
            triangle.close()
            accent.setFill()
            triangle.fill()
        }

        // A short scan mark on the bottom edge.
        if colors.focused {
            NSGradient(colors: [accent.withAlphaComponent(0), accent, accent.withAlphaComponent(0)])?
                .draw(in: NSRect(x: box.minX + 14, y: box.maxY - 0.5, width: min(120, box.width - 28), height: 1), angle: 0)
        }
    }

    /// A chip's icon (a folder, a git branch, a package), drawn on a 16-point grid.
    private func drawChipIcon(_ kind: Int, at origin: NSPoint, size: CGFloat, color: NSColor) {
        let unit = size / 16
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        let path = NSBezierPath()
        path.lineWidth = 1.2
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch kind {
        case 2:
            for center in [point(4.5, 3.5), point(4.5, 12.5), point(11.5, 5.5)] {
                let radius = 1.5 * unit
                path.appendOval(in: NSRect(
                    x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2))
            }
            path.move(to: point(4.5, 5))
            path.line(to: point(4.5, 11))
            path.move(to: point(11.5, 7))
            path.curve(to: point(4.5, 10.6), controlPoint1: point(11.5, 9.6), controlPoint2: point(8.3, 9.4))
        case 3:
            path.move(to: point(8, 1.75))
            path.line(to: point(13.5, 4.85))
            path.line(to: point(13.5, 11.15))
            path.line(to: point(8, 14.25))
            path.line(to: point(2.5, 11.15))
            path.line(to: point(2.5, 4.85))
            path.close()
            path.move(to: point(2.5, 4.85))
            path.line(to: point(8, 8))
            path.line(to: point(13.5, 4.85))
            path.move(to: point(8, 8))
            path.line(to: point(8, 14.25))
        default:
            let radius = 1.5 * unit
            path.move(to: point(1.75, 4.5))
            path.appendArc(from: point(1.75, 3), to: point(3.25, 3), radius: radius)
            path.line(to: point(6.25, 3))
            path.line(to: point(7.75, 4.75))
            path.line(to: point(12.75, 4.75))
            path.appendArc(from: point(14.25, 4.75), to: point(14.25, 6.25), radius: radius)
            path.appendArc(from: point(14.25, 13.25), to: point(12.75, 13.25), radius: radius)
            path.appendArc(from: point(1.75, 13.25), to: point(1.75, 11.75), radius: radius)
            path.close()
        }
        color.setStroke()
        path.stroke()
    }

    private enum Icon { case copy, check, folded, open }

    private func drawButton(_ button: Hit, in rect: NSRect, hovered: Bool, color: NSColor, icon: Icon) {
        let over = hover == button
        if over {
            color.withAlphaComponent(pressed == button ? 0.16 : 0.09).setFill()
            NSBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6).fill()
        }
        let alpha: CGFloat = icon == .check ? 1 : over ? 0.95 : hovered ? 0.6 : 0.3
        color.withAlphaComponent(alpha).setStroke()

        // Icons are drawn on a 16-point grid, scaled to 13 points and centered.
        let size: CGFloat = 13
        let unit = size / 16
        let origin = NSPoint(x: rect.midX - size / 2, y: rect.midY - size / 2)
        func point(_ x: CGFloat, _ y: CGFloat) -> NSPoint {
            NSPoint(x: origin.x + x * unit, y: origin.y + y * unit)
        }
        let path = NSBezierPath()
        path.lineWidth = 1.3
        path.lineCapStyle = .round
        path.lineJoinStyle = .round
        switch icon {
        case .copy:
            path.appendRoundedRect(
                NSRect(origin: point(5.5, 5.5), size: CGSize(width: 8.25 * unit, height: 8.25 * unit)),
                xRadius: 2 * unit, yRadius: 2 * unit)
            path.move(to: point(10.5, 5.25))
            path.appendArc(from: point(10.5, 2.25), to: point(2.25, 2.25), radius: 1.5 * unit)
            path.appendArc(from: point(2.25, 2.25), to: point(2.25, 10.5), radius: 1.5 * unit)
            path.appendArc(from: point(2.25, 10.5), to: point(5.25, 10.5), radius: 1.5 * unit)
            path.line(to: point(5.25, 10.5))
        case .check:
            path.move(to: point(3, 8.5))
            path.line(to: point(6.2, 11.7))
            path.line(to: point(13, 4.8))
        case .folded:
            path.move(to: point(6, 3.5))
            path.line(to: point(10.5, 8))
            path.line(to: point(6, 12.5))
        case .open:
            path.move(to: point(3.5, 6))
            path.line(to: point(8, 10.5))
            path.line(to: point(12.5, 6))
        }
        path.stroke()
    }
}


/// A folded block's output, shown over the pane by its command line.
///
/// Folded output is normally put back into the terminal itself. That cannot be done once
/// the command line has scrolled up into the scrollback, so there the kept text is shown
/// in this panel instead: plain text in the terminal's line height, scrollable, nothing
/// else. It takes no keyboard focus; the terminal keeps it.
private final class SignalPeekView: NSView {
    private static let caption: CGFloat = 22
    private static let inset: CGFloat = 5
    /// Height the panel needs beyond its rows of text.
    static let chrome: CGFloat = caption + inset * 2 + 4

    private let scroll = NSScrollView()
    private let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: 200, height: 20))
    private let tint: NSColor
    private let ink: NSColor
    private let fill: NSColor
    private let note: String
    private var placed = false

    init(text: String, lines: Int, cellWidth: CGFloat, cellHeight: CGFloat, colors: SignalBlockView.Colors) {
        tint = colors.tint
        ink = colors.foreground
        fill = colors.background
        note = (lines == 1 ? "1 LINE" : "\(lines) LINES") + "  \u{00B7}  SCROLLED AWAY, SHOWN HERE"
        super.init(frame: .zero)
        wantsLayer = true
        layer?.shadowColor = NSColor.black.cgColor
        layer?.shadowOpacity = 0.5
        layer?.shadowRadius = 12
        layer?.shadowOffset = .zero

        // Very long output is cut for the panel. Copy still takes all of it.
        var shown = text
        let limit = 2000
        var count = 0
        if let cut = text.firstIndex(where: { character in
            if character == "\n" { count += 1 }
            return count >= limit
        }) {
            shown = String(text[..<cut]) + "\n\u{2026} the rest is not shown here. Copy takes all of it."
        }

        let paragraph = NSMutableParagraphStyle()
        paragraph.minimumLineHeight = cellHeight
        paragraph.maximumLineHeight = cellHeight
        paragraph.lineBreakMode = .byCharWrapping
        // A monospaced letter is six tenths of its font's size wide. Sized from the
        // terminal's cell, the text sets at the terminal's own columns.
        let size = min(max((cellWidth / 0.6 * 4).rounded() / 4, 8), 32)

        textView.isEditable = false
        textView.isSelectable = false
        textView.isRichText = false
        textView.drawsBackground = false
        textView.textContainerInset = NSSize(width: 4, height: Self.inset)
        textView.minSize = .zero
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.layoutManager?.allowsNonContiguousLayout = true
        textView.textStorage?.setAttributedString(NSAttributedString(string: shown, attributes: [
            .font: SignalFont.mono(size),
            .foregroundColor: colors.foreground.withAlphaComponent(0.9),
            .paragraphStyle: paragraph,
        ]))

        scroll.documentView = textView
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = false
        scroll.autohidesScrollers = true
        scroll.scrollerStyle = .overlay
        addSubview(scroll)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    override func layout() {
        super.layout()
        scroll.frame = NSRect(
            x: 1, y: Self.caption, width: max(0, bounds.width - 2),
            height: max(0, bounds.height - Self.caption - 4))
        textView.setFrameSize(NSSize(width: scroll.contentSize.width, height: textView.frame.height))
        // It opens at the first line, like the output it stands in for.
        if !placed, bounds.height > 0 {
            placed = true
            textView.layoutManager?.ensureLayout(forCharacterRange: NSRange(location: 0, length: 0))
            scroll.contentView.scroll(to: .zero)
            scroll.reflectScrolledClipView(scroll.contentView)
        }
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width >= 2, bounds.height >= 2 else { return }  // see RoundedTerminalTabBar.draw
        let box = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 8, yRadius: 8)
        // Solid: the terminal's own text is right behind it.
        fill.withAlphaComponent(1).setFill()
        box.fill()
        tint.withAlphaComponent(0.05).setFill()
        box.fill()
        tint.withAlphaComponent(0.5).setStroke()
        box.lineWidth = 1
        box.stroke()

        let font = SignalFont.mono(8.5, .semibold)
        let tag = NSAttributedString(string: "PEEK", attributes: [.font: font, .foregroundColor: tint, .kern: 1.5])
        let detail = NSAttributedString(string: note, attributes: [
            .font: font, .foregroundColor: ink.withAlphaComponent(0.42), .kern: 1.1,
        ])
        let hint = NSAttributedString(string: "ESC", attributes: [
            .font: font, .foregroundColor: ink.withAlphaComponent(0.3), .kern: 1.1,
        ])
        let tagSize = tag.safeSize()
        let hintSize = hint.safeSize()
        let y = ((Self.caption - tagSize.height) / 2).rounded() + 1
        tag.safeDraw(at: NSPoint(x: 12, y: y))
        if bounds.width > 360 {
            detail.safeDraw(at: NSPoint(x: 12 + tagSize.width + 12, y: y))
        }
        hint.safeDraw(at: NSPoint(x: bounds.width - 12 - hintSize.width, y: y))
        ink.withAlphaComponent(0.08).setFill()
        NSRect(x: 1, y: Self.caption - 1, width: bounds.width - 2, height: 1).fill(using: .sourceOver)
    }
}
