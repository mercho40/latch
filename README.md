# Latch

Native remote control for coding agents.

Latch lets you start, monitor, and control coding-agent sessions on your Mac from an iPhone or iPad. It is local-first, open source, lightweight, and agent-harness agnostic.

## Product thesis

Coding agents should keep running where the code lives while their control surface follows you.

Latch is not another agent harness. It is a native client and secure bridge for any ACP-compatible agent. Server presets make common agents easy to launch, while a generic command profile keeps the protocol boundary vendor-neutral.

## Principles

- Fully native Apple-platform interfaces
- Local-first; no account or hosted service required
- Direct connections whenever possible
- Open protocols and portable session data
- Harness and model agnostic
- Small memory, energy, and binary footprint
- Explicit, understandable security boundaries
- Fast, dense, restrained interface

## Initial platforms

- **macOS:** Swift + AppKit
- **iOS/iPadOS:** Swift + UIKit, using SwiftUI selectively where it simplifies non-critical UI
- **Agent integration:** Agent Client Protocol (ACP)
- **First conformance target:** `fx acp`, through the same generic command profile available to every ACP server

Zig is not part of the initial stack. Introduce it only if profiling or portability requirements justify a small native core.

## MVP

A user can:

1. Install Latch on a Mac and iPhone.
2. Pair both devices securely.
3. Select a local project on the Mac.
4. Start or resume a session using a configured ACP server.
5. Stream agent messages and tool activity.
6. Send prompts from either device.
7. Approve or deny permission requests.
8. Cancel a running prompt.
9. See attention requests immediately while the iOS app is connected.

### Explicitly out of scope for v0.1

- Hosted accounts or mandatory cloud infrastructure
- Team collaboration
- Embedded code editor
- General remote desktop or shell
- File browser beyond selecting a workspace
- Supporting non-ACP terminal output parsers
- Running coding agents directly on iOS
- Plugin marketplace

## Architecture

```text
┌──────────────────┐        encrypted connection       ┌──────────────────┐
│ Latch for iOS    │ ◀────────────────────────────────▶ │ Latch Agent      │
│ Native client    │                                    │ macOS launchd svc │
└──────────────────┘                                    └────────┬─────────┘
                                                                 │ ACP / stdio
                                                        ┌────────▼─────────┐
┌──────────────────┐       local IPC                    │ ACP server       │
│ Latch for macOS  │ ◀────────────────────────────────▶ │ per session      │
│ Native client    │                                    └────────┬─────────┘
└──────────────────┘                                             │
                                                        ┌────────▼─────────┐
                                                        │ Repo + local     │
                                                        │ development tools│
                                                        └──────────────────┘
```

### Components

#### Latch Agent

A lightweight background service managed by `launchd` that:

- Runs independently of the visible macOS app
- Launches and supervises arbitrary configured ACP server processes
- Maintains one ACP process per active session, using that session's workspace as the process working directory
- Enforces ACP's limit of one active session and one active prompt per connection
- Translates ACP events into Latch's transport protocol
- Owns pairing, authentication, and connection state
- Persists only the minimum session metadata needed by Latch
- Exposes a local IPC interface to the macOS app

#### macOS app

- Installs and configures the background service
- Manages workspaces and paired devices
- Provides the same session control surface as iOS
- Displays connection, agent, and security state

#### iOS app

- Discovers and pairs with Macs
- Lists workspaces and sessions
- Renders streamed messages, tools, and permission requests
- Sends prompts, approvals, denials, and cancellation requests
- Surfaces attention requests while connected; background push notifications require the later relay service

## Connectivity plan

### v0.1: local network

- Bonjour discovery
- Network.framework transport
- Device-to-device pairing with a QR code or short verification code
- Mutual authentication using device-generated keys stored in Keychain
- Encrypted connection with certificate/key pinning

### Public alpha: remote access

- Support connections over user-managed private networking such as Tailscale
- Accept a manually configured Mac hostname or tailnet address
- Do not bundle the Tailscale SDK or make Tailscale a product dependency
- Defer NAT traversal and a hosted relay until the local product is validated

