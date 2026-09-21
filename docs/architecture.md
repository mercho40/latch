# Architecture

How the shipped macOS app is put together. The target multi-device design is in the [roadmap](roadmap.md).

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

## Embedded XPC service

The Xcode project builds two targets. `Latch` is the application; `LatchAgentXPCService` (bundle ID `sh.latch.mac.agent`) is an XPC service embedded in `Latch.app/Contents/XPCServices` that hosts one `LatchAgentService` for every session in the app. The app talks to it through `LatchAgentXPCClient`, one connection per session, and the service answers through `LatchAgentXPCHost`, which admits only same-user peers whose code signature satisfies `identifier "sh.latch.mac"`. All commands, streamed updates, and brokered permission requests cross that boundary; the UI never touches a runtime in-process. Disconnect stops only that session's runtime because the service is shared. If the connection is interrupted or invalidated, the session is shown as disconnected and a fresh connection is opened for the next attempt; nothing is replayed.

The embedded service sets `XPCService:JoinExistingSession`, so it shares the app's security session. Without it the service gets its own session, every keychain read from an agent fails with `errSecInteractionNotAllowed`, and agents that store provider credentials in the keychain — Claude Code among them — report a false "not signed in" on the first prompt even though their CLI is logged in. The service entry point lives in the `LatchAgentServiceHost` library of the app package so the same code can be unit-tested from SwiftPM. Both bundles are ad-hoc signed with hardened runtime and no sandbox. The SwiftPM preview (`swift run … Latch`) has no bundle and therefore hosts the service in-process; the bundled app does the same only when `LATCH_IN_PROCESS_AGENT=1` is set. The smoke test prints which transport it used and the service PID, and `Scripts/test-mac-app.sh` fails unless a separate service process handled it. Agent processes are children of the service; the app stops every runtime before it quits, but if the app or service is killed outright, running agents are not cleaned up yet. A Mach-service launch agent via `SMAppService` remains pending.

## Failures and authentication

Agent RPC failures retain bounded, redacted display text across XPC instead of becoming a generic command failure. Arbitrary error metadata, stderr, and native error details are not forwarded as display text; redaction of free-form agent prose is best effort. ACP authentication-required errors stop the affected session and show sign-in/reconnection guidance, rather than leaving a potentially stale authenticated session ready. Reconnect explicitly by selecting the harness after signing in; prompts are never automatically replayed. Existing chat remains visible until a new session connects.

## Permission requests

Permission requests during the active prompt appear in native sheets with selectable, scrollable agent-provided request details. Only explicitly offered, known ACP option kinds can be selected. Return and Escape cancel the request; approval has no default shortcut. “Always” uses the agent's scope, not a saved Latch preference. Pending decisions are cancelled on prompt completion, Stop, agent disconnection or exit, or quit; stale sheet callbacks cannot approve a different request. Requests outside the active session/prompt, duplicate option IDs, and requests beyond the 16-decision queue limit are cancelled. These controls are not a sandbox guarantee; agents must still enforce their own restrictions. Permission requests are brokered by the service: the runtime registry holds the agent's request, publishes it as a `permissionRequested` event with a Latch-local request ID, and the client answers with a `resolvePermission` command. Pending requests are closed with a `permissionClosed` event when answered, and cancelled when the prompt ends, is cancelled, or the runtime stops or exits; at most 16 requests may wait per runtime. Because no client touches the in-process runtime directly, the same UI can later run against an XPC-hosted service. Real-provider approval flows have not yet been validated.

## Model, effort, and mode

Model, Effort, and Permission Mode pop-ups inside the composer use the connected agent's advertised ACP `configOptions` (categories `model`, `thought_level`, and `mode`, including grouped choices), with legacy `models` / `session/set_model` and `modes` / `session/set_mode` support when needed. No model names, effort levels, or permission modes are hard-coded. Mode names and descriptions belong to the harness: a mode may affect planning or tool approval policy and is not a Latch sandbox or automatic approval of pending requests. Changing a setting refreshes the advertised option set; unsupported settings are hidden. Picks are confirmed by the agent, errors keep the last confirmed selection, and controls are disabled during prompts or pending changes. Configuration is session-local, follows ordered agent updates, and is cleared on disconnect. Mock tests cover these paths; real-provider model/effort/mode switching has not yet been validated.

## Streaming and history

Streaming history keeps incremental character counts while preserving Unicode grapheme boundaries and the existing retention limits. Text-only UI rendering is coalesced with a one-shot 16 ms delay; permission, configuration, cancellation, and connection-state updates remain immediate. Persistence reads current history, not a delayed render snapshot. Streamed text does not refresh the sidebar, attention state, pickers, or composer layout.

## Service layer

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

