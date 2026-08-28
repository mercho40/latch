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

The service layer now has three small primitives:

- `ACPAgentRuntime` owns one ACP subprocess and connection, forwards session updates and stderr, enforces lifecycle state, and reports unexpected process termination.
- `AgentRuntimeRegistry` reserves stable Latch-local IDs, prevents duplicate launches, supervises multiple runtimes, exposes Codable status snapshots and an outbound event stream, evicts terminated processes, and supports individual or concurrent shutdown.
- `LatchServiceProtocol` defines shared Codable commands, responses, events, launch profiles, and versioned request/reply/event envelopes used across the macOS service and native clients.
- `LatchAgentService` dispatches those transport-neutral commands onto the runtime registry and exposes its single outbound event stream.

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
