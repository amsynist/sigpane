# Ghostty X

A macOS appearance fork based on `amsynist/ghostty-X` at e95bed633. The terminal engine remains Ghostty. The visual reference is the owner's OmniVM-X terminal: compact tabs aligned left, rounded split panes, six-point gutters and a blue focus outline. The UI implementation is written independently using native AppKit tab controls and SwiftUI split views; no OmniWM source or window-management dependency is included.

## Changes

- With `macos-titlebar-style = tabs` on macOS 26+, a custom tab strip replaces the native tab strip's visible contents within its existing titlebar accessory. Native AppKit tab groups still own windows, selection and restoration.
- Tabs support selection, close confirmation, rename, tab colors, drag reordering within a group, context menu movement and moving to a new window. Overflow scrolls horizontally and the selected tab is revealed. Keyboard bindings come from the existing Ghostty configuration.
- Split panes have eight-point corners, six-point gutters, and a focus outline. The existing terminal surfaces, drag/drop zones, split tree, zoom and equalize actions are retained. Divider geometry accounts for the entire gap and drag resizing uses translation to avoid jumps.
- The app bundle is `GhosttyX.app` (`com.amsynist.ghosttyx`) so the official application remains separate. The executable and Swift module keep their upstream names. Existing Ghostty configuration is reused. No custom user config, signing keys or terminal history belongs in this repository.
- macOS 13–15 retains upstream tab appearance. No private terminal engine APIs or additional dependency were introduced. Titlebar attachment uses the existing upstream AppKit hierarchy integration.

## Build

Read `AGENTS.md`, `macos/AGENTS.md` and `HACKING.md` first. This revision pins Zig 0.17.0. Use that exact compiler, Xcode with the Metal Toolchain, and Nushell:

```sh
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
macos/build.nu --configuration ReleaseLocal --arch arm64
macos/build.nu --configuration ReleaseLocal --arch arm64 --action test
```

The `--arch arm64` option matches the native-only framework; omit it when building a universal framework.

The release-optimized local app is `macos/build/ReleaseLocal/GhosttyX.app`. `ReleaseLocal` uses upstream local build signing; distributing or installing a trusted custom build requires explicit signing and validation. Building does not replace or quit an installed terminal. The development toolchain and local build logs are excluded using `.git/info/exclude`.

## Review and validation

See `macos/Tests/Splits/SplitViewGeometryTests.swift` and `macos/Tests/RoundedTerminalTabModelTests.swift` for focused coverage. Run the native test suite and lint the changed Swift files. Runtime checks should cover tabs, close warnings, overflow, drag reorder, detach, splits, resize, zoom, fullscreen and restored sessions. A successful compile is not evidence of those manual checks.

AI assistance: OpenAI Codex implemented this custom appearance and its focused tests at the owner's request. This is work in a personal fork, not a submitted upstream contribution.

## Current validation

- Release-optimized Apple Silicon core and `ReleaseLocal` macOS app builds succeeded with Xcode 27.2 and Zig 0.17.0.
- Native suite: 299 passed, one skipped, zero failures (300 tests, including parameterized runs). UI automation is skipped by the upstream runner.
- Strict SwiftLint passed on all six changed/new Swift source and test files; `git diff --check` passed.
- The built CLI reports the expected fork revision and validates the existing user configuration.
- The actual tab component was rendered offscreen with synthetic titles and visually inspected. Pane geometry and native group reorder/detach have automated coverage.
- The local app was signed using the certificate/key from OmniVM-X's ignored `.signing` folder, via a temporary keychain following its rebuild procedure. Deep, strict bundle signature verification passed. The original user keychain search list was restored and temporary key material removed. No signing key or certificate was copied into this repository. This is local signing, not notarization.
- Local signing helper, build logs, result summary and synthetic tab preview are in ignored `.local/`. Rebuilding replaces the signature using upstream build settings; re-sign using the local helper afterward.
- The user quit stock Ghostty, then the signed build was installed at `/Applications/Ghostty.app`. The complete stock bundle was retained in the user’s local terminal-backup directory. The existing Zera launcher path was verified; the active OmniWM rule now assigns the fork’s bundle ID to workspace 2. Full real-window validation (fullscreen, restoration, tab close confirmation, overflow, splits and physical keyboard shortcuts) remains unverified.

