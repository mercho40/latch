# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub's private vulnerability reporting](https://github.com/mercho40/latch/security/advisories/new), not in a public issue. Include the Latch commit, the macOS version (and the server's system, for `latch-server`), and the steps to reproduce. Do not include real credentials, tokens, or private source code; a mock agent that reproduces the problem is ideal.

Latch is maintained by one person and is pre-release. Expect an acknowledgement within a week. There are no supported release branches yet: fixes land on `main`.

## What Latch is, from a security point of view

Latch launches coding-agent executables on your Mac, in the workspace you choose, with your user's privileges. That is its purpose, so:

- **Latch is not sandboxed,** and neither are the agents it launches. An agent can do anything your user account can do.
- **Approval sheets are not a security boundary.** They relay the permission requests an agent chooses to make. An agent that does not ask is not stopped. Restricting what an agent may do is the agent's job; Latch's job is to make sure a decision you did not make is never sent.
- **A custom agent command is code you chose to run.** Latch does not vet it.
- **A `latch-server` token is a shell.** Anyone who holds a server's token can run any command on that server, as the user it runs as, by naming it as a custom agent. Treat the token like an SSH private key.

## Boundaries Latch does maintain

Reports against any of these are in scope:

- **The XPC service admits only the app.** The embedded agent service accepts same-user peers whose code signature satisfies the app's identifier, and nothing else.
- **No approval without a decision.** Approval has no default key; Return and Escape cancel. Pending requests are cancelled when the prompt ends, is stopped, or the agent disconnects or exits, and a stale sheet cannot answer a different request. Quitting Latch sends no answer for a remote session's pending request: it stays waiting on the server, and the next launch raises it again. Only option kinds the agent explicitly offered can be selected.
- **Commands are not shell-evaluated.** Agent commands are split into arguments with quote and backslash handling; there is no shell expansion, substitution, or pipeline. Latch does not run shell startup files to find agents.
- **Notifications carry no content.** Notification text names the workspace folder, and for a remote session the server's name in Settings, only: no prompt text, tool name, or argument.
- **The transcript renders no remote content.** There is no web view; HTML is not rendered and remote resources are never loaded. Links open only for `http` and `https` URLs without embedded credentials.
- **Error text crossing XPC is bounded and redacted.** Arbitrary error metadata and agent stderr are not forwarded as display text. Redaction of free-form agent prose is best effort.
- **Inputs are bounded.** JSON payloads across the service boundary, the saved session library, the transcript history, and the pending-permission queue all have fixed limits.

## Boundaries latch-server maintains

`latch-server` is in scope when you run it yourself; [Running latch-server](../docs/server.md) describes how. Reports against any of these are in scope:

- **Nothing unencrypted by default.** Latch does not encrypt its connection; encryption comes from Tailscale or an SSH tunnel. The server listens on `127.0.0.1:7428` unless told otherwise. It accepts a tailnet address (`100.64.0.0/10`, `fd7a:115c:a1e0::/48`) only if a Tailscale interface carries it when the server starts, refuses host names other than `localhost`, and refuses every other address, including `0.0.0.0`, unless started with `--allow-unencrypted-network`, which it logs as a warning.
- **The client checks where it connected before sending the token.** The Mac app sends the token only to a loopback peer, or to a tailnet peer reached through a tunnel (`utun`) interface, unless the server's Allow unencrypted network setting is on. A name that resolves elsewhere, or a tailnet address routed over another network while Tailscale is down, never receives it. The check is by interface kind, not by Tailscale itself: another VPN's `utun` interface carrying a `100.64.0.0/10` address would also pass.
- **The token file is private.** The token is 32 random bytes in `~/.config/latch/server-token`. The file is created with mode 0600 by `open` itself, in a directory that must be owned by the server user with no group or other permissions; every `latch-server` command refuses either if it is loosened, owned by someone else, or a symbolic link, and refuses a token that is not a regular file. It is re-read on every hello, every 15 seconds and on SIGHUP. After `latch-server token --rotate`, the running server closes every connection that used the old token within 15 seconds, or at once on SIGHUP. An unreadable file refuses every client rather than falling back to a remembered token. Tokens are compared in constant time and never logged.
- **Little is exposed before authentication.** The server sends nothing until it has read a hello: one line of at most 16 KiB, decoded as nothing else, within ten seconds of connecting, with at most eight such connections at once. The token is checked before the protocol version, so a client without it learns only that it was refused: not the protocol versions, the host name or anything else from the welcome. Log lines such a client can cause are rate-limited.
- **Limits after authentication.** Frames are capped at just over 8 MiB, each connection may have 32 requests in flight, and each runtime's event journal is bounded. Runtime IDs are restricted to 64 letters, digits, dots, dashes and underscores. Launch requests name a preset or a command and a workspace folder, resolved on the server; the server's own environment is used, never the client's. The server refuses to run as root without `--allow-root`.
- **Agent stderr stays on the server.** It is never sent to clients, and is logged only with `--log-agent-stderr`, escaped and capped.

What the connection carries is everything a session shows: prompts, the agent's replies and reasoning, tool calls with their arguments and output, permission requests and answers, and images attached to prompts; and the server's host name, system, architecture and home folder, each runtime's workspace path, and any custom agent command. Latch does not encrypt any of it; that is the network path's job.

Out of scope for the server: what someone holding the token does with it, which is a shell by design; what agents do on the server, which they do with the server user's full permissions; other users on the same machine, who may bind the server's port while it is down (see below); anyone with root on the server; and the security of Tailscale or SSH themselves.

## Known limitations

- Builds are ad-hoc signed. With an ad-hoc signature the XPC admission check binds to the bundle identifier rather than to a Team ID, so it does not defend against another local process running as you that presents the same identifier. This will tighten when Developer ID signing is in place.
- If the app or its service is killed outright, agent processes it launched on the Mac are not cleaned up.
- Agents on a `latch-server` keep running after Latch quits or is killed, by design, until their session is closed in Latch, something stops them on the server, or the server's idle timeout does. The idle timeout never stops an agent with a turn running or a permission request waiting. Removing a server from Settings stops none of its agents, and once Latch has relaunched, closing a session on a removed server cannot stop its agent either; close a server's sessions before removing it.
- Session transcripts are stored unencrypted in `~/Library/Application Support/Latch/sessions.json`, readable by anything running as your user.
- `latch-server` has one token for every device. There are no per-device tokens and no way to revoke one device; rotating the token disconnects them all. After a rotation, paste the new pairing string into the server's Edit… sheet in Settings → Servers; its sessions stay on it and attach again to agents that kept running.
- `latch-server` is meant for a machine with one user. While it is not running, another local user can listen on its port, loopback included, and receive the token from the next client that connects; an SSH tunnel to that port does not prevent this. The same holds on the Mac for a tunnel's forwarded port while the tunnel is down.
- With `--allow-unencrypted-network` on the server, or Allow unencrypted network in the app, the token and the whole session cross the network in the clear.
- The Mac app keeps server tokens in a file in `~/Library/Application Support/Latch` readable only by your user, not in the Keychain, because every update of an ad-hoc-signed app is a new identity to the Keychain.

The design for the planned iOS pairing, per-device credentials and TLS, which do not exist yet, is in the [roadmap](../docs/roadmap.md#security-model).