A future relay must never receive plaintext prompts, source code, tool output, or approval contents.

## ACP mapping

Latch should preserve ACP semantics rather than inventing a second agent abstraction prematurely:

- `session/list` → session list
- `session/new` → new session
- `session/load` / `session/resume` → open session
- `session/prompt` → send message
- `session/cancel` → stop action
- `session/set_mode` → permission mode
- ACP updates → streamed messages and tool state
- ACP permission request → native approval sheet

A thin internal adapter can isolate ACP version changes and allow other structured harness adapters later.

## Security model

- The coding agent and repository remain on the Mac.
- The iOS app receives only data intentionally forwarded by the Latch Agent.
- Pairing grants control over agent actions and must be treated as privileged access.
- Every command is authenticated and scoped to a paired device.
- Permission decisions clearly show the target Mac, workspace, session, tool, and arguments.
- Revoking a device immediately invalidates its credentials.
- No listening public port is enabled by default.
- Sensitive values should not be written to notification bodies or diagnostic logs.

## First milestones

### M0 — protocol spike

- [x] Launch a configured ACP command from a small macOS command-line prototype, validated against the Codex ACP adapter
- [x] Complete ACP initialization
- [x] Create a session and send a prompt
- [x] Print streamed messages, tool updates, and permission requests
- [x] Cancel an active prompt

The generic ACP v1 path is complete. Direct `fx acp` conformance remains blocked on an AI Gateway credential because fx 0.0.6 does not use its Codex subscription session for ACP.

Run the current initialization probe from the workspace to validate a configured ACP server without sending a model prompt:

```sh
swift run --package-path Packages/LatchACP LatchACPProbe /absolute/path/to/fx acp
swift run --package-path Packages/LatchACP LatchACPProbe /usr/bin/env npx -y @agentclientprotocol/codex-acp
```

Add `--prompt <text> --` before the command to create a session and verify streaming. The probe rejects any requested tool permission. Add `--cancel-after-ms <milliseconds>` to cancel the active turn on a timer:

```sh
swift run --package-path Packages/LatchACP LatchACPProbe \
  --prompt "Reply exactly: Latch ACP connected. Do not use tools." -- \
  /usr/bin/env npx -y @agentclientprotocol/codex-acp

swift run --package-path Packages/LatchACP LatchACPProbe \
  --prompt "Analyze the repository without tools." --cancel-after-ms 100 -- \
  /usr/bin/env INITIAL_AGENT_MODE=read-only npx -y @agentclientprotocol/codex-acp
```

The probe uses the current directory as the ACP server's primary workspace. The Codex adapter can use an existing ChatGPT subscription login. In fx 0.0.6, `fx acp` requires Vercel AI Gateway credentials from `fx login` or `fx setup`; a Codex subscription login alone does not satisfy ACP initialization.

### M1 — local Mac application

- AppKit shell and session UI
- Workspace management
- Background-service lifecycle
- Local IPC between app and service
- Reliable process recovery

#### Native UI preview

Open `Apps/LatchMac/Latch.xcodeproj`, select the shared **Latch** scheme, and Run to build the macOS application. The target reuses the same entry point and `LatchMacUI` Swift package as the command-line preview; there is no separate UI implementation.

The local-development app uses bundle ID `sh.latch.mac`, requires macOS 15, and is ad-hoc signed with hardened runtime enabled and App Sandbox disabled. No signing account is required. Version `0.0.0` is a development placeholder, not a release. The app icon is an Icon Composer document at `Apps/LatchMac/Resources/Latch.icon`; `actool` compiles it into the layered macOS 26 appearance plus an `icns` fallback for macOS 15. Developer ID distribution, notarization, iOS targets, and background-service embedding remain pending.

The SwiftPM preview is still available:

```sh
swift run --package-path Apps/LatchMac Latch
```

