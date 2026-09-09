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

Run the single-window AppKit preview:

```sh
swift run --package-path Apps/LatchMac Latch
```

Choose a workspace folder, enter an absolute ACP executable and its arguments, and connect. The window provides a selectable streamed transcript, multiline composer, Send (⌘ Return), Cancel, and Disconnect. Standard AppKit controls, system colors, and fonts follow macOS appearance; there is no web view or JavaScript UI.

For example, with Node/npm on your terminal's `PATH` and a local Codex login:

```text
/usr/bin/env INITIAL_AGENT_MODE=read-only npx -y @agentclientprotocol/codex-acp@1.7.0
```

Commands support quotes and backslash escaping, not shell expansion or pipelines. Nothing launches until you press Connect. This preview hosts `LatchAgentService` in-process, not over XPC, and requests agent shutdown on disconnect/quit. It has no persistence or background-service installation. The current transport requests termination but does not yet force-kill an unresponsive process.

Permission requests during the active prompt appear in native sheets with selectable, scrollable agent-provided request details. Only explicitly offered, known ACP option kinds can be selected. Return and Escape cancel the request; approval has no default shortcut. “Always” uses the agent's scope, not a saved Latch preference. Pending decisions are cancelled on prompt completion, Cancel, Disconnect, agent exit, or quit; stale sheet callbacks cannot approve a different request. Requests outside the active session/prompt, duplicate option IDs, and requests beyond the 16-decision queue limit are cancelled. These controls are not a sandbox guarantee; agents must still enforce their own restrictions. Real-provider approval flows have not yet been validated.

Verify the preview without model access:

```sh
swift test --package-path Apps/LatchMac
swift run --package-path Apps/LatchMac Latch --smoke-test
```

The smoke test opens a real window, exercises AppKit controls and permission sheets (including Escape dismissal and explicit approval) with mock ACP agents, and quits. It does not automate the folder picker or establish visual/accessibility conformance. `Apps/LatchMac` is a standalone Swift package preview; the eventual Xcode application project is still pending.

The service layer now has these small primitives:

- `ACPAgentRuntime` owns one ACP subprocess and connection, forwards session updates and stderr, enforces lifecycle state, and reports unexpected process termination.
- `AgentRuntimeRegistry` reserves stable Latch-local IDs, prevents duplicate launches, supervises multiple runtimes, exposes Codable status snapshots and an outbound event stream, evicts terminated processes, and supports individual or concurrent shutdown.
- `LatchServiceProtocol` defines shared Codable commands, responses, events, launch profiles, and versioned request/reply/event envelopes used across the macOS service and native clients.
- `LatchAgentService` dispatches those transport-neutral commands onto the runtime registry and exposes its single outbound event stream.
- `LatchServiceCodec` checks JSON payload byte limits before decoding and after encoding.
- `LatchAgentXPC` (a macOS-only target in `LatchAgentCore`) adapts bounded `Data` requests to versioned service replies. Codec failures use sanitized transport errors; command failures remain in correlated replies.
- `LatchAgentXPCEventHub` consumes the service event stream once and broadcasts versioned, sequenced events to attached clients. Each client acknowledges delivery, with one event in flight and a configurable per-client queue limit (128 events including the in-flight event by default). Slow clients are disconnected; an unencodable event disconnects all current recipients rather than silently skipping it.

Start one event hub at service startup. After authorizing a peer, configure its request adapter and transfer the unresumed connection to `attach`; the hub installs its remote event interface and lifecycle handlers, then resumes it. Clients export `LatchAgentXPCEventReceiver` using the hub's interface. The host must explicitly shut down the hub before releasing it.

Events go to clients attached when the hub consumes them; upstream buffered events may predate attachment. There is no replay API. Per-client queues are bounded, but the upstream service stream is not. Shutdown or source completion aborts pending delivery. Clients must treat interruption/invalidation as a stale view; reconciliation and transcript replay are not implemented yet.

The XCTest XPC tests use anonymous listeners within the test process. A mocked ACP lifecycle test verifies launch, session creation, progress events, listing during an active prompt, cancellation on the same XPC connection, and shutdown. Additional tests cover ordered multi-client delivery, reconnecting after all clients leave, slow-client isolation, oversized events, and abortive teardown. A separate bundled-service probe validates cross-process XPC (below). Production peer authorization, a Mach-service host, and `SMAppService` registration are not implemented yet. A reply-encoding failure can occur after a command executes, so clients must not blindly retry mutations.

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