## Tab mouse-input correction

The first header used a draggable hosting view and SwiftUI button/drag recognizers in AppKit's titlebar. The corrected strip uses non-draggable native AppKit controls with first-click handling and stable per-window controls. Native inline title editing is bypassed for this custom strip so a rapid double-click cannot focus an invisible editor over the hidden stock tabs. Native double-click rename and context menus belong to the visible tab controls. Published tab snapshots now lay out new controls directly, without reading the previous model value during its `willSet` notification.

Two additional native fixture tests dispatch mouse events through the titlebar window: selecting another tab, and selecting a newly added tab above split content after resizing. The final suite passes 299 tests with one skip. These are disposable fixtures; physical mouse/trackpad behavior in the installed terminal still requires a user check.

The mouse-input correction has been installed at `/Applications/Ghostty.app` after the user quit the previous copy. Its executable hash matches the tested build and deep signature verification passed. The preceding custom build is retained in the local terminal-backup directory. Physical click confirmation is pending.

## Tab click z-order fix

Root cause of tabs not switching on physical clicks: whenever the selected tab changes, AppKit re-inserts its native `NSTabBar` as the last (frontmost) subview of the shared titlebar accessory view, above the rounded strip. The native bar was only made invisible with `alpha = 0`, but `NSTabBar` still hit-tests while transparent (and even while `isHidden`), so after the first switch every click landed on an invisible native tab button at a different x position (or on the `+`). An in-app trace confirmed it: the first click hit `RoundedTabCell`, later ones hit `NSTabButton`/`NSTextField` inside `NSTabBar`.

`TitlebarTabsTahoeTerminalWindow` now keeps the rounded strip frontmost with an in-place `sortSubviews` (constraints survive) on `becomeMain`, tab-bar setup, and right before AppKit hit-tests every mouse-down in `sendEvent`. A traced run of 10 scripted clicks across three tabs (two with splits) plus the `+` button switched correctly every time. `ProductionTabTitlebarTests` now also clicks back to the first tab after a switch. Installed at `/Applications/Ghostty.app`; the prior build is in the terminal-backup directory.

## Theme-matched tab gradients

Tabs take their colors from the active Ghostty config (palette 4 → 5 accent gradient, `foreground` for text; Tokyo Night fallback) and update on config reload. The selected tab is a rounded pill with a blue→magenta wash, gradient hairline border, top sheen and gradient underline; hover adds a neutral wash. Selection and hover fade over 0.18s via animatable `selectAmount`/`hoverAmount`. User tab colors keep their own underline. Previewed offscreen with the real component before install.

## Signal interface

The Signal design restyles the custom chrome after `docs/previews/signal-interface.html`. It is the default look (`TabBarSettings.design`); choose Classic in the Tab Bar settings to get the capsule strip back. Every part has its own switch in the settings window.

- Sidebar (tab bar on the left or right): 54-point session cards with a numbered tile in the tab's color, the title, and the focused pane's directory. A highlight with a slight overshoot slides between cards on selection (`TabSelectionIndicator`). A tab opened in the last 1.2 seconds fades in with a color sweep while its title "decodes". The dashed row reads "New session", and the foot of the bar shows the 1-minute load average as a sparkline.
- Tint: the selection, focus outline, trace, status line and titlebar capsule take the selected tab's color (`RoundedTabTheme.signal(for:settings:)`), or the accent when "Tint follows the selected tab" is off.
- Panes: every pane is framed, a lone or zoomed one included, with an 8-point gap and 10-point corners (both adjustable). Each has a 24-point header with its letter, title, directory and size in cells, plus split and close buttons on hover. The focused pane gets a tinted outline, a soft glow, corner brackets and a sweep when it takes focus. Hovering a split divider lights a small handle.
- Trace: with the bar on the left, `SignalTraceView` draws a line from the selected card along the gutter to the focused pane, masked by the panes so it only shows in the gaps, with a pulse travelling along it.
- Status line: a 24-point strip under the terminal with the focused pane's title, which pane has focus, its size and the time.
- Titlebar (tabs not at the top, two or more tabs): the title becomes a capsule with the tab's number, title and directory, and three buttons at the trailing end split right, split down and open the command palette.