Choose a workspace folder and select fx, Codex, Claude Code, OpenCode, or a custom ACP agent. Opening a session connects its locally discovered default harness; selecting another harness connects it immediately. Model and effort options load before the first prompt. Send only sends to an already-connected session and never starts or retries a connection. Stop cancels setup or the active response without losing an unsent draft. Reselect the harness to rescan and retry; there is no separate settings or refresh control. Reselecting an already-connected harness rescans but keeps the live session, its history, and any unsent draft. You can switch harnesses while idle or connecting. New sessions remain available from the toolbar or ⌘N. Close one with ⌘⌫, the sidebar's context menu, or File → Close Session: its agent stops and it leaves the saved library, and ⌘Z reopens it in the same place with its title, transcript, unsent draft, and agent context. The window reopens at the size and position it was left at.

Sessions keep running while Latch is behind another app, so attention comes to you. A permission request, or a finished turn, in a session you are not looking at posts a notification; Allow Once and Reject Once sit on the notification itself, while clicking its body only brings the session forward, because approving something unread is not a decision. Notification text names the workspace folder and nothing else — no prompt text, tool name, or argument. The Dock icon badges how many sessions are waiting for a decision and bounces once when one arrives in the background. A menu bar extra lists every session with its state and leads back to any of them; hide it from its own menu, and View → Show in Menu Bar brings it back. While it is showing, closing the window no longer quits Latch. The SwiftPM preview has no bundle identifier and therefore posts no notifications; the Dock badge and the menu bar extra still work.

The Session menu carries the session commands with keyboard equivalents: Stop (⌘.), Fork Session (⌘⇧N), Disconnect, Rename…, Reveal Workspace in Finder, Open Workspace in Terminal, and Previous/Next Session (⌥⌘↑ and ⌥⌘↓), each disabled when it cannot run. A folder dropped on the sidebar or on the empty detail pane opens a session in it, as does one dropped on the Dock icon or opened from the Finder, and File → Open Recent lists the workspaces you have opened. Right-clicking a session offers rename, fork, reveal, open in Terminal, copy path, and close; right-clicking a workspace offers the workspace actions alone. Renaming is inline in the row, and Escape keeps the previous name.

⌘F opens a find bar over the conversation. It matches the text that is actually on screen, case- and diacritic-insensitively, in reading order; ⌘G and ⇧⌘G step through matches and wrap at either end, showing each in a native find indicator. Collapsed tool rows are not searched because there is nothing on screen to reveal, and Escape or Done closes the bar. A prompt in flight is registered as user-initiated activity so App Nap cannot throttle streaming while Latch is in the background; the Mac may still sleep on its own schedule. Saving sessions holds off sudden termination for the length of the write.

Built-in setup is automatic: Latch reuses an installed integration or silently starts the pinned fallback on first connection. There is no installation dialog or adapter confirmation, and built-in command paths are never shown. For Codex, sign in with `codex login`; for Claude Code, set up your Claude login and Node.js 22+. First-time setup may need Node.js with npm and internet access. fx and OpenCode use their installed commands and existing provider authentication. Missing prerequisites and startup failures appear inline; after installing a prerequisite, select the agent again to rescan and retry.

The quiet native chat uses a centered content column, selectable replies, and compact tool updates. The window resizes to the full screen; the column stays centered at its maximum width instead of stretching, and no content constraint may become the window's maximum width. Process diagnostics are not included in the conversation. The composer shares that column and offers large, rounded native model, effort, and permission-mode pop-ups only where supported. Controls have 36-point hit targets and 14-point text, wrapping onto another row in narrow windows rather than being squeezed. Return or ⌘ Return sends; Shift Return inserts a newline; Stop cancels the active response. Each composer keeps its own undo stack, so ⌘Z there edits that draft and never reaches the session list. Spelling is checked, but nothing is rewritten: autocorrect, text replacement, and quote and dash substitution stay off for paths, flags, and identifiers. The header carries only the harness pop-up and status text. Native Markdown supports a subset of headings, emphasis, lists, quotes, links, and fenced code; it is not a browser or full CommonMark renderer. HTML and remote resources are not rendered or loaded. Per-message Copy preserves the original Markdown, while normal text selection copies the rendered text. Edit → Copy Conversation copies the retained messages and tool activity. Streaming follows the bottom unless you scroll up, with Jump to Latest to return. History is bounded to 400 messages / 200,000 text characters and is not persisted. System colors and fonts follow macOS appearance; there is no web view or JavaScript UI.

