# Ghostty X

Ghostty X is a macOS appearance fork of Ghostty. Its default Signal interface
adds session cards, a focus trace around split panes, and command blocks you
can fold and copy inside the terminal.

[![Ghostty X Signal live walkthrough over the teal cutting-mat wallpaper](https://raw.githubusercontent.com/amsynist/ghostty-X/278ab3c5f3f8b8f162d2070ded61dd77ecf252d8/signal/4k/signal-preview.webp)](https://raw.githubusercontent.com/amsynist/ghostty-X/278ab3c5f3f8b8f162d2070ded61dd77ecf252d8/signal/4k/signal-walkthrough.mp4)

[Watch the live walkthrough (22 seconds)](https://raw.githubusercontent.com/amsynist/ghostty-X/278ab3c5f3f8b8f162d2070ded61dd77ecf252d8/signal/4k/signal-walkthrough.mp4) ·
[Download the offline HTML walkthrough (ZIP)](https://raw.githubusercontent.com/amsynist/ghostty-X/bfe8a233548a71f718581aafe9f797a3b4f18f96/signal/4k/signal-walkthrough-html.zip)

The live walkthrough and native lossless 3324 × 2120 agent-activity captures
run `GhosttyX.app` with translucent blurred glass over the teal cutting-mat
wallpaper, alongside the 3840 × 2496 layout and prompt close-ups below. Select
any image to open the full capture, or open the downloaded HTML file to jump
directly to any tab position, prompt style, or command-block action.

## Sidebars and tabs

Select **Ghostty X Settings… → Layout → Position** to move the session strip. Signal shows numbered
session cards in the left or right sidebar and compact tabs at the top or bottom.
Use the sidebar button or **Control-S** at the shell prompt to collapse the
sidebar to numbered tiles.

### Claude Code and Codex activity

The Signal interface treats a Claude Code or Codex session as a session of its
own, in the space the chrome already has:

- **Session card.** The second line shows the state and the tool in use
  (`▸ Edit routes.swift`). The turn's time follows the title, the outline
  around the tile fills with the context window, and each subagent is a dot.
- **Pane header.** Who is working and on what, with task steps, subagent dots
  and a context pie. Its lower edge moves while the agent works and turns
  amber while it waits. Nothing is added above the terminal, so a session
  starting or ending never changes the terminal's size.
- **Status line.** Follows the focused pane: state and turn time, model,
  permission mode, context, tokens, cost, files and lines changed.
- **Sidebar foot.** One segment per session and **Next Approval**. A pill in
  the titlebar appears while a session in another tab is waiting.
- **Agents overview.** <kbd>⌘⇧A</kbd> lists every session in every tab with
  its subagents. <kbd>⌃⇧A</kbd> goes to the next one waiting for an answer.

Amber means **Needs approval**, cyan **Running**, violet **Compacting**, red
**Stopped on error**, and green **Done** until you have looked at the pane.
Approvals are handled in the original CLI prompt.

[![Three sessions in the sidebar: one running with subagents, one waiting for approval, one ready](docs/previews/agents/agents-1-working.webp)](docs/previews/agents/agents-1-working.webp)

| Agents overview | Top tabs |
| --- | --- |
| [![The agents overview panel listing three sessions with their subagents](docs/previews/agents/agents-4-overview.webp)](docs/previews/agents/agents-4-overview.webp) | [![The same sessions with the tab bar at the top](docs/previews/agents/agents-5-top.webp)](docs/previews/agents/agents-5-top.webp) |
| **Collapsed sidebar** | **Codex approval & compacting state** |
| [![The sidebar collapsed to numbered tiles with context rings and state dots](docs/previews/agents/agents-2-rail.webp)](docs/previews/agents/agents-2-rail.webp) | [![Codex approval prompt in the active pane while a Claude session compacts in the sidebar](docs/previews/agents/agents-3-compacting.webp)](docs/previews/agents/agents-3-compacting.webp) |

[Open the interactive preview](docs/previews/signal-agents.html)

In **Ghostty X Settings… → Agent Activity**, enable Claude Code, Codex, or both. The
setup uses Python 3.9 or newer. You can also enable the hooks from this
checkout:

```sh
python3 scripts/agent-activity.py enable claude
python3 scripts/agent-activity.py enable codex
```

Launch `claude` or `codex` in a pane opened by a Ghostty X build with agent
activity support. In Codex, review and trust the Ghostty X hooks in
`/hooks`. The hook passes the provider's state to the pane through a local
temporary directory: the phase, the tool's name and one word about its target
(a file's name, a command's first word), never a prompt, a path or a full
command. To remove the hooks, run the same commands with `disable`. Enable
again after updating Ghostty X, since newer versions follow more events.

Context, tokens and cost come from Claude Code's status line. **Context and
cost → Enable** (or `usage-enable claude`) records them and then runs the
status line command you already had; `usage-disable` puts it back.

| Left sidebar | Right sidebar |
| --- | --- |
| [![Left sidebar with four session cards](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-left.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-left.png) | [![Right sidebar with four session cards](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-right.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-right.png) |

### Top tabs

[![Top tab bar and New session button](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-top.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-top.png)

### Bottom tabs

[![Bottom tab bar and New session button](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-bottom.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-bottom.png)

## Prompt styles

Choose **Ghostty X Settings… → Terminal → Prompt style** to change the zsh prompt.

### Breadcrumb Rail

[![Breadcrumb Rail prompt with a full path and Git branch](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-prompt-rail.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-rail.png)

### Command Capsule

[![Command Capsule with the environment, branch and command on one line](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-prompt-capsule.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-capsule.png)

### Tabbed Dock

[![Tabbed Dock with directory, Git and Python tabs above the command](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-prompt-dock.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-dock.png)

### HUD Brackets

[![HUD Brackets with corner brackets and labeled context](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-prompt-hud.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-hud.png)

### Command Card

[![Command Card with directory and Git chips above the command line](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-detail-prompt-card.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-card.png)

## Command blocks

[![A selected command block with the keyboard copy hint](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-blocks.png)](https://raw.githubusercontent.com/amsynist/ghostty-X/cd32c38f0cb310a2daa15d3c29c84edb7ae9b763/signal/4k/signal-blocks.png)

- **Fold and reopen output.** Use a block’s chevron or press **Control-F** to
  fold or reopen eligible blocks at the shell prompt. Optional automatic
  folding lets you set the line threshold and include or skip the newest output.
- **Pick and copy.** Use **Shift-Up** or **Shift-Down** to select a finished
  block, then **Control-C** or **Command-C** to copy its output. Recent commands
  also offers a preview and copy controls.
- **See what failed.** A command with a nonzero exit status gets a red
  **FAILED** marker on its own block. A fold in scrollback can open as a
  read-only preview.
- **Follow focus.** The active tab’s color carries through to the pane outline,
  trace, titlebar and status line. The status line can show the current
  shortcuts for tab, pane and block actions.

## Configuration

The custom tab strip uses the `tabs` titlebar style on macOS 26 and later.
Set it in your Ghostty configuration:

```ini
macos-titlebar-style = tabs
```

Open **Ghostty X Settings…** beside **Open Config** in the app menu. Choose **Signal** or
**Classic**, configure tab placement and sizing, and adjust pane headers,
focus effects, status hints, and **Agent Activity** hooks. The **Terminal** section controls the zsh
Signal prompt, command blocks and optional Signal Void colors. Window opacity
and blur follow your Ghostty configuration, and the Quick Terminal derives a
matching Signal accent from your active screen wallpaper when available.

[![Ghostty X Settings window showing Design, Agent Activity, Terminal controls, and Live preview](docs/previews/agents/ghostty-x-settings.webp)](docs/previews/agents/ghostty-x-settings.webp)

The app builds as `GhosttyX.app` with bundle identifier
`com.amsynist.ghosttyx`. See the [build and implementation notes](GHOSTTY_X.md)
for build commands, supported behavior and test coverage.

---

<!-- LOGO -->
<h1>
<p align="center">
  <img src="https://github.com/user-attachments/assets/fe853809-ba8b-400b-83ab-a9a0da25be8a" alt="Logo" width="128">
  <br>Ghostty
</h1>
  <p align="center">
    Fast, native, feature-rich terminal emulator pushing modern features.
    <br />
    A native GUI or embeddable library via <code>libghostty</code>.
    <br />
    <a href="#about">About</a>
    ·
    <a href="https://ghostty.org/download">Download</a>
    ·
    <a href="https://ghostty.org/docs">Documentation</a>
    ·
    <a href="CONTRIBUTING.md">Contributing</a>
    ·
    <a href="HACKING.md">Developing</a>
  </p>
</p>

## About

Ghostty is a terminal emulator that differentiates itself by being
fast, feature-rich, and native. While there are many excellent terminal
emulators available, they all force you to choose between speed,
features, or native UIs. Ghostty provides all three.

**`libghostty`** is a cross-platform, zero-dependency C and Zig library
for building terminal emulators or utilizing terminal functionality
(such as style parsing). Anyone can use `libghostty` to build a terminal
emulator or embed a terminal into their own applications. See
[Ghostling](https://github.com/ghostty-org/ghostling) for a minimal complete project
example or the [`examples` directory](https://github.com/ghostty-org/ghostty/tree/main/example)
for smaller examples of using `libghostty` in C and Zig.

For more details, see [About Ghostty](https://ghostty.org/docs/about).

## Download

See the [download page](https://ghostty.org/download) on the Ghostty website.

## Documentation

See the [documentation](https://ghostty.org/docs) on the Ghostty website.

## Contributing and Developing

If you have any ideas, issues, etc. regarding Ghostty, or would like to
contribute to Ghostty through pull requests, please check out our
["Contributing to Ghostty"](CONTRIBUTING.md) document. Those who would like
to get involved with Ghostty's development as well should also read the
["Developing Ghostty"](HACKING.md) document for more technical details.

## Roadmap and Status

Ghostty is stable and in use by millions of people and machines daily.

The high-level ambitious plan for the project, in order:

|  #  | Step                                                    | Status |
| :-: | ------------------------------------------------------- | :----: |
|  1  | Standards-compliant terminal emulation                  |   ✅   |
|  2  | Competitive performance                                 |   ✅   |
|  3  | Rich windowing features -- multi-window, tabbing, panes |   ✅   |
|  4  | Native Platform Experiences                             |   ✅   |
|  5  | Cross-platform `libghostty` for Embeddable Terminals    |   ✅   |
|  6  | Ghostty-only Terminal Control Sequences                 |   ❌   |

Additional details for each step in the big roadmap below:

#### Standards-Compliant Terminal Emulation

Ghostty implements all of the regularly used control sequences and
can run every mainstream terminal program without issue. For legacy sequences,
we've done a [comprehensive xterm audit](https://github.com/ghostty-org/ghostty/issues/632)
comparing Ghostty's behavior to xterm and building a set of conformance
test cases.

In addition to legacy sequences (what you'd call real "terminal" emulation),
Ghostty also supports more modern sequences than almost any other terminal
emulator. These features include things like the Kitty graphics protocol,
Kitty image protocol, clipboard sequences, synchronized rendering,
light/dark mode notifications, and many, many more.

We believe Ghostty is one of the most compliant and feature-rich terminal
emulators available.

Terminal behavior is partially a de jure standard
(i.e. [ECMA-48](https://ecma-international.org/publications-and-standards/standards/ecma-48/))
but mostly a de facto standard as defined by popular terminal emulators
worldwide. Ghostty takes the approach that our behavior is defined by
(1) standards, if available, (2) xterm, if the feature exists, (3)
other popular terminals, in that order. This defines what the Ghostty project
views as a "standard."

#### Competitive Performance

Ghostty is generally in the same performance category as the other highest
performing terminal emulators.

"The same performance category" means that Ghostty is much faster than
traditional or "slow" terminals and is within an unnoticeable margin of the
well-known "fast" terminals. For example, Ghostty and Alacritty are usually within
a few percentage points of each other on various benchmarks, but are both
something like 100x faster than Terminal.app and iTerm. However, Ghostty
is much more feature rich than Alacritty and has a much more native app
experience.

This performance is achieved through high-level architectural decisions and
low-level optimizations. At a high-level, Ghostty has a multi-threaded
architecture with a dedicated read thread, write thread, and render thread
per terminal. Our renderer uses OpenGL on Linux and Metal on macOS.
Our read thread has a heavily optimized terminal parser that leverages
CPU-specific SIMD instructions. Etc.

#### Rich Windowing Features

The Mac and Linux (build with GTK) apps support multi-window, tabbing, and
splits with additional features such as tab renaming, coloring, etc. These
features allow for a higher degree of organization and customization than
single-window terminals.

#### Native Platform Experiences

Ghostty is a cross-platform terminal emulator but we don't aim for a
least-common-denominator experience. There is a large, shared core written
in Zig but we do a lot of platform-native things:

- The macOS app is a true SwiftUI-based application with all the things you
  would expect such as real windowing, menu bars, a settings GUI, etc.
- macOS uses a true Metal renderer with CoreText for font discovery.
- macOS supports AppleScript, Apple Shortcuts (AppIntents), etc.
- The Linux app is built with GTK.
- The Linux app integrates deeply with systemd if available for things
  like always-on, new windows in a single instance, cgroup isolation, etc.

Our goal with Ghostty is for users of whatever platform they run Ghostty
on to think that Ghostty was built for their platform first and maybe even
exclusively. We want Ghostty to feel like a native app on every platform,
for the best definition of "native" on each platform.

#### Cross-platform `libghostty` for Embeddable Terminals

In addition to being a standalone terminal emulator, Ghostty is a
C-compatible library for embedding a fast, feature-rich terminal emulator
in any 3rd party project. This library is called `libghostty`.

Due to the scope of this project, we're breaking libghostty down into
separate libraries, starting with `libghostty-vt`. The goal of
this project is to focus on parsing terminal sequences and maintaining
terminal state. This is covered in more detail in this
[blog post](https://mitchellh.com/writing/libghostty-is-coming).

`libghostty-vt` is already available and usable today for Zig and C and
is compatible for macOS, Linux, Windows, and WebAssembly. The functionality
is extremely stable (since its been proven in Ghostty GUI for a long time),
but the API signatures are still in flux.

`libghostty` is already heavily in use. See [`examples`](https://github.com/ghostty-org/ghostty/tree/main/example)
for small examples of using `libghostty` in C and Zig or the
[Ghostling](https://github.com/ghostty-org/ghostling) project for a
complete example. See [awesome-libghostty](https://github.com/Uzaaft/awesome-libghostty)
for a list of projects and resources related to `libghostty`.

`libghostty-vt` is released on its own, separately from Ghostty, with
`vt-X.Y.Z` tags. To build or package it, see
[`PACKAGING-LIBGHOSTTY.md`](PACKAGING-LIBGHOSTTY.md). To use it from a
CMake project, see [`dist/cmake/README.md`](dist/cmake/README.md). We're
still working on a better docs experience, but our
[Doxygen website](https://lib.ghostty.org/vt/) is a good resource
for the C API.

#### Ghostty-only Terminal Control Sequences

We want and believe that terminal applications can and should be able
to do so much more. We've worked hard to support a wide variety of modern
sequences created by other terminal emulators towards this end, but we also
want to fill the gaps by creating our own sequences.

We've been hesitant to do this up until now because we don't want to create
more fragmentation in the terminal ecosystem by creating sequences that only
work in Ghostty. But, we do want to balance that with the desire to push the
terminal forward with stagnant standards and the slow pace of change in the
terminal ecosystem.

We haven't done any of this yet.

## Crash Reports

Ghostty has a built-in crash reporter that will generate and save crash
reports to disk. The crash reports are saved to the `$XDG_STATE_HOME/ghostty/crash`
directory. If `$XDG_STATE_HOME` is not set, the default is `~/.local/state`.
**Crash reports are _not_ automatically sent anywhere off your machine.**

Crash reports are only generated the next time Ghostty is started after a
crash. If Ghostty crashes and you want to generate a crash report, you must
restart Ghostty at least once. You should see a message in the log that a
crash report was generated.

> [!NOTE]
>
> Use the `ghostty +crash-report` CLI command to get a list of available crash
> reports. A future version of Ghostty will make the contents of the crash
> reports more easily viewable through the CLI and GUI.

Crash reports end in the `.ghosttycrash` extension. The crash reports are in
[Sentry envelope format](https://develop.sentry.dev/sdk/envelopes/). You can
upload these to your own Sentry account to view their contents, but the format
is also publicly documented so any other available tools can also be used.
The `ghostty +crash-report` CLI command can be used to list any crash reports.
A future version of Ghostty will show you the contents of the crash report
directly in the terminal.

To send the crash report to the Ghostty project, you can use the following
CLI command using the [Sentry CLI](https://docs.sentry.io/cli/installation/):

```shell-session
SENTRY_DSN=https://e914ee84fd895c4fe324afa3e53dac76@o4507352570920960.ingest.us.sentry.io/4507850923638784 sentry-cli send-envelope --raw <path to ghostty crash>
```

> [!WARNING]
>
> The crash report can contain sensitive information. The report doesn't
> purposely contain sensitive information, but it does contain the full
> stack memory of each thread at the time of the crash. This information
> is used to rebuild the stack trace but can also contain sensitive data
> depending on when the crash occurred.