### Second pass

- Every position: top and bottom strips draw Signal chips (numbered tile and title) with the same sliding highlight, marked by a bar under the selected chip. The trace runs from the selected tab to the focused pane for left, right, top and bottom.
- Selection animation: each tab is its own window with its own strip, so strips share the latest selection change per tab group (`selectionHistory`). The strip that comes forward starts its highlight at the previously selected tab and slides to the new one, and the terminal fades and slides in (`playTabTransition`).
- Collapsible sidebar: the button in the sidebar header (or the bar's context menu) shrinks a Signal sidebar to its 58-point column of numbered tiles. The change slides when animations are on.
- Commands: `ghostty_surface_read_command` (new, in `src/apprt/embedded.zig` and `include/ghostty.h`) reads a command's output or command line through shell integration's prompt marks. The pane header uses it for "copy the last command's output" and for a Recent commands list: each command folded to one line with its line count and first line, unfoldable, with a copy button per command. The core library must be rebuilt for this.
- Cost: tabs that are not on screen stop their clock and load timers and their trace animation, and skip the per-update sync. Timers carry tolerance. The pane header subscribes to the title, directory and size instead of observing the whole surface, which publishes on every pointer move. The command list keeps only previews and reads full text on demand.

Not part of this change: prompt chips and transient prompts belong to the shell prompt. Folding output in place, inside the scrolling terminal grid, needs row hiding in the core renderer; the Recent commands list is the folded view for now. `docs/signal/` has a matching color theme and config lines to copy into the Ghostty config by hand.

Validation: the first pass compiled and linked in a `ReleaseLocal` build on 2026-11-20. The second pass was written without a macOS toolchain: the Swift passes a syntax parse and the Zig passes `zig ast-check` and `zig fmt --check` with Zig 0.17.0, but neither has been compiled. Nothing here has been linted, and the native test suite has not been run against it.

### Command blocks, folding and the Signal prompt

Every command and its output is one block. The app draws a box around each block in view, with
a copy button and a fold chevron on the command line. Copy takes the output whether it is
showing or folded (or the command itself when it printed nothing).

- **Where the blocks come from.** Shell integration (OSC 133) marks prompt rows, so
  `src/terminal/fold.zig` can say which rows each command covers. `ghostty_surface_blocks`
  returns the blocks in view; it reads only the rows in view. `SignalBlockView`
  (`TerminalSplitTreeView.swift`) draws over them. It sits beside the surface view and only its
  buttons take clicks. It asks 60 times a second while the terminal is changing, 4 times a second
  once it has been still for 1.2 s, and not at all while its window is off screen.
- **Folding.** Folding removes the output rows from the screen (`PageList.eraseRowsAt`) and keeps
  their text, with colors, in a ring of the 48 most recent folds. The command line gets a label
  ("42 lines" and the first line of output) that carries the fold's id as an OSC 8 link, so
  nothing depends on remembered positions. The chevron, or a click on the label, folds and opens
  a block. A block whose command line has scrolled off the top can be folded from the rows still
  in view; its command line comes back down.
- **Nothing folds by itself unless you ask.** Out of the box, output stays on the screen until
  you fold it. "Fold long output for me" (off by default) folds the previous command's output
  when the next command starts, if it was longer than "Fold after lines" (default 20). "Fold the
  newest output too" folds as soon as a command finishes. The output of a command that failed is
  never folded for you. The settings have new names (`autoFold`, `autoFoldLines`), so the earlier
  always-on default of 8 lines is not picked up from saved settings.
- **What stays still.** Two rules decide what a fold may move (`Anchor` in `fold.zig`). A fold
  made with the pointer keeps the command line that was clicked where it is: what is under it
  moves up, the freed rows are left blank at the bottom, and a second click in the same place
  undoes the first. (If that command line is up in the scrollback there is nothing in view to
  hold still, so the space is filled from the scrollback and the command line arrives with it.)
  A fold made for you keeps the cursor where it is: the rows from the fold down
  do not move, and the space is filled from above by lines coming back out of the scrollback. If
  the scrollback holds fewer lines than the fold would free, that output is left open.
- **Opening.** Blank rows at the bottom of the screen are used first; for the rest, rows above
  scroll into the scrollback and the view stays on the command line, so it does not move and the
  output unrolls under it. The prompt may then be below the view; typing brings it back.
- **Peek.** Rows can be put back on the screen itself but not into the scrollback. A fold whose
  command line has scrolled up there opens as a panel over the pane instead (`SignalPeekView`):
  the kept text, plain, set at the terminal's columns and line height, scrollable. The chevron
  again, any key, a click elsewhere or scrolling the terminal puts it away. Escape closes it
  without reaching the shell. Text over 2,000 lines is cut in the panel; copy takes all of it.
- **Showing the change.** For under half a second after a fold or an opening the block shows
  which way it went: an opened block has a bright line run down from its command line, with the
  rows it has not reached yet dimmed; a folded one glows and settles. Not with Reduce Motion.
- **Copy from a fold.** Kept text holds the blanks between words as cursor steps, not spaces.
  Plain text made from it (copy, the label's preview, the peek) turns each step back into
  spaces; before, the words of a column listing ran together.
- **Limits.** Blocks are only rewritten while the shell is at a prompt, on the primary screen.
  A fold pushed out of the ring of 48 keeps its label but has no button. Output over 20,000 rows
  is never folded. Colors come back when a fold is opened in place, not in the peek or a copy.
- **Prompt.** With "Signal prompt (zsh)" on, the app sets `GHOSTTY_X_PROMPT=1` and the zsh
  integration draws the prompt itself (directory and branch chips, caret, Python environment on
  the right) with zsh builtins only, taking over from Starship inside Ghostty X. When a line is
  accepted its prompt shrinks to a blank spacer row and the caret, which is what gives each
  block its own box.
- **Command deck.** The prompt being typed at is a card of its own, drawn by the same overlay:
  in the focused pane it has the window's color on its edge, a wash that fades to the right, a
  bright bar down its left side, and "CMD" and "RUN" labels set into its top edge. In other
  panes it is a plain outline. The shell prints only the prompt's text. Its graphics (the chip
  outlines and icons, the arrow pointer, and the caret that starts each finished command) are
  drawn by the overlay over cells the prompt marks with blank one-cell characters (U+2002,
  U+2003, U+2005, U+2006, U+2008, U+2009; see `fold.marks`), so they are vector shapes that
  match the design rather than font glyphs. The cursor is a thin blinking bar with nothing
  drawn around it. The prompt never turns red: a failure is shown on the command that failed (next point).
- **Failed commands.** A command that exits non-zero is marked on its own block: red caret, a
  red edge down the left, a red outline and a "FAILED" tag by the buttons. When the command
  finishes (OSC 133;D with a non-zero code) the core changes the blank pointer cell at the start
  of its command line from U+2002 to U+2003 (`markFailed` in `fold.zig`), so the mark is part of
  the row and stays with it through scrolling and folding. Before, the failure was shown on the
  prompt after it (red pointer, "FAILED" on HUD Brackets, "EXIT n" on Tabbed Dock), which read as
  if the prompt being typed at had failed. The exit code itself is no longer shown. The caret of
  a command typed over several rows is now drawn on its first row.
- **Keys.** Control-F folds every block with two or more rows of output, or opens every fold on
  the screen when there is nothing left to fold (`toggleAll` in `fold.zig`); the cursor stays put
  as far as the scrollback can fill the space. Control-S shrinks the sidebar to its tiles and
  brings it back. Both are keys terminal programs use, so they are only taken from the terminal
  while the shell has the plain screen (Control-F only at a prompt): in vim, less or an editor
  the key goes to the program as always. At a zsh prompt this does replace Control-F's
  forward-char and Control-S's forward search. Each can be turned off in Settings ▸ Tab Bar ▸
  Terminal. One app-wide key monitor (`SignalShortcuts`), no timers.
- **Picking a block from the keyboard.** At a prompt, Shift with the up and down arrows moves
  from one finished command to the next (the first press picks the newest); the picked block is
  outlined in the window's color and tagged "CTRL+C COPIES". Control-C, or Command-C, copies its
  output (its command if it printed nothing) and lets go of it. Escape or any other key lets go
  of it too, and with nothing picked Control-C is the usual interrupt. Past the top or bottom of
  the view it scrolls a prompt at a time (`jump_to_prompt`). A copy, by key or by the button,
  shows "COPIED TO CLIPBOARD" on that block for 1.6 s. A block is remembered by the screen row of
  its command line (`view_top` in the block geometry), which does not change as the view scrolls.
  Not taken while a program is running. Settings ▸ Tab Bar ▸ Terminal turns it off.
- **Key hints in the status line.** The free middle of the status line shows the keys worth
  remembering, each as a small key cap and a word: new tab, split, pick block, fold all, sidebar,
  next pane, zoom pane, clear, close. The app's own keys are listed when they are turned on; the
  terminal's are read from the loaded configuration (`keyboardShortcut(for:)`), so a rebound key
  shows as bound and an action with no key is left out. As many are drawn as fit, most useful
  first, and a long title gives up part of its room for them. The list is worked out once and
  kept until a setting or the configuration changes (`SignalHints`). "Key hints in the status
  line" in Settings ▸ Tab Bar turns it off.
- **Tabbed Dock spacing.** The dock is the typed row with the same margin above and below, so
  the text sits in its middle (it had 4 points above and 6 below). The directory tab has matching
  room before its icon and after its text, and the gap between the arrow tile and the text is
  about the tile's own margin (one cell less than before).
- **Room above the prompt.** Every prompt, the first of a session included, starts with a blank
  row. Before, the first had none, and the prompt's frame and label were drawn over whatever had
  been printed just before it (a direnv or login message).
- **Prompt styles.** Settings ▸ Tab Bar ▸ Terminal ▸ Prompt style picks the look of the prompt
  being typed at: Breadcrumb Rail (default), Command Capsule, Tabbed Dock, HUD Brackets, or the
  Card above. The app writes the choice to `prompt-style` in its cache folder; the zsh integration
  reads it before every prompt (`GHOSTTY_X_STYLE_FILE`), so open shells switch at their next
  prompt. Each look lays its text out differently and starts with a mark naming the look
  (U+2000, U+2001, U+2004, U+2007), and the overlay draws the look the marks name, so a shell
  that has not reached its next prompt is still drawn correctly. A demo run uses `demo-` copies
  of these cache files and never changes what the real app reads.
- **Motion.** Signal animations are stepped by `SignalMotion` (a 60 Hz timer that exists only
  while a motion runs) and move real geometry, not implicit layer animations. Each tab is its own
  window, so a motion plays only in the window being looked at (`NSWindow.isFrontTab`); a strip
  that is behind leaves the change unplayed and plays it when it comes forward. Before this, the
  strips played and used up their animations while still off screen, which is why switching and
  new tabs looked instant. The sidebar slide gives the terminal its new width once and then
  glides it, so the terminal is not resized every frame. A tab coming forward gets a sweep line
  drawn over the terminal; nothing underneath moves or fades, so a translucent window never shows
  through more. Motion in a window made under 0.7 s ago waits 0.24 s for it to settle.
- **Window opacity and blur.** The Signal Void overlay no longer sets `background-opacity`; your
  config's opacity and blur apply. The command deck's label gaps are cut out of its edge rather
  than painted, so they stay see-through too.
- **Colors and settings.** Settings ▸ Tab Bar ▸ Terminal has: Signal Void colors, Signal prompt,
  Prompt style, Command blocks, Fold long output for me, and with that on, Fold after lines and
  Fold the newest output too. Colors and the prompt are applied
  through a config overlay in `~/Library/Caches/com.amsynist.ghosttyx/`; the user's config file is
  never edited.
- **Drawing into nothing.** Closing a tab and switching at once could end the app: the strip is
  squeezed to zero width for a frame, `bounds.insetBy` then returns the null rectangle, its
  midpoint is not a number, and `NSBezierPath.line(to:)` raises, which AppKit turns into a crash
  (`+[NSApplication _crashOnException:]`; found from the crash record and the system log, 4 demo
  runs of 4 failed). Every `draw(_:)` in the Ghostty X chrome now returns when its bounds are
  under two points, the sliding highlight is never given a negative size, and it is not placed
  behind a tab that has no frame yet.
- **Memory and idle cost.** A demo run now opens, switches and closes tabs in three rounds and
  writes the app's memory after each: it levels off (for example 566, 552, 474 MB right after
  each round, 278 MB once idle, against 281 MB at the start; the numbers include the demo's own
  full-window pictures). The system leak checker (`leaks`) on the same run reports under 5 KB,
  all in system XPC objects. Two things were tightened: overlays are kept in a plain list and
  dropped when their pane closes, with one shared event monitor instead of one per pane, and the
  text kept for folds is capped at 16 MB in all (oldest folds go first). Left alone with three
  panes the app uses about 1.7% of one core, about 0.5% of it for the command blocks.