Custom ACP Agent reveals a native editable command field and executable browser for arbitrary ACP servers, shown only for that selection. Finish editing the command (Return or leave the field), or choose an executable, to connect; typing alone does not launch it. Commands support quotes and backslash escaping, not shell expansion or pipelines. It has no persistence or background-service installation. On disconnect the transport closes stdin and sends SIGTERM, then force-kills the agent process if it has not exited within five seconds.

#### Embedded XPC service

Agent RPC failures retain bounded, redacted display text across XPC instead of becoming a generic command failure. Arbitrary error metadata, stderr, and native error details are not forwarded as display text; redaction of free-form agent prose is best effort. ACP authentication-required errors stop the affected session and show sign-in/reconnection guidance, rather than leaving a potentially stale authenticated session ready. Reconnect explicitly by selecting the harness after signing in; prompts are never automatically replayed. Existing chat remains visible until a new session connects.

The Xcode project builds two targets. `Latch` is the application; `LatchAgentXPCService` (bundle ID `sh.latch.mac.agent`) is an XPC service embedded in `Latch.app/Contents/XPCServices` that hosts one `LatchAgentService` for every session in the app. The app talks to it through `LatchAgentXPCClient`, one connection per session, and the service answers through `LatchAgentXPCHost`, which admits only same-user peers whose code signature satisfies `identifier "sh.latch.mac"`. All commands, streamed updates, and brokered permission requests cross that boundary; the UI never touches a runtime in-process. Disconnect stops only that session's runtime because the service is shared. If the connection is interrupted or invalidated, the session is shown as disconnected and a fresh connection is opened for the next attempt; nothing is replayed.

The embedded service sets `XPCService:JoinExistingSession`, so it shares the app's security session. Without it the service gets its own session, every keychain read from an agent fails with `errSecInteractionNotAllowed`, and agents that store provider credentials in the keychain — Claude Code among them — report a false "not signed in" on the first prompt even though their CLI is logged in. The service entry point lives in the `LatchAgentServiceHost` library of the app package so the same code can be unit-tested from SwiftPM. Both bundles are ad-hoc signed with hardened runtime and no sandbox. The SwiftPM preview (`swift run … Latch`) has no bundle and therefore hosts the service in-process; the bundled app does the same only when `LATCH_IN_PROCESS_AGENT=1` is set. The smoke test prints which transport it used and the service PID, and `Scripts/test-mac-app.sh` fails unless a separate service process handled it. Agent processes are children of the service; the app stops every runtime before it quits, but if the app or service is killed outright, running agents are not cleaned up yet. A Mach-service launch agent via `SMAppService` remains pending.

Permission requests during the active prompt appear in native sheets with selectable, scrollable agent-provided request details. Only explicitly offered, known ACP option kinds can be selected. Return and Escape cancel the request; approval has no default shortcut. “Always” uses the agent's scope, not a saved Latch preference. Pending decisions are cancelled on prompt completion, Stop, agent disconnection or exit, or quit; stale sheet callbacks cannot approve a different request. Requests outside the active session/prompt, duplicate option IDs, and requests beyond the 16-decision queue limit are cancelled. These controls are not a sandbox guarantee; agents must still enforce their own restrictions. Permission requests are brokered by the service: the runtime registry holds the agent's request, publishes it as a `permissionRequested` event with a Latch-local request ID, and the client answers with a `resolvePermission` command. Pending requests are closed with a `permissionClosed` event when answered, and cancelled when the prompt ends, is cancelled, or the runtime stops or exits; at most 16 requests may wait per runtime. Because no client touches the in-process runtime directly, the same UI can later run against an XPC-hosted service. Real-provider approval flows have not yet been validated.

