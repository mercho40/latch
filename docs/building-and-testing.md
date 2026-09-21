# Building and testing

Everything here runs without model access unless it says otherwise.

## Build and run

Open `Apps/LatchMac/Latch.xcodeproj`, select the shared **Latch** scheme, and Run to build the macOS application. The target reuses the same entry point and `LatchMacUI` Swift package as the command-line preview; there is no separate UI implementation.

The local-development app uses bundle ID `sh.latch.mac`, requires macOS 15, and is ad-hoc signed with hardened runtime enabled and App Sandbox disabled. No signing account is required. Version `0.0.0` is a development placeholder, not a release. The app icon is an Icon Composer document at `Apps/LatchMac/Resources/Latch.icon`; `actool` compiles it into the layered macOS 26 appearance plus an `icns` fallback for macOS 15. Developer ID distribution, notarization, iOS targets, and background-service embedding remain pending.

The SwiftPM preview is still available:

```sh
swift run --package-path Apps/LatchMac Latch
```

## Unit tests and UI smoke test

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

## Performance benchmarks

Run the opt-in local performance comparisons (no network or model quota):

```sh
LATCH_HISTORY_BENCHMARK=1 swift test --package-path Apps/LatchMac -c release --filter ChatHistoryRegressionTests
LATCH_STREAMING_BENCHMARK=1 swift test --package-path Apps/LatchMac -c release --filter TranscriptRenderSchedulerTests
```

The history benchmark compares the frozen previous implementation against incremental bookkeeping, including retained snapshots. The rendering benchmark compares per-chunk and coalesced AppKit updates for one and eight sessions with simulated eight-chunk frames; it measures CPU work, not display FPS or end-to-end agent latency. Normal tests cover Unicode, eviction, state/transcript notification routing, pending-render cancellation, and final content.

## App bundle verification

Build and verify the actual app bundle with the active Xcode toolchain:

```sh
bash Scripts/test-mac-app.sh
bash Scripts/test-mac-app.sh --release
open .build/LatchMacApp/Build/Products/Debug/Latch.app
```

These scripts check bundle metadata, the ad-hoc signature, hardened runtime, and absence of the sandbox entitlement for both the app and the embedded XPC service, then run the app's mock-agent smoke test and require it to have gone through a separate service process. Nothing is installed or registered as a background service. The built apps remain under `.build/LatchMacApp/Build/Products/{Debug,Release}`. Release executables are arm64-only, stripped before signing, with separate dSYMs; the Release script checks the slice and the dSYM UUIDs, and still runs the actual Release smoke code. Debug builds remain unstripped.

The bundle smoke runs its executable directly with the terminal environment. Finder and Dock launches are also supported by filesystem-only discovery of common local agent locations and Node installations (including fnm, nvm, and Volta); Latch does not run shell startup files. For tools outside those locations, use Custom ACP Agent and choose an executable or wrapper. The mock smoke covers silent first launch, hidden built-in commands, draft retry, compact composer bounds at minimum and large window sizes, and genuine permission sheets; it does not validate live provider authentication or network setup.

## ACP probe

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

## XPC tests

The XCTest XPC tests use anonymous listeners within the test process. A mocked ACP lifecycle test verifies launch, session creation, progress events, listing during an active prompt, cancellation on the same XPC connection, and shutdown. Additional tests cover ordered multi-client delivery, reconnecting after all clients leave, slow-client isolation, oversized events, abortive teardown, a client/host round trip including a brokered permission, and rejection of unauthorized peers. A separate bundled-service probe validates cross-process XPC (below), and the application bundle test exercises the real embedded service. A Mach-service host and `SMAppService` registration are not implemented yet. A reply-encoding failure can occur after a command executes, so clients must not blindly retry mutations.

### Live backend smoke test

With Node/npm available on `PATH` and a working local Codex login, run:

```sh
LATCH_LIVE_CODEX_TEST=1 swift test --package-path Packages/LatchAgentCore --filter LatchAgentXPCLiveTests
```

This opt-in test uses network access and model quota. It launches the pinned Codex ACP adapter (`1.7.0`) in read-only mode in a temporary workspace, creates a session through XPC, verifies the streamed reply `Latch XPC connected.` and contiguous event sequences, then stops the runtime and checks that the registry is empty. It skips during normal test runs. The XPC listener and client are in the same test process; the ACP adapter is a real subprocess. This is not yet an installed-app or separate-service-process test.

### Separate-process XPC probe

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