- **Prompt looks against their designs.** Each look is photographed in the state the design was
  drawn in (a branch, a Python environment, a command typed) and set beside it; spacing was
  corrected from that: the rail's environment ends in the last column and its branch and text sit
  closer, the capsule's badge and key cap stand at its two ends, the dock's "READY" is small and
  drawn by the app, and the brackets' tags and hints keep the design's gaps. What the cell grid
  does not allow: text in one size only (the designs use smaller labels), and the capsule's
  two-line name and version, which is one line here.
- **One script for all of it.** `.local/ghostty-x-install.sh` builds the core library and the
  app, signs it with the local helper, checks a staged copy, swaps it in for
  `/Applications/Ghostty.app` (the old one goes to `~/.config/zera-terminal-backups/`, and is put
  back if anything fails) and opens it. `--no-core`, `--no-build`, `--no-open` and `--close-old`
  change what it does; `--help` lists them. Run end to end once: 8 seconds with nothing to
  rebuild.
- **Installed.** The native tests pass (455, Debug configuration: the test target needs
  testability, which ReleaseLocal does not have). The build was signed with
  `.local/sign-ghostty-x.sh` and put at `/Applications/Ghostty.app`; the app it replaced is kept
  under `~/.config/zera-terminal-backups/GhosttyX-before-signal-20261121-125449/`. The copy that
  was running was not closed and keeps running from that folder until it is quit.