Model, Effort, and Permission Mode pop-ups inside the composer use the connected agent's advertised ACP `configOptions` (categories `model`, `thought_level`, and `mode`, including grouped choices), with legacy `models` / `session/set_model` and `modes` / `session/set_mode` support when needed. No model names, effort levels, or permission modes are hard-coded. Mode names and descriptions belong to the harness: a mode may affect planning or tool approval policy and is not a Latch sandbox or automatic approval of pending requests. Changing a setting refreshes the advertised option set; unsupported settings are hidden. Picks are confirmed by the agent, errors keep the last confirmed selection, and controls are disabled during prompts or pending changes. Configuration is session-local, follows ordered agent updates, and is cleared on disconnect. Mock tests cover these paths; real-provider model/effort/mode switching has not yet been validated.

Verify the preview without model access:

```sh
swift test --package-path Apps/LatchMac
swift run --package-path Apps/LatchMac Latch --smoke-test
```

The smoke test opens a real window, exercises AppKit controls and permission sheets (including Escape dismissal and explicit approval) with mock ACP agents, closes a session and undoes it, searches a real transcript, checks the menu bar listing, and quits. It never posts a notification or claims a slot in the menu bar, though it does exercise the Dock badge. It does not automate the folder picker or establish visual/accessibility conformance. When the app cannot become active (another app holds focus on recent macOS), the permission sheet never becomes key and AppKit drops its Return equivalent; the smoke then falls back to Escape, prints a note that Return-cancels was not verified, and still asserts that no approval button owns Return. Package unit tests remain in SwiftPM; the shared application scheme does not yet contain an Xcode test target.

With a working local Codex login, an opt-in live test drives the native `SessionModel` against the pinned Codex adapter in a temporary workspace. It checks pre-prompt model and effort changes, a streamed no-tools reply, cancellation, disconnect/reconnect, and a real permission round trip (one approved write, one rejected write). It uses network access and model quota and skips during normal runs:

```sh
LATCH_LIVE_CODEX=1 swift test --package-path Apps/LatchMac --filter LiveCodexIntegrationTests
```

Streaming history keeps incremental character counts while preserving Unicode grapheme boundaries and the existing retention limits. Text-only UI rendering is coalesced with a one-shot 16 ms delay; permission, configuration, cancellation, and connection-state updates remain immediate. Persistence reads current history, not a delayed render snapshot. Streamed text does not refresh the sidebar, attention state, pickers, or composer layout.

Run the opt-in local performance comparisons (no network or model quota):

```sh
LATCH_HISTORY_BENCHMARK=1 swift test --package-path Apps/LatchMac -c release --filter ChatHistoryRegressionTests
LATCH_STREAMING_BENCHMARK=1 swift test --package-path Apps/LatchMac -c release --filter TranscriptRenderSchedulerTests
```

The history benchmark compares the frozen previous implementation against incremental bookkeeping, including retained snapshots. The rendering benchmark compares per-chunk and coalesced AppKit updates for one and eight sessions with simulated eight-chunk frames; it measures CPU work, not display FPS or end-to-end agent latency. Normal tests cover Unicode, eviction, state/transcript notification routing, pending-render cancellation, and final content.

Build and verify the actual app bundle with the active Xcode toolchain:

```sh
bash Scripts/test-mac-app.sh
bash Scripts/test-mac-app.sh --release
open .build/LatchMacApp/Build/Products/Debug/Latch.app
```

These scripts check bundle metadata, the ad-hoc signature, hardened runtime, and absence of the sandbox entitlement for both the app and the embedded XPC service, then run the app's mock-agent smoke test and require it to have gone through a separate service process. Nothing is installed or registered as a background service. The built apps remain under `.build/LatchMacApp/Build/Products/{Debug,Release}`. Release executables are stripped before signing while retaining both arm64 and x86_64 slices and separate dSYMs; the Release script checks their UUIDs and still runs the actual Release smoke code. Debug builds remain unstripped.

