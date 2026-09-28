# Running latch-server

`latch-server` runs ACP agents on another machine, usually a Linux VPS, and lets Latch on your Mac, iPhone or iPad drive them over the network. Agents keep running when the Mac sleeps or changes network, and when Latch quits; Latch reconnects, or attaches again when it next opens, and catches up on what it missed. It also runs on macOS, which lets a phone follow agents on the Mac itself; [On a Mac](#on-a-mac) covers that. The rest of this guide covers Linux with systemd.

Holding the server's token is the same as having a shell on the server as the user it runs as: a client can start any command there as a custom agent. Latch does not encrypt the connection. Encryption comes from the path: a Tailscale (WireGuard) tailnet, or an SSH tunnel. The server listens only on loopback unless told otherwise, accepts a tailnet address only if Tailscale carries it when the server starts, and refuses any other address without `--allow-unencrypted-network`. See [SECURITY.md](../.github/SECURITY.md) for the boundaries it maintains.

## Requirements

- Linux on x86_64 or aarch64. The static binaries run on any distribution. A build made with the Swift toolchain on the server needs glibc 2.29 or later.
- The agents installed and signed in **on the server, as the user `latch-server` runs as**. Your Mac's logins are never used. For Claude Code, sign in with `claude`; for Codex, `codex login`. Codex and Claude Code need Node.js 22+ with npm when their ACP adapter is fetched through `npx`, and internet access on first use. OpenCode and fx use their installed commands and their own logins.
- Tailscale on the server and on every Mac, iPhone or iPad that connects to it, or, for a Mac only, SSH access to the server.

Agents get `latch-server`'s environment, not your login shell's. It searches, in order, the `PATH` it was given; `~/.local/bin`, `~/.fx/bin`, `~/.opencode/bin`, `~/.bun/bin`, `~/.npm-global/bin` and `~/.volta/bin`; Linuxbrew, `/usr/local/bin`, the system directories and `/snap/bin`; then fnm installs, then nvm installs. An agent installed anywhere else needs `Environment=PATH=…` in the unit below, or an absolute path in a custom command. The first `node` or `npx` found wins, so a distribution's Node in `/usr/bin` is used before one from nvm or fnm; if it is older than 22, put the newer Node's `bin` directory first with `Environment=PATH=…`.

Provider keys that an agent reads from the environment go in an `EnvironmentFile=`, such as `%h/.config/latch/agent.env` with mode 0600. Every agent the server starts sees them, a custom command included.

## Get a binary

Releases do not include `latch-server` yet; build it.

**From a Mac**, with [Apple's container tool](https://github.com/apple/container) running (`container system start`):

```sh
bash Scripts/build-linux-server.sh
```

This builds static musl binaries in `.build/linux-server/latch-server-x86_64` and `latch-server-aarch64`. Copy the one that matches `uname -m` on the server:

```sh
ssh vps mkdir -p .local/bin
scp .build/linux-server/latch-server-x86_64 vps:.local/bin/latch-server
```

**On the server**, with a Swift 6.4 toolchain:

```sh
git clone https://github.com/mercho40/latch.git && cd latch
swift build -c release --package-path Packages/LatchAgentCore --product latch-server
install -D -m 755 "$(swift build -c release --package-path Packages/LatchAgentCore --show-bin-path)/latch-server" ~/.local/bin/latch-server
```

This binary loads the Swift runtime from the toolchain, so keep the toolchain installed.

Check it with `~/.local/bin/latch-server --version`; `--help` lists every option. The rest of this guide runs it as plain `latch-server`, which works once `~/.local/bin` is on your `PATH`. On Ubuntu and Debian the login profile adds it only if the directory existed when you logged in, so after creating it, log out and back in; elsewhere, add it to `PATH` yourself or use the full path.

## The token

```sh
latch-server token
```

prints the token, creating it on first use in `~/.config/latch/server-token` (or `$XDG_CONFIG_HOME/latch` when `XDG_CONFIG_HOME` is an absolute path; `--config-dir` overrides both). The file is created with mode 0600 and the directory 0700. Every command refuses either if it has any group or other permissions, belongs to another user, or is a symbolic link, and refuses a token that is not a regular file; the message says what to fix. Serving never prints the token.

```sh
latch-server pair --host vps.example.ts.net
```

prints a `latch://vps.example.ts.net:7428?token=…` string to paste into Latch. `--host` is the name or address your Mac or phone will connect to; add `--port` if the server does not listen on 7428. The string contains the token. Treat it like the token: paste it straight into Latch, and do not send it through chat, mail or notes.

Add `--qr` to print, below the string, a QR code of it for the iPhone's Camera, which opens it in Latch. The code holds the string exactly, token included, so the same care applies: scan it from your own screen, and do not photograph it, screenshot it or leave it in a shared terminal's scrollback. It is drawn with half-block characters, the light modules and the margin around the code in white on black, whatever the terminal's theme; with `NO_COLOR` set, or written anywhere but a terminal, it has no colours of its own and suits a dark theme. It is at most 65 columns wide. Some terminals draw the blocks from the font and leave a thin gap between lines; drawn this way round the gaps fall across light modules, where the Camera still reads the code, so keep the terminal's line spacing at its default. If the Camera does not read it, add `--invert`, which draws the dark modules instead, in black on white. A host name longer than about 140 characters does not fit in a code.

`latch-server` refuses to run as root, because its agents would run as root too; `--allow-root` overrides that. Create an ordinary user for it instead, and do everything in this guide logged in as that user over SSH, not through `su` or `sudo -u`: those do not start the user's systemd instance, and `systemctl --user` then fails with "Failed to connect to bus".

## Run it as a systemd user service

Create the directory for user units, which a new user does not have yet:

```sh
mkdir -p ~/.config/systemd/user
```

Save this as `~/.config/systemd/user/latch-server.service`:

```ini
[Unit]
Description=Latch server
StartLimitIntervalSec=0

[Service]
ExecStart=%h/.local/bin/latch-server --listen 127.0.0.1:7428
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure
RestartSec=2s

[Install]
WantedBy=default.target
```

For Tailscale, replace the `--listen` address with the server's tailnet address (below). Then:

```sh
systemctl --user daemon-reload
systemctl --user enable --now latch-server
loginctl enable-linger "$USER"
```

`enable-linger` starts your user's services at boot and keeps them running when you log out; without it the server stops with your last SSH session. Some distributions ask for `sudo` to set it.

## Reach it over Tailscale

Find the server's tailnet address with `tailscale ip -4` and listen on it:

```ini
ExecStart=%h/.local/bin/latch-server --listen 100.101.102.103:7428
```

The server accepts a tailnet address only if it is on a Tailscale interface when the server starts: one whose name starts with `tailscale` on Linux, or `utun` on macOS. It does not check again later. Tailscale in userspace-networking mode has no such interface; use the SSH tunnel instead, or run Tailscale with its TUN device, rather than `--allow-unencrypted-network`. At boot, if Tailscale is not up yet, the server logs `waiting for Tailscale` and tries again every two seconds for up to five minutes, then exits with status 1, and systemd restarts it two seconds later.

`StartLimitIntervalSec=0` means systemd never stops restarting it. A configuration error, such as a loosened token file or a bad `--listen`, therefore shows up as a restart every two seconds; `systemctl --user status latch-server` shows the last message.

Anything on your tailnet that its access controls allow can reach the port; only the token keeps it out. On a tailnet you share with other people, or with nodes shared into it, restrict TCP 7428 on the server to your own devices with a Tailscale ACL.

Pair with the server's MagicDNS name or its tailnet address: `latch-server pair --host vps.example.ts.net`.

## Reach it over an SSH tunnel

Keep the default loopback address and forward a local port from the Mac:

```sh
ssh -N -L 7428:127.0.0.1:7428 vps
```

On the server, `latch-server pair --host 127.0.0.1` prints the string to paste: to Latch the server is at `127.0.0.1:7428`. This path is for the Mac; the iOS app has no tunnel, so reach the server from a phone over Tailscale. The tunnel must be up whenever Latch connects. When it drops, Latch keeps retrying, waiting up to 30 seconds between attempts, and catches up once it is back. While it is down, Latch sends the token to whatever listens on the Mac's `127.0.0.1:7428`; see Caveats.

## Add it in Latch

In Latch, open Settings → Servers, choose Add Server…, and paste the pairing string, or enter a name, host, port and token. Test Connection reports the server's host name, system and version, or why it could not connect. Then Session → New Remote Session… starts a session in a folder on the server. To change a server's name, address or token later, select it and click Edit…, or double-click it; its sessions stay on it. On an iPhone or iPad, scan the code `latch-server pair --host NAME --qr` prints with the Camera instead; [Latch for iPhone and iPad](ios.md#pairing-a-server) covers it.

Before sending the token, Latch checks where it actually connected. It sends the token only to a loopback address, or to a tailnet address reached through a tunnel (`utun`) interface from a tailnet address of the device's own, which is how Tailscale connects when it is up. A name that resolves somewhere else, a tailnet address routed over Wi-Fi while Tailscale is down, or one carried by another VPN, which gives the device an address of its own, never receives it. The server's Allow unencrypted network setting lifts this check; with it on, the token and everything after it can cross that network in the clear.

## Rotate the token

```sh
latch-server token --rotate
systemctl --user reload latch-server
```

`--rotate` writes a new token. The running server closes every connection that used the old one within 15 seconds, or at once on the reload, which sends SIGHUP. A client that tries the old token again is refused and stops retrying.

Rotate it if the token or a pairing string may have leaked. Then, in Latch, choose the server in Settings → Servers, click Edit… or double-click it, and paste the new pairing string. On an iPhone or iPad, run `latch-server pair --host … --qr`, scan the code and choose Update Token. Its sessions stay on it: those the server refused attach again to the agents still running there, where they left off. Do not remove the server and add it again, which leaves its sessions on a removed server.

## Logs

```sh
journalctl --user -u latch-server -f
```

If that shows nothing, the journal may be volatile, as on Debian without `/var/log/journal`: create that directory to keep logs, or read them as root with `journalctl _SYSTEMD_USER_UNIT=latch-server.service`. `systemctl --user status latch-server` shows the last lines either way.

The server logs where it listens, each connection from its peer address, and each agent launched, stopped or exited, and why an agent failed to launch. It never logs the token. Lines that a peer without the token can cause are limited to 30 a minute. Agents' stderr is logged only with `--log-agent-stderr`, one escaped line at a time, each prefixed with its runtime ID, cut at 1,000 characters and at most 100 lines per agent every ten seconds.

When Latch says only "Agent command failed." for Claude Code or Codex, the log has a `failed to launch` line with the command that was run. The usual cause is a Node.js older than 22 found first on the server's `PATH` (see Requirements); run the server with `--log-agent-stderr` to see what the agent printed before it exited.

## When Latch quits or loses the connection

Losing the connection does not stop anything: turns run to their end and permission requests wait. Latch keeps retrying and catches up once the server answers again.

Quitting Latch does not stop remote agents either. Each saved session remembers the agent it was following on the server and how far it had got. The next launch attaches to every such agent in the background, without waiting for you to select the session: it catches up on what the agent did meanwhile, raises any permission request still waiting, finishes following a turn still running, and announces the turn it left running, if that finished while Latch was closed, as it would any other. A permission request raised while Latch is closed waits on the server, unanswered, until then. If Latch is killed rather than quit, its remote agents keep running as well, and the next launch attaches from what Latch last saved. An agent left idle with no client for longer than the idle timeout below is stopped meanwhile, and its session resumes it as after a restart.

On the Mac, closing a remote session stops its agent, as Session → Disconnect does. If the server cannot be reached within ten seconds, the agent is left running there until the idle timeout below; if it was waiting on a permission request, until the longer timeout for those. Undoing the close starts the agent again and resumes its saved session, if the agent can load one.

On iOS, Remove forgets a session on the device and leaves its agent running; Stop Agent stops it. [Latch for iPhone and iPad](ios.md#sessions) covers both.

Removing a server from Latch, on the Mac or on iOS, stops none of its agents. On the Mac, close its sessions first: after Latch relaunches, a session on a removed server cannot reach its agent, and closing it leaves the agent running until the idle timeouts below stop it, or until it is stopped on the server.

## When the server stops

On SIGTERM or SIGINT, the server stops accepting and stops every agent, then gives each connected client up to two seconds to receive the news before it closes the connection, and exits 0. An agent gets SIGTERM with its whole process group, and SIGKILL if it has not exited within five seconds. Under the unit above, `systemctl --user stop` or `restart` sends SIGTERM to the server and every agent in the unit at the same time, so an agent may end before the server stops it. If `latch-server` itself is killed or crashes, it cannot stop its agents; systemd ends whatever is left in the unit before it restarts it.

**Agents do not survive a server restart.** Nothing about a running agent is written to disk. A session connected when the server stopped says its agent was stopped on the server; one that reconnects or attaches later finds the agent gone and says it is no longer running there. Retry starts the agent again and resumes the agent's saved session, if the agent can load one. A session attaching when Latch opens does this by itself, and if a turn was running when Latch quit, adds a line saying that some output from while Latch was closed could not be recovered.

A session that says its agent was stopped on the server means the agent is no longer running there, and not because of anything this session did: another client stopped it, or the server shut down while the session was connected. The idle timeout below stops only agents no client is attached to, and forgets them, so a session finds such an agent gone, as after a restart. It is not a crash; an agent that crashed shows its exit status instead. An agent that exited or was stopped stays attachable, so Latch can show how it ended; the server keeps the last eight. The server keeps up to 8 MiB of each agent's events for clients that return, and 128 MiB across all of them, dropping the oldest first. A client that returns after some of its events were dropped is told so.

## Idle agents

An agent nobody has been attached to for 24 hours, with no turn running, is stopped and forgotten; the server checks once a minute. Change the timeout with `--detached-timeout`, such as `12h`, `90m` or `1h30m`; `0` turns this off. An agent whose turn is waiting on a permission request is given seven days, or the timeout if that is longer, so a request left waiting when Latch quit is still there the next day, but an agent whose session was closed while the server was out of reach does not run forever. An agent running a turn that waits on nothing is never stopped. A client that comes back later resumes the session as after a restart.

## On a Mac

Nothing is packaged for macOS: releases do not include `latch-server`, and there is no launchd property list. Build it from a clone, with Xcode 27:

```sh
swift build -c release --package-path Packages/LatchAgentCore --product latch-server
```

The binary is in the directory `swift build -c release --package-path Packages/LatchAgentCore --show-bin-path` prints. Run it as yourself, in a terminal or from a launch agent you write, on loopback for the Mac and on the Mac's tailnet address for the phone; `--listen` can be given more than once:

```sh
latch-server --listen 127.0.0.1:7428 --listen 100.101.102.103:7428
```

On macOS the server accepts a tailnet address on a `utun` interface, which is where Tailscale puts it. Pair the phone with `pair --host` and the Mac's MagicDNS name or tailnet address, and add the server to Latch on the Mac with `pair --host 127.0.0.1`. Start the agents you want to follow from both in remote sessions on this server: they are separate from the agents Latch runs under its own service, which the phone cannot reach. They run as you, with your logins on the Mac, and only while the Mac is awake.

## Caveats

- **One user per server.** Everyone who holds the token acts as the same user, with the same agents and logins. There are no per-device tokens: rotating the token disconnects every device.
- **Not a sandbox.** Agents run with the server user's full permissions. Approval sheets relay what an agent asks; they do not confine it.
- **Other users on the same machine.** While `latch-server` is down, another local user could listen on its port, loopback included, and read the token from the next client that connects. Latch connects to `localhost` at `127.0.0.1` only, where the server listens, never at `::1`. An SSH tunnel does not prevent this, since it connects to that port too. With an SSH tunnel the same applies on the Mac: while the tunnel is down, another user of the Mac could listen on its forwarded port. Prefer machines whose only user is you.
- **Connections without the token.** Anyone who can reach the port can open connections that never send a hello. The server holds at most eight such connections per address and 64 in all, and a new one closes the oldest rather than being turned away, so idle sockets cannot keep Latch out; a peer that opens connections faster than Latch completes its handshake can still delay it.
- **No TLS.** Latch relies on Tailscale or SSH for encryption. `--allow-unencrypted-network` on the server, or Allow unencrypted network in Latch, sends the token and every prompt and reply in the clear.
- **No file attachments.** Remote sessions take images, for agents that accept them, but not files or folders, which live on the Mac.
