# Building and testing

Everything here runs without model access unless it says otherwise.

## Build and run

Open `Apps/LatchMac/Latch.xcodeproj`, select the shared **Latch** scheme, and Run to build the macOS application. The target reuses the same entry point and `LatchMacUI` Swift package as the command-line preview; there is no separate UI implementation.

The local-development app uses bundle ID `dev.latchapp.mac`, requires macOS 15, and is ad-hoc signed with hardened runtime enabled and App Sandbox disabled. No signing account is required. The version is `MARKETING_VERSION` in the two xcconfigs; see [Releasing](#releasing). The app icon is an Icon Composer document at `Apps/LatchMac/Resources/Latch.icon`; `actool` compiles it into the layered macOS 26 appearance plus an `icns` fallback for macOS 15. iOS targets and a background service that outlives the app remain pending. There is no Developer ID signing or notarization, and none is planned.

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

These scripts check bundle metadata, the ad-hoc signature, hardened runtime, and absence of the sandbox entitlement for both the app and the embedded XPC service, then run the app's mock-agent smoke test and require it to have gone through a separate service process, then the [remote smoke](#remote-smoke-test) against a `latch-server` on loopback. Nothing is installed or registered as a background service. The built apps remain under `.build/LatchMacApp/Build/Products/{Debug,Release}`. Release executables are arm64-only, stripped before signing, with separate dSYMs; the Release script checks the slice and the dSYM UUIDs, and still runs the actual Release smoke code. Debug builds remain unstripped.

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

## Linux and latch-server

### Package tests on Linux

With [Apple's container tool](https://github.com/apple/container) installed and running (`container system start`):

```sh
bash Scripts/test-linux.sh
bash Scripts/test-linux.sh LatchAgentCore
bash Scripts/test-linux.sh --static
```

The script runs the `LatchACP`, `LatchServiceProtocol` and `LatchAgentCore` suites, or only the packages named, in one `swift:6.4.0-noble` container with 4 CPUs and 4 GB. Build products go under `.build/linux`, apart from the macOS builds; run one invocation at a time, because they share it. `--static` also installs the Swift 6.4.0 Static Linux SDK, checksum pinned, into a `latch-swiftpm` volume so it is downloaded once; builds `latch-server` for x86_64 and aarch64 musl; and runs `LatchServerExecutableTests` against the binary for the container's architecture. The first run pulls the image and needs network access.

Some tests exist on one platform only. `LinuxChildProcessTests` cover the Linux spawner: an agent spawned from a Swift concurrency thread starts with no blocked or ignored signals and no descriptor but its standard streams, stops on SIGTERM without being force-killed, and is reported gone promptly when a background child still holds its output. The client tests need Network.framework and run only on macOS.

### Server and protocol tests

`LatchAgentServerTests`, in `LatchAgentCore`, cover the replay hub and its journal, the socket layer byte for byte through a plain POSIX client, the token file, the listen policy, the command line, and agent resolution. On macOS, `RemoteServerClientTests` also runs `LatchRemoteRuntimeChannel` against the real server with a shell mock agent. Their mock agents follow the single-key `case` rule in [AGENTS.md](../AGENTS.md).

`LatchServerExecutableTests` runs the built `latch-server` as a process: `--version`, `token` and `pair`, two first runs agreeing on one token, SIGTERM stopping agents and exiting cleanly, SIGHUP closing connections after a rotation, and a deeply nested hello. It looks for the binary next to the test bundle, or at `LATCH_SERVER_BINARY`:

```sh
LATCH_SERVER_BINARY=/path/to/latch-server swift test --package-path Packages/LatchAgentCore --filter LatchServerExecutableTests
```

In `LatchServiceProtocol`, `LatchRemoteProtocolTests` pin the JSON of every frame, command, response and event with golden fixtures, check that unknown types, kinds, codes and keys still decode, and cover framing, tokens, pairing strings and the address checks. `LatchRemoteClientTests` run the client against a fake server: the destination check, backoff, reconnects, re-attaching, and turns that end while the link is down.

### Static binaries

```sh
bash Scripts/build-linux-server.sh
```

builds static musl `latch-server` binaries in `.build/linux-server/latch-server-x86_64` and `latch-server-aarch64`, with debug info stripped and the symbol table kept. It checks that the one for this machine starts and that both ask for 8 MiB thread stacks. It pins the same image and SDK as `Scripts/test-linux.sh`; change both together. [Running latch-server](server.md) covers installing one.

### iOS build check

The wire types and the client stay buildable for an iOS app:

```sh
swift build --package-path Packages/LatchServiceProtocol --target LatchRemoteProtocol \
  --triple arm64-apple-ios18.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
swift build --package-path Packages/LatchServiceProtocol --target LatchRemoteClient \
  --triple arm64-apple-ios18.0 --sdk "$(xcrun --sdk iphoneos --show-sdk-path)"
```

### App tests against latch-server

In `Apps/LatchMac`, `RemoteSessionLiveTests` and `RemoteSessionReattachTests` run sessions through the real window and model against `latch-server`'s hub and network layer, listening on 127.0.0.1 inside the test process, with shell mock agents. The live tests cover streaming, permissions, dropped links, a server that never answers, a refused token and an edited server, a server shutting down, and an agent stopped by another client. The re-attach tests run Latch twice against one server: quitting mid-turn, idle, or with a permission pending, then relaunching; a turn that ended while Latch was closed; a restarted server; an agent that exited or was stopped; evicted output; and closing and undoing. `RemoteSessionTests` and `ServersSettingsTests` cover remote locations, saving, the sidebar, attachments and the Servers pane.

### Remote smoke test

After the XPC smoke, `Scripts/test-mac-app.sh` builds `latch-server` for this Mac, starts it on a free loopback port with a throwaway config directory, and runs the bundled app with `--smoke-test-remote latch://127.0.0.1:PORT?token=… FOLDER`. The app adds that server, with a custom agent command running a shell mock agent it writes into the folder, and, through the real window, composer and sheet:

- creates a remote session, selected under the server in the sidebar;
- streams a reply, and approves a permission request in its sheet;
- drops the link mid-turn, checks that the banner says it is reconnecting while the agent finishes the turn on the server, then reconnects and checks that the output from while the link was down is replayed and that the prompt ran once;
- quits through the normal path, and checks that the quit saved the session's runtime, with the sequence it had reached, in a real session store on disk.

The smoke waits 30 seconds between reconnects, so the link comes back only when it asks. After the app has exited, the script checks that the agent is still running and that the server has not logged it stopped, then sends the server SIGTERM and requires it to exit 0 within ten seconds, log the runtime as stopped, and take the agent with it. The smoke does not relaunch the app; re-attaching is covered by `RemoteSessionReattachTests`. CI does not run it, since it does not run `Scripts/test-mac-app.sh`.

### Testing against a Linux server locally

To try the Mac app against the Linux build, run a static binary in Apple's container tool. The container runs as root, hence `--allow-root`, and has to listen on its own network address rather than loopback:

```sh
bash Scripts/build-linux-server.sh
container run -d --name latch-linux -v "$PWD/.build/linux-server:/opt/latch" swift:6.4.0-noble \
  /opt/latch/latch-server-aarch64 --allow-root --allow-unencrypted-network --listen 0.0.0.0:7428
container ls                      # the IP column is the container's address, such as 192.168.64.2/24
container exec latch-linux /opt/latch/latch-server-aarch64 pair --host CONTAINER-IP --allow-root
```

`CONTAINER-IP` is that address without its prefix length, such as `192.168.64.2`; `pair` refuses `192.168.64.2/24`. The subcommand has to come first, before any option. Paste the pairing string into Settings → Servers. The container's address is neither loopback nor Tailscale, so Latch refuses to send the token until the server's Allow unencrypted network is on; the traffic stays on the Mac's virtual network. Alternatively, forward a port on the Mac's 127.0.0.1 to the container's address and pair with `--host 127.0.0.1`, which needs no exception; `ssh -N -L 7428:CONTAINER-IP:7428 localhost` is one such forward, and needs Remote Login on in System Settings → General → Sharing. Do not rely on `container run --publish 127.0.0.1:…`: with container 1.4.1 it accepted connections on the Mac but never forwarded them. The image has no agents; give the server a custom agent command in Settings, or install one in the container.

The remote smoke can run against such a server too, through a loopback forward, since it never allows an unencrypted network: `Latch.app/Contents/MacOS/Latch --smoke-test-remote 'latch://127.0.0.1:PORT?token=…' FOLDER`. The app writes the mock agent into `FOLDER` on the Mac and the server runs it from its own filesystem, so mount the folder into the container at the same absolute path, symbolic links resolved (`/private/tmp`, not `/tmp`). The mount must be writable: the agent writes its process ID and logs into the folder, and the smoke reads them there to follow the turn and check that the prompt ran once.

### CI

Besides the macOS package tests, the app tests with the XPC probe, the site budget and the secret scan, CI runs:

- **Linux package tests:** the three package suites in `swift:6.4.0-noble` on x86_64 and arm64 runners.
- **Static Linux build:** both musl binaries; the x86_64 one must print its version and pass `LatchServerExecutableTests`.
- **iOS build check:** the two builds above.

## Releasing

Releases are built locally, because hosted CI runners cannot compile the app icon yet, and are ad-hoc signed: there is no Developer ID and no notarization.

1. Set `MARKETING_VERSION` in both `Apps/LatchMac/Configuration/App.xcconfig` and `AgentService.xcconfig`, and `LatchServerVersion.current` in `Packages/LatchAgentCore/Sources/LatchAgentServer/LatchServerVersion.swift`, commit, and push `main`.
2. Rehearse with `bash Scripts/release.sh --dry-run 0.2.0`. It runs the Release bundle verification and smoke test, archives the app with `ditto`, unpacks the archive again to check the signature survived, and leaves the zip, its `.sha256`, and the dSYMs in `.build/release/v0.2.0`.
3. Publish with `bash Scripts/release.sh 0.2.0`. It refuses unless the tree is clean, `main` matches `origin/main`, the tag is new, and both xcconfigs and `LatchServerVersion` carry the version; then it tags, pushes the tag, and creates the GitHub release with generated notes and the checksum.

Do not mark a release as a pre-release: `Scripts/install.sh` follows GitHub's "latest release", which skips pre-releases. To test the installer without publishing, point it at a local copy of the release layout:

```sh
mkdir -p /tmp/apps /tmp/rel/download/v0.2.0 && cp .build/release/v0.2.0/Latch-0.2.0.zip* /tmp/rel/download/v0.2.0/
LATCH_DOWNLOAD_BASE=file:///tmp/rel LATCH_VERSION=0.2.0 LATCH_INSTALL_DIR=/tmp/apps sh Scripts/install.sh
```

A copy installed that way shares the real session library in `~/Library/Application Support/Latch` if you launch it.

## The website

`site/` is latchapp.dev, deployed to Cloudflare Pages as it stands: there is no build step. It is one HTML file with its CSS and script inlined, system fonts, and no third-party requests, so the whole page arrives in the server's first flight and the screenshot is the only other download.

- `python3 Scripts/check-site.py` is what CI runs. It fails if the gzipped HTML passes 14 KB, if HTML plus the largest image passes 100 KB, if the page loads anything from another origin, if `site/install.sh` differs from `Scripts/install.sh`, or if the inline script no longer matches the hash in `site/_headers`.
- `bash Scripts/build-site-images.sh` regenerates `site/img` from `docs/images/latch-{light,dark}.png` (needs `cwebp`). The directory is named for a hash of its sources, so images are cached forever and a new screenshot gets new URLs; the script rewrites the page to match.
- After changing `Scripts/install.sh`, copy it to `site/install.sh`. After changing the inline script, update the hash the check prints.
- To look at it: `cd site && python3 -m http.server`.