The bundle smoke runs its executable directly with the terminal environment. Finder and Dock launches are also supported by filesystem-only discovery of common local agent locations and Node installations (including fnm, nvm, and Volta); Latch does not run shell startup files. For tools outside those locations, use Custom ACP Agent and choose an executable or wrapper. The mock smoke covers silent first launch, hidden built-in commands, draft retry, compact composer bounds at minimum and large window sizes, and genuine permission sheets; it does not validate live provider authentication or network setup.

The service layer now has these small primitives:

- `ACPAgentRuntime` owns one ACP subprocess and connection, forwards session updates and stderr, enforces lifecycle state, and reports unexpected process termination.
- `AgentRuntimeRegistry` reserves stable Latch-local IDs, prevents duplicate launches, supervises multiple runtimes, exposes Codable status snapshots and an outbound event stream, evicts terminated processes, and supports individual or concurrent shutdown.
- `LatchServiceProtocol` defines shared Codable commands, responses, events, launch profiles, and versioned request/reply/event envelopes used across the macOS service and native clients.
- `LatchAgentService` dispatches those transport-neutral commands, including permission resolutions, onto the runtime registry and exposes its single outbound event stream.
- `LatchServiceCodec` checks JSON payload byte limits before decoding and after encoding.
- `LatchAgentXPC` (a macOS-only target in `LatchAgentCore`) adapts bounded `Data` requests to versioned service replies. Codec failures use sanitized transport errors; command failures remain in correlated replies.
- `LatchAgentXPCEventHub` consumes the service event stream once and broadcasts versioned, sequenced events to attached clients. Each client acknowledges delivery, with one event in flight and a configurable per-client queue limit (128 events including the in-flight event by default). Slow clients are disconnected; an unencodable event disconnects all current recipients rather than silently skipping it.

Start one event hub at service startup. After authorizing a peer, configure its request adapter and transfer the unresumed connection to `attach`; the hub installs its remote event interface and lifecycle handlers, then resumes it. Clients export `LatchAgentXPCEventReceiver` using the hub's interface. The host must explicitly shut down the hub before releasing it.

Events go to clients attached when the hub consumes them; upstream buffered events may predate attachment. There is no replay API. Per-client queues are bounded, but the upstream service stream is not. Shutdown or source completion aborts pending delivery. Clients must treat interruption/invalidation as a stale view; reconciliation and transcript replay are not implemented yet.

- `LatchAgentXPCClient` is the reusable client side: correlated requests, `LatchAgentFailure` surfaced as thrown errors, and a single-consumer event stream that finishes on interruption, invalidation, or an out-of-sequence event.
- `LatchAgentXPCHost` is the reusable listener delegate: it owns the service, adapter, and hub, runs a synchronous admission check, applies an optional code-signing requirement before resuming a peer, and shuts everything down on request.

The XCTest XPC tests use anonymous listeners within the test process. A mocked ACP lifecycle test verifies launch, session creation, progress events, listing during an active prompt, cancellation on the same XPC connection, and shutdown. Additional tests cover ordered multi-client delivery, reconnecting after all clients leave, slow-client isolation, oversized events, abortive teardown, a client/host round trip including a brokered permission, and rejection of unauthorized peers. A separate bundled-service probe validates cross-process XPC (below), and the application bundle test exercises the real embedded service. A Mach-service host and `SMAppService` registration are not implemented yet. A reply-encoding failure can occur after a command executes, so clients must not blindly retry mutations.

#### Live backend smoke test

With Node/npm available on `PATH` and a working local Codex login, run:

```sh
LATCH_LIVE_CODEX_TEST=1 swift test --package-path Packages/LatchAgentCore --filter LatchAgentXPCLiveTests
```

