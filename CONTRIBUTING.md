# Contributing to Sigpane

Thanks for your interest in Sigpane. Issues, ideas and pull requests are welcome here.

## Where to report what

Sigpane is an independent fork of [Ghostty](https://github.com/ghostty-org/ghostty). It changes the macOS app's interface (session cards, framed panes, agent activity, command blocks, the Signal prompt); the terminal engine underneath is Ghostty's.

- **Something in the Sigpane interface** (the sidebar, pane headers, the status line, agent activity, command blocks, prompt styles, the Sigpane settings window): open an issue in this repository.
- **Something in the terminal itself** (escape sequences, rendering, fonts, configuration keys): first check whether it also happens in the official Ghostty app. If it does, it belongs with the Ghostty project and their own contributing guide. If it only happens in Sigpane, open an issue here.

Please don't report Sigpane problems to the Ghostty project. They don't maintain this fork.

## Issues

A useful issue says what you did, what you expected, and what happened instead, with your macOS version and the Sigpane commit you built from. A screenshot or a short screen recording helps a lot for interface problems. Leave out anything private: tokens, real project paths, other people's names.

## Pull requests

- Keep each pull request to one change, and describe what it changes and how you checked it.
- Build and test before you open it. [HACKING.md](HACKING.md) covers the toolchain; the short version for the macOS app is `macos/build.nu` to build and `macos/build.nu --action test` to run the tests. Run `zig build test` for changes under `src/`.
- Format before you push: `zig fmt .` for Zig, `swiftlint lint --strict --fix` for Swift, `prettier -w .` for everything else.
- Keep upstream code recognizable. Changes outside the macOS interface make it harder to take in Ghostty's updates, so keep them small and explain why they are needed.
- You must understand the code you submit, and say when you used AI tools and how. See the [AI usage policy](AI_POLICY.md).

## License

Sigpane is released under the [MIT license](LICENSE), like Ghostty. By contributing, you agree that your contributions are licensed under it too.
