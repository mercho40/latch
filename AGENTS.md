# Notes for coding agents

Latch is a native macOS client for ACP coding agents. Read [README.md](README.md) for what it does and [docs/architecture.md](docs/architecture.md) for how; this file is what you would otherwise learn the hard way.

## Layout

- `Apps/LatchMac` — the app. `Sources/LatchMacUI` holds nearly everything; `Sources/Latch` is the entry point and `Sources/LatchAgentXPCService` the embedded service's. The Xcode project and the SwiftPM package build the same sources.
- `Packages/LatchACP` → `Packages/LatchServiceProtocol` → `Packages/LatchAgentCore` — ACP client, wire types, then the service and its XPC layer. `LatchServiceProtocol` also holds the network protocol (`LatchRemoteProtocol`) and its Network.framework client (`LatchRemoteClient`); `LatchAgentCore` also builds `latch-server` (`LatchAgentServer`) for Linux and macOS. See [docs/server.md](docs/server.md).
- The UI never touches an agent runtime in-process. Local sessions go through `LatchAgentXPCClient`, even in the SwiftPM preview; remote sessions through `LatchRemoteClient`.

## Constraints

- AppKit only: no SwiftUI, no web views, no third-party dependencies.
- Swift 6 language mode. `@unchecked Sendable` appears only where a lock or an XPC/process boundary already guards the state; do not add one to quiet a diagnostic.
- The app: macOS 15 deployment target, arm64 only. The packages also build on Linux (x86_64 and aarch64), and the protocol and client for iOS.
- No model names, effort levels, or permission modes are hard-coded; they come from the connected agent.

## Verify

```sh
swift test --package-path Packages/LatchACP
swift test --package-path Packages/LatchServiceProtocol
swift test --package-path Packages/LatchAgentCore
swift test --package-path Apps/LatchMac
bash Scripts/test-mac-app.sh            # builds the bundle, runs the UI smoke over XPC and the remote smoke against a loopback latch-server
bash Scripts/test-linux.sh              # the package tests on Linux, in Apple's container tool
```

A change to anything the user sees is not verified until the bundle script passes; the SwiftPM preview has no bundle identifier and no separate service process.

## Things that look wrong and are not

- **The transcript uses TextKit 1 on purpose.** `TranscriptMessageView.arrange(width:)` and `ChatComposerScrollView.refreshHeight()` touch `layoutManager` deliberately. Both views are sized to their whole content, so TextKit 2's viewport layout buys nothing, and it measured up to 22× slower for re-measuring after an appended token. `NSLayoutManager`'s incremental invalidation is what the streaming path depends on.
- **Streaming writes a minimal edit, not `setAttributedString`.** `ChatMarkdown.Cache` re-parses from the first changed line and `TranscriptMessageView.apply` writes only the changed range. `cache.reusedLength` is the prefix `apply` may leave untouched — a starting point for the attribute walk, not the answer. The cache never resumes within two lines of a change because a prose line becomes a table header retroactively. `ChatMarkdownTests` proves resumed output equals a full render at every prefix; keep it green. It compares a structural signature because two renders of one table never compare equal.
- **`-Osize`, LTO, and a higher deployment target do not shrink the bundle.** All were measured and produced a byte-identical app. What moved it was arm64-only and `ASSETCATALOG_COMPILER_OPTIMIZATION = space`; most of what remains is the icon.
- **Quitting Latch stops local agents but only detaches remote ones.** A remote session's `RemoteBinding` is saved and the next launch attaches to the same runtime; closing the session is what stops it. `Scripts/test-mac-app.sh` fails if quitting stops the remote smoke's agent, and `RemoteSessionReattachTests` checks that quitting still stops an agent on this Mac.
- **On Linux, agents are not spawned with `Foundation.Process`.** `LinuxChildProcess` uses `posix_spawn` because Foundation's Process detects exit through a socket every descendant inherits (an agent with a background child was "running" until the child exited), passes on the spawning thread's signal mask, and leaks non-close-on-exec pipes between concurrent agents. Do not switch it back.

## Traps

- **Mock ACP agents are `sh` `case` statements matching the JSON Latch writes, and `JSONEncoder` orders dictionary keys randomly per process.** Never match two keys in one pattern such as `*"id":10*"selected"*`: it matches only sometimes, the mock never replies, and the test hangs forever. Match one key and nest a second `case`, as `SmokeAgent.permissionScript` does. If a test hangs intermittently, suspect this before suspecting concurrency.
- **The UI smoke test needs the app to become active.** When another app holds focus, the permission sheet never becomes key and AppKit drops its Return equivalent. The smoke falls back to Escape and prints a `UI SMOKE NOTE`; that note is environmental, not a regression. If the smoke fails at a key-window step, run it on a clean checkout before bisecting.
- **The embedded service needs `XPCService:JoinExistingSession`.** Without it every keychain read from an agent fails and Claude Code reports a false "not signed in".
- **A reply-encoding failure can happen after a command ran.** Do not add blind retries of mutating service commands.
- **Agents inherit the spawning thread's signal mask and ignored signals on Linux.** Swift concurrency threads block SIGTERM, SIGINT and SIGHUP, and `SIG_IGN` survives `exec`. Never set `SIG_IGN` in the server (SIGPIPE has a no-op handler instead); the spawner resets the mask and every disposition, so keep it that way.
- **Never block inside a Task on the server.** Sockets, `waitpid` and pipe reads belong on their own threads; a 1-vCPU VPS runs one task at a time, and one blocked task stalls every agent.
- **Remote commands are re-sent after a reconnect only because each is idempotent on the server** (turn IDs, same-ID launches, recorded session replies). A new remote command needs that property before the client may retry it; the no-blind-retries rule above still stands everywhere else.
- **The static musl build needs large thread stacks.** musl's 128 KiB default overflows on deeply nested JSON; `RemoteServer` gives its threads 1 MiB and `latch-server` links with an 8 MiB `PT_GNU_STACK`. `Scripts/build-linux-server.sh` checks the latter; keep both.