This opt-in test uses network access and model quota. It launches the pinned Codex ACP adapter (`1.7.0`) in read-only mode in a temporary workspace, creates a session through XPC, verifies the streamed reply `Latch XPC connected.` and contiguous event sequences, then stops the runtime and checks that the registry is empty. It skips during normal test runs. The XPC listener and client are in the same test process; the ACP adapter is a real subprocess. This is not yet an installed-app or separate-service-process test.

#### Separate-process XPC probe

On macOS with Xcode selected, run:

```sh
bash Scripts/test-xpc-process.sh
```

The script builds `LatchXPCProcessProbe`, assembles an ad-hoc-signed temporary app with an embedded XPC service, and lets macOS launch the service. It asserts distinct client/service PIDs and exercises runtime launch, session creation, a streamed progress event, listing during a pending prompt, cancellation, runtime stop, and service shutdown. Both fixture processes have a 120-second watchdog. The temporary bundle is removed when the script exits.

By default this deterministic test uses a shell mock ACP agent and requires no model access. To verify the complete client → separate XPC service → real Codex ACP → streamed client event path, run:

```sh
bash Scripts/test-xpc-process.sh --live-codex
```

Live mode uses the local Codex login, network access, and model quota. It launches the pinned adapter in read-only mode in a temporary workspace and verifies `Latch cross-process connected.` with `end_turn`, sequenced events, runtime stop, and service shutdown. Only the invoking terminal's `PATH` is forwarded as a launch setting because launchd does not inherit it; the terminal's full environment is not forwarded.

Neither mode installs a launch agent. The fixture's same-user admission check and test-only shutdown method are not production security policy. These tests do not establish full ACP conformance, live permission-approval behavior, `SMAppService` installation, notarization, or native application UI behavior.

To run every package test, including the separate opt-in XCTest live smoke test:

```sh
swift test --package-path Packages/LatchACP
swift test --package-path Packages/LatchServiceProtocol
LATCH_LIVE_CODEX_TEST=1 swift test --package-path Packages/LatchAgentCore
```

### M2 — paired iPhone client

- Bonjour discovery and secure pairing
- Session list and transcript streaming
- Prompt, cancel, approve, and deny actions
- Reconnection and basic offline state

### M3 — usable alpha

- Tailscale-compatible remote connections using a manually configured address
- In-app attention alerts while the iOS client is connected
- Session restoration
- Diagnostics and exportable logs with redaction
- Signed and notarized builds with an installation/update path
- Threat-model review

Background iOS push notifications are deferred until Latch has an optional relay or another trusted APNs provider. A direct Mac-to-iPhone connection cannot reliably wake a suspended iOS application.

## Architecture decisions

1. **Deployment targets:** macOS 15 and iOS/iPadOS 18.
2. **Repository layout:** one Xcode project containing the application targets, backed by local Swift packages for the ACP client, transport protocol, models, and reusable UI-independent logic.
3. **Local IPC:** an XPC Mach service between the macOS app and Latch Agent. The remote transport remains a separate Network.framework protocol.
4. **Distribution:** direct signed and notarized macOS builds with Hardened Runtime, outside the Mac App Store and without App Sandbox for v0.1. Repository access remains explicit and user-selected.
5. **Background service:** bundle Latch Agent inside the macOS application and register it as a per-user launch agent with `SMAppService`. The app owns installation, status, updates, and removal.
6. **Initial remote access:** work over user-managed Tailscale connections without bundling its SDK. LAN use requires no third-party service.
7. **License:** Apache-2.0, with Developer Certificate of Origin sign-off and no Contributor License Agreement.

These decisions can be revisited only when a prototype exposes a concrete platform constraint.

## Near-term validation

Before building the full interface, validate these assumptions:

- ACP exposes enough structured permission information for a safe mobile approval UI.
- An ACP process can survive client reconnections without losing the active session.
- The background service can reliably supervise multiple workspace processes.
- Streaming remains responsive across iPhone network transitions.
- Users value remote approvals and monitoring enough without remote code editing.