- **Fonts are made once.** The tab strip asked AppKit for a font inside every draw call. While
  tabs were opened and switched quickly, a label now and then reached Core Text with a nil font
  in its attributes; Core Text raises from inside `draw` and the app ends (the exception cannot
  be caught on its way out of Core Text, which was tried). `SignalFont` now makes each font once
  and keeps it, through a wrapper declared nullable (`GhosttyChromeFont` in
  `ObjCExceptionCatcher`), and `safeDraw`/`safeSize` skip a label that has no font. Which step
  inside AppKit lost the font was not pinned down: asking afresh about 12,000 times during two
  demo runs never returned nil. Before the change 3 of 4 complete demo runs ended in this crash;
  see the next point for the runs since. The belief recorded earlier, that emoji in a title
  caused it, was wrong; titles still leave emoji out, as a matter of looks.
- **Checked by** running the app's own demo (`GHOSTTYX_SIGNAL_DEMO=<folder>`, driven by
  `.local/signal-loop.sh`), which photographs its window after each step and writes what the
  core did to `trace.txt`: nothing folding with the settings as installed; a fold and an opening
  by hand; a fold made for you with the cursor on the same row before and after (the bottom row,
  with 25 rows taken back from the scrollback); output of a failed command left open; the same with a
  full screen and the command line in the scrollback; the opening and folding motion slowed six
  times; a fold from the last rows of output longer than the screen; the peek; the prompt styles;
  and the four tab bar positions. Motion was checked two ways: slowed six times and photographed
  frame by frame, and timed at real speed (tab switch and new tab: about 25 frames in 0.41 s,
  longest gap 17 to 41 ms; sidebar slide: about 16 frames in 0.30 s with one gap of about 50 ms).
  A stress run of 70 rapid tab switches, sidebar toggles, tab bar moves and new tabs is part of
  every demo run; since the fonts change it ended without a crash in seven consecutive runs
  (builds 42 to 48). Not covered: real clicks and wheel scrolling
  (the demo calls the same functions the buttons do), resizing with blocks open, bash and fish
  prompts (they get boxes and folding but keep their own prompt), very long sessions.

