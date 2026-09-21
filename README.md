# Latch

A small, native macOS client for coding agents.

Latch runs Codex, Claude Code, OpenCode, fx, or any other [Agent Client Protocol](https://agentclientprotocol.com) agent in a real AppKit window: sessions per workspace, streamed replies and tool activity, and native approval sheets for what the agent asks to do. There is no web view, no account, and no hosted service. The whole app is under 4 MB.

<!-- TODO before going public: screenshot at docs/images/latch.png -->
<!-- ![Latch](docs/images/latch.png) -->

> **Early development.** Latch is pre-release: there are no signed builds yet, so today you build it from source. Expect bugs and breaking changes. Issues are welcome; please read [CONTRIBUTING.md](.github/CONTRIBUTING.md) before opening a pull request.

## What works today

- **Any ACP agent.** Built-in presets for Codex, Claude Code, OpenCode, and fx find what you already have installed; a custom command runs anything else that speaks ACP. No model names, effort levels, or permission modes are hard-coded — the pickers show what the connected agent advertises.
- **Sessions per workspace.** Open a folder from the toolbar, the Finder, or by dropping it on the window or Dock icon. Sessions, transcripts, and unsent drafts are saved locally and survive a relaunch; fork, rename, close, and undo-close are all there.
- **Approvals you have to read.** Permission requests appear as native sheets with the agent's full request details. Approval has no default key — Return and Escape both cancel.
- **Attention comes to you.** Sessions keep running in the background. A permission request or finished turn posts a notification, badges the Dock icon, and shows in the menu bar extra. Notification text names the workspace folder and nothing else.
- **A fast native transcript.** Incremental Markdown rendering keeps a streamed frame cheap however long the answer gets, with ⌘F find, per-message copy, and system fonts and colors throughout.
- **Process isolation.** Agents run under an XPC service embedded in the app, not in the UI process. The service admits only the app's own code signature.

## What does not exist yet

Latch's goal is a control surface that follows you: the agent keeps running on the Mac where the code lives, and a native iPhone or iPad app pairs with it to monitor sessions and answer approvals. **None of the iOS or pairing work is built.** The [roadmap](docs/roadmap.md) describes that design and its milestones.

Other known gaps:

- No signed or notarized download, and no update mechanism.
- Agents stop when the app quits; the background service that would outlive it is not implemented.
- If the app or its service is killed outright, running agent processes are not cleaned up.
- Permission approval and model/effort/mode switching are covered by mock-agent tests and an opt-in live Codex test, but have not been validated across every provider.
- The Markdown renderer covers a subset of CommonMark. HTML and remote resources are never rendered or loaded.
- Apple silicon only.

## Requirements

- macOS 15 or later on Apple silicon
- Xcode 26 or later (Swift 6; the app icon is an Icon Composer document)
- At least one ACP agent. For Codex, sign in with `codex login`; for Claude Code, set up your Claude login and Node.js 22+. First-time setup of either may download its ACP adapter through npm. OpenCode and fx use their installed commands and existing authentication.

## Build and run

```sh
git clone https://github.com/mercho40/latch.git
cd latch
bash Scripts/test-mac-app.sh --release
open .build/LatchMacApp/Build/Products/Release/Latch.app
```

The script builds the app, checks its signature and entitlements, and runs the UI smoke test against mock agents before you open it. No signing account is needed; the build is ad-hoc signed with the hardened runtime. To work on it in Xcode instead, open `Apps/LatchMac/Latch.xcodeproj` and run the **Latch** scheme, or use the SwiftPM preview:

```sh
swift run --package-path Apps/LatchMac Latch
```

## Tests

None of these need network or model access:

```sh
swift test --package-path Packages/LatchACP
swift test --package-path Packages/LatchServiceProtocol
swift test --package-path Packages/LatchAgentCore
swift test --package-path Apps/LatchMac
```

[Building and testing](docs/building-and-testing.md) covers the bundle verification scripts, the cross-process XPC probe, benchmarks, and the opt-in live tests.

## Repository layout

| Path | Contents |
| --- | --- |
| `Apps/LatchMac` | The macOS app: Xcode project, the `LatchMacUI` package, and the XPC service host |
| `Packages/LatchACP` | ACP client: JSON-RPC over stdio, process transport, sessions, and a command-line probe |
| `Packages/LatchServiceProtocol` | Codable commands, events, and versioned envelopes between clients and the service |
| `Packages/LatchAgentCore` | Runtime registry, the agent service, and its XPC adapter, host, client, and event hub |
| `Scripts` | App bundle and cross-process XPC verification |
| `docs` | [Using Latch](docs/using-latch.md) · [Architecture](docs/architecture.md) · [Building and testing](docs/building-and-testing.md) · [Roadmap](docs/roadmap.md) |

There are no third-party dependencies.

## Security

Latch is not sandboxed: its purpose is to launch agent executables with access to the workspace you choose. Its approval sheets relay the agent's own permission requests and are not a sandbox; agents must enforce their own restrictions. See [SECURITY.md](.github/SECURITY.md) for the boundaries Latch does maintain and how to report a vulnerability.

## License

[Apache-2.0](LICENSE).
