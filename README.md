<h1 align="center">Ghostty X</h1>

<p align="center">
  <strong>The Signal interface for Ghostty on macOS.</strong>
  <br />
  Session cards, framed split panes, live Claude Code and Codex activity, and command blocks you can fold.
  <br />
  <br />
  <a href="#what-ghostty-x-adds">Features</a>
  ·
  <a href="#build-from-source">Build</a>
  ·
  <a href="#configuration">Configuration</a>
  ·
  <a href="#relationship-to-ghostty">Relationship to Ghostty</a>
  ·
  <a href="#original-ghostty-readme">Original Ghostty README</a>
</p>

https://raw.githubusercontent.com/amsynist/ghostty-X/assets/signal/ghostty-x-film-1080p.mp4

> [!NOTE]
> Ghostty X is an independent fork of [Ghostty](https://github.com/ghostty-org/ghostty). It is not affiliated with or endorsed by the Ghostty project. The terminal engine, rendering, native tabs and splits, and configuration are Ghostty's work; see [Relationship to Ghostty](#relationship-to-ghostty).

## What Ghostty X adds

Ghostty X changes how the macOS app looks and what it tells you. The terminal underneath is Ghostty.

|              | Ghostty X adds                                                                                                             | Ghostty provides                                                |
| ------------ | -------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| **Sessions** | Numbered session cards in a sidebar, or compact tabs at the top or bottom, with a selection that slides between them       | Native tabs and windows, restoration, key bindings              |
| **Splits**   | A frame and header for every pane, corner brackets and a trace line that follow focus, split buttons in the titlebar       | The split tree, resizing, zoom and equalize                     |
| **Agents**   | Claude Code and Codex activity in the pane header, session card, status line and sidebar, with a jump to the next approval | The terminal they run in                                        |
| **Commands** | A block around each command and its output, folding in place, copy, and a marker on commands that failed                   | Shell integration, which marks where each prompt begins         |
| **Prompt**   | Five zsh prompt styles                                                                                                     | Shell integration                                               |
| **Engine**   | A small addition for folding rows and reading a command's output                                                           | Terminal emulation, GPU rendering, fonts, themes, configuration |

## The Signal interface

[![A Ghostty X window with a sidebar of four sessions, Claude Code in the left pane and Codex in the right pane, each pane framed with its own header](docs/media/signal-workspace.webp)](docs/media/signal-workspace.webp)

- **Session cards.** Each tab is a card with a numbered tile in the tab's color, its title and the focused pane's directory. A new session sweeps into place, and the selection slides from one card to the next.
- **Titlebar.** The title is a capsule with the session's number, name and directory. Buttons at the trailing end split right, split down and open the command palette.
- **Framed panes.** Every pane has a header with its letter, title, directory and size in cells. The focused pane has a tinted outline and corner brackets, and a trace line runs from the selected session to it.
- **Status line.** A strip under the terminal shows the focused pane and the current shortcuts for tab, pane and block actions.
- **One color.** The selection, focus outline, trace, titlebar and status line take the selected tab's color.

## Agent activity

A Claude Code or Codex session is treated as a session of its own, in the space the interface already has. Nothing is added above the terminal, so a session starting or ending never changes the terminal's size.

[![Claude Code working in a pane: the header shows the tool and file, task steps, subagents and context, and the status line shows the model, mode, context, tokens and cost](docs/media/agent-activity.webp)](docs/media/agent-activity.webp)

- **Pane header.** Who is working and on what (`Write RateLimiterTests.swift`), with task steps, a dot for each subagent and a context pie. Its lower edge moves while the agent works.
- **Session card.** The second line shows the state and the tool in use. The outline around the tile fills with the context window.
- **Status line.** Follows the focused pane: state and turn time, model, permission mode, context, tokens, cost, files and lines changed.

<p align="center">
  <img src="docs/media/agent-status-line.webp" alt="The status line reading: Running 0:11, Opus 5.5, accept edits, context 47 percent, 94k tokens, $0.55, 2 files, 57 lines added, 2 removed" width="620" />
</p>

### Approvals

When an agent in another pane or tab needs an answer, its header and session card turn amber, the sidebar foot counts it, and **Next Approval** takes you to it. A pill in the titlebar appears while a session in another tab is waiting. You answer in the agent's own prompt; Ghostty X only shows you where.

| The whole window                                                                                                                                                                                                                                                      | The pane that is waiting                                                                                                                                                          |
| --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| [![Three panes: Claude Code running on the left, Codex waiting for approval at the top right with an amber header, and a shell below it; the sidebar foot reads 1 waiting, 1 running, Next Approval](docs/media/agent-approval.webp)](docs/media/agent-approval.webp) | [![The Codex pane with an amber header reading Bash git push, asking whether to allow the command](docs/media/agent-approval-detail.webp)](docs/media/agent-approval-detail.webp) |

Amber means **Needs approval**, cyan **Running**, violet **Compacting**, red **Stopped on error**, and green **Done** until you have looked at the pane.

<kbd>⌘⇧A</kbd> opens the Agents overview, which lists every session in every tab with its subagents. <kbd>⌃⇧A</kbd> goes to the next one waiting for an answer.

[![The Agents overview panel listing three sessions with their subagents](docs/previews/agents/agents-4-overview.webp)](docs/previews/agents/agents-4-overview.webp)

### Turning it on

In **Ghostty X Settings… → Agent Activity**, enable Claude Code, Codex, or both. The setup uses Python 3.9 or newer. You can also enable the hooks from a checkout:

```sh
python3 scripts/agent-activity.py enable claude
python3 scripts/agent-activity.py enable codex
```

Then start `claude` or `codex` in a Ghostty X pane. In Codex, review and trust the Ghostty X hooks in `/hooks`. To remove the hooks, run the same commands with `disable`. Enable again after updating Ghostty X, since newer versions follow more events.

Context, tokens and cost come from Claude Code's status line. **Context and cost → Enable** (or `usage-enable claude`) records them and then runs the status line command you already had; `usage-disable` puts it back.

**What the hook passes on.** The provider's state reaches the pane through a local temporary directory: the phase, the tool's name and one word about its target (a file's name, a command's first word). Never a prompt, a path or a full command.

## Command blocks

Every command and its output is one block, with a copy button and a fold chevron on the command line.

| Open                                                                                                                                         | Folded                                                                                                                                                                         |
| -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| [![A command block showing make test and its seven lines of output](docs/media/command-block-open.webp)](docs/media/command-block-open.webp) | [![The same block folded to one line that reads make test, 7 lines, and the first line of output](docs/media/command-block-folded.webp)](docs/media/command-block-folded.webp) |

- **Fold and reopen.** Click a block's chevron, or press <kbd>⌃F</kbd> at the shell prompt. Folding takes the output off the screen and keeps its text, with colors; the command line shows the line count and the first line. Reopening unrolls it in place.
- **Fold long output for you.** Off by default. When on, you set the line threshold and whether the newest output folds too. The output of a command that failed is never folded for you.
- **Pick and copy.** <kbd>⇧↑</kbd> and <kbd>⇧↓</kbd> select a finished block; <kbd>⌃C</kbd> or <kbd>⌘C</kbd> copies its output, folded or not.
- **See what failed.** A command that exits non-zero gets a red **FAILED** marker on its own block.

Blocks come from shell integration's prompt marks, so they appear in shells where Ghostty's shell integration is active.

## Prompt styles

**Ghostty X Settings… → Terminal → Prompt style** changes the zsh prompt. The prompt is drawn with zsh builtins only and takes over from a prompt theme such as Starship inside Ghostty X.

| Style               | Looks like                                                                                                                                                  |
| ------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- |
| **Breadcrumb Rail** | <img src="docs/media/prompt-rail.webp" alt="Breadcrumb Rail: the path as breadcrumbs with the Git branch, and the command on the line below" width="500" /> |
| **Command Capsule** | <img src="docs/media/prompt-capsule.webp" alt="Command Capsule: directory, branch and command on one line inside a capsule" width="500" />                  |
| **Tabbed Dock**     | <img src="docs/media/prompt-dock.webp" alt="Tabbed Dock: directory and Git tabs above the command line" width="500" />                                      |
| **HUD Brackets**    | <img src="docs/media/prompt-hud.webp" alt="HUD Brackets: corner brackets around labeled directory and Git fields, with the command below" width="500" />    |
| **Command Card**    | <img src="docs/media/prompt-card.webp" alt="Command Card: directory and Git chips above the command line, inside a card" width="500" />                     |

## Layouts

**Ghostty X Settings… → Layout → Position** moves the session strip to the left, right, top or bottom. The sidebar button, or <kbd>⌃S</kbd> at the shell prompt, collapses a sidebar to numbered tiles. Sessions can be grouped by agent.

| Collapsed sidebar                                                                                                                                                | Tabs at the top                                                                                                                    |
| ---------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------- |
| [![The sidebar collapsed to numbered tiles with context rings and state dots](docs/previews/agents/agents-2-rail.webp)](docs/previews/agents/agents-2-rail.webp) | [![The same sessions with the tab bar at the top](docs/previews/agents/agents-5-top.webp)](docs/previews/agents/agents-5-top.webp) |

Choose **Classic** instead of **Signal** in the settings for a simpler capsule tab strip.

## Build from source

Ghostty X runs on macOS only. You need Xcode with its macOS SDK and Metal toolchain, Zig at the version in [`build.zig.zon`](build.zig.zon), and Nushell. See [Ghostty's macOS build prerequisites](HACKING.md#macos) for details.

```sh
git clone https://github.com/amsynist/ghostty-X.git
cd ghostty-X
zig build -Doptimize=ReleaseFast -Demit-macos-app=false -Dxcframework-target=native
macos/build.nu --configuration ReleaseLocal --arch "$(uname -m)"
open macos/build/ReleaseLocal/GhosttyX.app
```

The app builds as `GhosttyX.app` with the bundle identifier `com.amsynist.ghosttyx`, so it installs beside the official Ghostty and reads the same Ghostty configuration.

To run the native tests:

```sh
macos/build.nu --configuration ReleaseLocal --arch "$(uname -m)" --action test
```

## Configuration

The custom tab strip uses the `tabs` titlebar style, on macOS 26 and later. Set it in your Ghostty configuration:

```ini
macos-titlebar-style = tabs
```

On macOS 13 to 15 the tabs keep Ghostty's own appearance.

Everything else is in **Ghostty X Settings…**, beside **Open Config** in the app menu: Signal or Classic, tab placement and sizing, pane headers, focus effects, status hints, agent activity hooks, the prompt style, command blocks and the optional Signal Void colors. Window opacity and blur follow your Ghostty configuration.

[![The Ghostty X Settings window with Design, Agent Activity and Terminal controls and a live preview](docs/previews/agents/ghostty-x-settings.webp)](docs/previews/agents/ghostty-x-settings.webp)

The [implementation notes](GHOSTTY_X.md) describe how each part works, what it changes in the core, and how it was tested.

## Relationship to Ghostty

Ghostty X is a fork of [Ghostty](https://github.com/ghostty-org/ghostty), last merged with upstream at commit [`74241405f`](https://github.com/ghostty-org/ghostty/commit/74241405fe457d6a569a110cffe9d75a1c9a53b7).

- **Credit.** Ghostty is the work of Mitchell Hashimoto and the Ghostty contributors. The terminal emulation, renderer, font handling, shell integration, native tab and split handling, and configuration system in this repository are theirs.
- **Not official.** This is a personal project. It is not affiliated with, sponsored by or endorsed by the Ghostty project, and "Ghostty" is the name of their project, used here to say what this fork is built on.
- **Where to report problems.** A problem with anything described above belongs in this repository, not with the Ghostty project. Check whether it also happens in the official Ghostty before reporting it upstream.
- **The official app.** For Ghostty itself, its downloads and its documentation, go to [ghostty.org](https://ghostty.org).
- **License.** Ghostty X is distributed under the same [MIT license](LICENSE) as Ghostty, with Ghostty's copyright notice kept in place.

### About the film

The film and every screenshot made from it were recorded from the running app. The Claude Code and Codex sessions in them are staged with sample data, sent through the app's own agent activity hook, and the film says so on screen. Its interface sounds are CC0 recordings, and its narration is a synthetic voice made with ElevenLabs.

---

## Original Ghostty README

Everything below this line is the README of upstream Ghostty at commit [`74241405f`](https://github.com/ghostty-org/ghostty/blob/74241405fe457d6a569a110cffe9d75a1c9a53b7/README.md), reproduced without changes. Its links, download instructions and roadmap describe Ghostty itself, not this fork.

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