## Agent sessions

The chrome treats a Claude Code or Codex session as a session of its own, in the space the
chrome already had (`docs/previews/signal-agents.html` is the design).

- **Where the state comes from.** Each pane gives its shell a private folder
  (`GHOSTTY_AGENT_ACTIVITY_DIR`, mode 0700, removed with the pane). `scripts/agent-activity.py`
  is registered as a hook and writes one small file per provider there; the app watches the
  folder, with no polling. Settings ▸ Agent Activity turns the hooks on per provider. Enable
  again after updating: this version follows more events (subagents, tasks, compaction, errors,
  notifications).
- **What is stored.** The phase, the tool's name and one safe word about its target (a file's
  own name, a command's first word and subcommand, a host, an agent type), when the turn
  started, the model, the permission mode, a dot per subagent and a count of tasks. Never a
  prompt, a path, a full command or anything from a transcript. "Show the tool and file an
  agent is using" off (`GHOSTTY_AGENT_ACTIVITY_DETAILS=0`, panes opened from then on) stores
  the phase alone.
- **Context and cost.** Claude Code gives these only to its status line command. "Context and
  cost ▸ Enable" puts the script in front of the status line command you had (kept in
  `ghostty-x-statusline.json` beside Claude's settings), records the numbers and then runs
  yours, so the status line looks as it did. Disable puts the original back.
