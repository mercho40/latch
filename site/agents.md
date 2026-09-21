# Latch

Latch is a native macOS client for coding agents that speak the Agent Client Protocol (ACP): Codex, Claude Code, OpenCode, fx, or any other ACP server. It is an AppKit app with no web view, no account and no hosted service. Source: https://github.com/mercho40/latch (Apache-2.0).

## Install

Requires macOS 15 or later on Apple silicon.

```sh
curl -fsSL https://latchapp.dev/install.sh | sh
```

The script downloads the latest GitHub release, checks its SHA-256 and code signature, and installs `Latch.app` into `/Applications` (or `~/Applications` if that is not writable). Run it again to update. `LATCH_VERSION=0.1.0` pins a release; `LATCH_INSTALL_DIR=/path` changes the destination.

Latch is signed ad hoc and is not notarized. Installing with `curl` does not set the quarantine attribute, so there is no Gatekeeper prompt. A zip downloaded in a browser needs `xattr -dr com.apple.quarantine /Applications/Latch.app` before it will open.

## Build from source

Requires Xcode 27.

```sh
git clone https://github.com/mercho40/latch.git
cd latch
bash Scripts/test-mac-app.sh --release
open .build/LatchMacApp/Build/Products/Release/Latch.app
```

## Connect an agent

Built-in agents are found automatically if they are installed: `codex login` for Codex, a Claude login and Node.js 22+ for Claude Code, and the existing provider login for OpenCode and fx.

Any other ACP server runs as the custom agent. Set its command in Settings → Agents, for example `my-agent acp`. Quotes and backslash escapes are supported; shell expansion and pipelines are not.

## Limits worth knowing

Latch is not sandboxed and its approval sheets are not a security boundary: they relay the permission requests an agent chooses to make. See https://github.com/mercho40/latch/security/policy.