- **Session card.** Second line: a glyph for the state, then the tool and its target (the
  directory when there is no agent). The turn's time trails the title. The outline around the
  tile fills with the context window, amber from 75% and red from 90%. One dot per subagent,
  filled while it runs. A collapsed sidebar and the chips of top and bottom strips show the
  state as a dot on the tile.
- **Pane header.** The separate bar above the terminal is gone: it changed the terminal's row
  count whenever a session started or ended. The header says who is working and on what, with
  task steps, subagent dots and a context pie, and its lower edge shows working (a bar moved by
  Core Animation) or waiting (solid amber).
- **Sidebar foot.** One segment per session in the window's tabs, most urgent first, a line of
  counts, and Next Approval. The load sparkline is off unless "System load" is turned on.
- **Status line.** Follows the focused pane: state and turn time, model, permission mode,
  context cells, tokens, cost, lines changed. For a shell: title and key hints. The clock
  shows minutes and is drawn once a minute.
- **Titlebar.** A pill appears only while a session in another tab is waiting for an answer;
  a click goes to it.
- **Agents overview.** Command-Shift-A (app menu ▸ Agents Overview) lists every session in
  every tab and window with its subagents; arrows pick, Return goes to the pane. Control-Shift-A
  goes to the next session waiting for an answer, and is only taken while one is.
- **Done means unseen.** A finished turn reads Done until its pane is the focused pane of the
  key window, then Ready.
- **Cost.** Nothing animates on the main thread while an agent works. Measured on one pane,
  median of 20 one-second readings: a running session cost 6.2% of a core before and 0.6%
  after; idle went from 1.0% to 0.6%. While a turn's time is on screen one shared timer ticks
  once a second (`AgentClock`), and stops when nothing shows a time. Strips of tabs that are
  behind skip title and agent updates and catch up as they come forward. Status folders left
  by a copy of the app that has quit are removed at the next launch.
- **Checked by** `GHOSTTYX_SIGNAL_DEMO_SCRIPT=agents` (with `GHOSTTYX_SIGNAL_DEMO=<folder>`):
  three tabs with a running, a waiting and a finished session, photographed in the sidebar,
  the collapsed rail, compacting, the overview and a top strip. Make
  `/tmp/ghostty-x-demo/{api-service,release-tools,docs-site}` first: the demo's tabs sit in
  them, so the cards have names. The README's pictures were captured live over the teal
  cutting-mat wallpaper with `background-opacity = 0.6` and `background-blur = 40`. The hook script was run
  against made-up events in scratch folders. Not checked: a real Claude Code or Codex session
  end to end, and the Settings buttons, which edit `~/.claude/settings.json`.
