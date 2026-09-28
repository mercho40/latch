# Latch for iPhone and iPad

The iOS app is a control surface for agents running on a [`latch-server`](server.md). It lists the sessions on your servers, streams their conversations, sends prompts and photos, and answers permission requests. It never runs an agent itself, and it cannot reach agents that the Mac runs under its own service: only agents on a `latch-server`. To follow the same agent from the Mac and the iPhone, start it in a remote session on a server; a server can run [on the Mac itself](server.md#on-a-mac).

It is built in the same repository as the Mac app, from UIKit, with no web views and no third-party code. It runs on iOS and iPadOS 18 or later.

## What you need

- A Mac with Xcode 27, to build the app. There is no other way to get it onto a phone.
- A `latch-server` the phone can reach, set up as in [Running latch-server](server.md), with the agents installed and signed in there.
- A network path the app will send the token over. Before it sends anything, the app checks where it actually connected. It sends the token only to a loopback address, or to a tailnet address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`) reached through a tunnel (`utun`) interface, which is what Tailscale uses on iOS. A name that resolves somewhere else, or a tailnet address routed over Wi-Fi while Tailscale is off, never receives the token. In practice:
  - **Over Tailscale:** install Tailscale on the phone and the server, run the server on its tailnet address, and pair with its MagicDNS name or tailnet address. Tailscale has to be connected on the phone whenever Latch connects.
  - **On a local network:** run the server with `--listen` on its LAN address and `--allow-unencrypted-network`, and turn on Allow unencrypted network for the server in the app. The token and the whole session then cross that network in the clear; use this only on a network you trust. iOS asks once whether Latch may use the local network.
  - The SSH tunnel that serves the Mac does not carry over: the app has no tunnel of its own.

## Getting the app

There is no App Store or TestFlight build. Build it with Xcode 27 from a clone of the repository.

**In the Simulator.** Open `Apps/LatchiOS/Latch.xcodeproj`, choose the **Latch iOS** scheme and a simulated iPhone or iPad, and Run. Simulator builds are signed ad hoc and need no Apple account. If Xcode has no iOS Simulator, install one with `xcodebuild -downloadPlatform iOS`. The Simulator shares the Mac's network, so a server on the Mac's `127.0.0.1` is reachable from it.

**On a device.** Automatic signing is set up with no team committed.

1. Sign in to Xcode with your Apple Account under Settings → Accounts. A free account gives you a personal team.
2. Find your team ID. For a paid team it is under Membership on developer.apple.com. Xcode does not show a personal team's ID, but it is the organizational unit of the team's Apple Development certificate. If Settings → Accounts → Manage Certificates lists none, add one there with + → Apple Development. Then:

   ```sh
   security find-certificate -c "Apple Development" -p | openssl x509 -noout -subject
   ```

   The value after `OU=` is the team ID. The ten characters in parentheses in the certificate's name are not.
3. Create `Apps/LatchiOS/Configuration/Local.xcconfig`, which git ignores, with that team ID:

   ```text
   DEVELOPMENT_TEAM = ABCDE12345
   PRODUCT_BUNDLE_IDENTIFIER = com.example.latch
   ```

   A bundle ID belongs to one team, so unless your team owns `dev.latchapp.ios`, set a reverse-DNS ID of your own as well, as above. Set the team only here, not with the team menu under Signing & Capabilities: that writes it into the project file, which is committed, and overrides this file.
4. Connect the device, choose it as the destination, and Run. iOS asks you to turn on Developer Mode the first time. With a personal team, the app then does not open until you trust its developer in Settings → General → VPN & Device Management.

A free personal team works, within Xcode's limits for one: a build it signs stops opening after seven days, until you run it from Xcode again.

Every build is signed with `Configuration/Latch.entitlements`, which grants the app its keychain access group. A build made without it stops at launch and says so, because tokens are kept nowhere but the Keychain.

## Pairing a server

On the server, run:

```sh
latch-server pair --host vps.example.ts.net --qr
```

`--host` is the name or address the phone connects to. The command prints the `latch://…?token=…` pairing string and, below it, a QR code of the same string. Scan the code with the Camera app and tap the link: Latch opens with Add Server filled in and the note "From a pairing link. Check the host, then tap Add." Nothing is saved until you tap Add. The code holds the token; see [Running latch-server](server.md#the-token) for how to handle it.

Without the Camera, copy the pairing string to the phone some other trusted way, open Servers (the server icon above the sessions list), tap Add Server, and use the Paste button, which fills in the host, port, token and name. Or type the name, host, port and token. Test Connection reports the server's host name, system and version, or why it could not connect. The Add Server sheet also has the Allow unencrypted network switch and the server's own Custom Agent command, which runs on the server.

A link to a server that is already added, at the same host and port, does not add it twice. The app asks "“vps” is already added" and offers Update Token, Add as New Server and Cancel. Update Token opens that server's editor with the new token; it is used once you tap Save.

To rotate a token, run `latch-server token --rotate` on the server, then `pair --host … --qr` again, scan the code and choose Update Token, or paste the new string into the server's editor. The server keeps its identity, so its sessions attach again to agents that kept running. In the editor a token field left empty keeps the current token.

Removing a server, from the editor or by swiping in Servers, asks first. Its sessions stay on the device but cannot connect again, even if you add the server back, and their agents keep running on the server. Stop Agent in its sessions first if you want them stopped. To take the agents up again later, add the server back, remove its old sessions from Removed Server, and take the agents up from "On <server>": while an old session is on the device, its agent is not listed there.

## If a server does not connect

Test Connection, and a session's banner, say why. The usual causes:

- **"Latch did not send the token … is neither this iPhone nor on a Tailscale network."** Tailscale is off on the phone, or the host is not the server's tailnet name or address. Connect Tailscale and check the host. The message offers Allow unencrypted network; do not turn it on to get past this over a network you do not control, since the token would then cross it in the clear.
- **"<server> refused the token."** The token was rotated, or mistyped. Run `latch-server pair --host NAME --qr` again, scan it and choose Update Token. The server's log shows `wrong token`.
- **"<server> is not answering at <address>."** On the server, `systemctl --user status latch-server` shows whether it is running, and its `listening on` line the address it serves. That has to be the address the phone uses, such as its tailnet address rather than `127.0.0.1`.
- **On a local network,** if you declined the app's request to use it, turn it back on in Settings → Privacy & Security → Local Network → Latch.

## Sessions

The sessions list has a section per server, most recently active first, and a Removed Server section for sessions whose server is gone. The dot beside a server's name is green when it answered the last time it was asked for its agents, red when it did not, and grey before it has been asked. Each server's menu (the `…` button) offers New Session, Refresh and Server Settings. Pulling the list down checks every link and asks every server again.

A session's row shows its title, from the first line of its first prompt, over the agent's name and folder. The slot at its end follows the Mac's sidebar: a spinner and how long the turn has run while it works; "Needs approval" with an orange mark while a permission decision waits; "Connecting…" or "Reconnecting…"; "Can’t connect" when the server cannot be reached; "Couldn’t start" when the server answered and the agent did not start; "Stopped"; a dot for a reply that finished while you were elsewhere; otherwise when it was last active.

**Agents another device started.** Under each server, a row "On <server>" shows how many agents run there that no session on this device follows. Tap it to list them, each by its first prompt, or by its folder until it has one, with its agent and whether it is working or needs approval. Tapping an agent takes it up in a new session. The app replays the agent's events from the start, so the conversation so far appears, including history the agent replayed when a session was resumed. The session then follows the agent like any other.

**New Session** (the `+` button, or a server's section) asks for a server, a folder on it and an agent. The folder is typed, because Latch cannot browse the server. It starts from the folder and agent last used on that server, or from the server's home folder. The agents offered are fx, Codex, Claude Code and OpenCode, and Custom when you have set a Custom Agent command for that server in its sheet; the command runs on the server. Whether an agent is installed is the server's to say; the session reports it when it starts. Create starts the agent at once.

## A conversation

A session opens pushed over the list on iPhone, or beside it on iPad. The title names the session, and the line under it the server and folder.

- **Replies** are Markdown, parsed by Foundation and drawn with UIKit: headings, emphasis, inline code, lists, quotes, rules, code blocks with their language and a Copy button, and tables as a grid. Wide code and tables scroll sideways. HTML is shown as text, images as their alt text, and nothing remote is loaded. Only `http` and `https` links without a user name or password, and `mailto` links, open. Reply text is selectable.
- **Tool calls** are compact rows with their status; tap one to see its details.
- **The composer** grows with the draft, which is saved with the session. Send becomes Stop while a turn runs. Typing `/` at the start of the draft lists the commands the agent offers.
- **Photos.** The `+` button in the composer picks up to four photos from your library. Each is sent as a JPEG no larger than 2048 pixels on its longest side, and only to an agent that accepts images; for one that does not, the app says so and keeps the draft. There are no file or folder attachments. The transcript lists a sent photo by name; its image data is not saved.
- **Model, effort and permission mode** are in the session's `…` menu, as the agent offers them, with their descriptions. Nothing is hard-coded, and a pick is checked once the agent confirms it. The same menu has Copy Path and Stop Agent.
- **Jump to Latest** appears when you scroll away from the end; while you are at the end, a streaming reply keeps it in view.

**Approvals.** A permission request opens a sheet over whatever is on screen: what the agent wants to do, the tool call's details, one button per option the agent offers, in its order, and Cancel Request. No option is the default, and the sheet cannot be swiped away. It closes when you decide, or when the agent closes the request, such as when another device answered it first.

**Stop Agent and Remove** are different. Stop Agent, from the session's menu, a row's swipe actions or its context menu, asks "Stop <agent> on <server>?" and stops the agent on the server; the conversation stays on the device, and the session offers Start Agent, which resumes the agent's saved session if the agent can load one. Remove from iPhone (or iPad) forgets the session on this device and leaves its agent running, where "On <server>" offers it again. The first time, it says so and asks. Removing a session whose agent is stopped asks every time, because nothing on the server keeps that conversation.

**The banner** under the title says what is wrong and what fixes it. "Reconnecting to <server>…" means the link dropped: the agent keeps working on the server, and the app catches up when it answers again, with nothing sent twice. A failure names whose it is, such as "Can’t connect to <server>" with Retry and Server Settings, or "<agent> can’t start on <server>" with the agent's own words and Latch's advice. An agent stopped by another device or the server says so, and Retry starts it again.

## Attention, and the badge

While the app is open, a session that is not on screen shows a banner at the top of the window, with its title, when its agent finishes a turn, waits for a permission decision, or is stopped on its server by another device or the server itself. Tapping the banner opens the session. Nothing is posted to Notification Center. A finished turn also leaves the unread dot on the session's row; a turn that failed, or ended because its agent was stopped, leaves none.

The app icon's badge counts the sessions waiting for a decision. The first time a request waits in a session you are not looking at, never at launch, iOS shows its standard prompt asking whether Latch may send notifications. Latch asks only for the badge, so allowing it never brings alerts or sounds. The badge changes only while the app runs, so it can be out of date after the app has been in the background.

## iPad

On iPad the sessions list is a sidebar beside the open session. In a window narrow enough for compact width, the two collapse into one stack with the open session on top, and widening it again shows both. The app has one window.

## Keyboard

With a hardware keyboard, on iPad or iPhone:

| Keys | Action |
| --- | --- |
| ⌘N | New Session |
| ⌘, | Servers |
| ⌘[ and ⌘] | Previous and next session, in the list's order |
| ⌘↩ | Send |
| ⌘. | Stop the turn |
| Escape | Cancel Request, in a permission sheet |

## In the background

iOS suspends the app soon after it leaves the screen, and its connections to the servers drop. Nothing is stopped or detached: agents keep working on the server, a turn runs to its end, and a permission request waits there, unanswered. The app saves every session as it goes to the background.

When you open the app again it checks every link at once, attaches each session again from where it had got to, catches up on what the agent did, raises any permission request still waiting, and lists each server's agents again. A turn that finished meanwhile shows on its row. After a relaunch, the sessions that left an agent on a server attach before you open any, and the session that was open is shown again.

**There are no push notifications.** iOS wakes a suspended app for a remote event only through Apple's push notification service, and a push has to come from a provider holding credentials tied to an Apple Developer account. `latch-server` runs on your machine with no such credentials, and Latch has no hosted relay to send them for it. So a request that arrives while the app is suspended reaches you when you next open the app, not before. The [roadmap](roadmap.md) keeps this for a later relay.

## Privacy and security

- **Tokens** are in the Keychain, one item per server, readable after the device's first unlock and only on this device. They are not synced through iCloud Keychain, and a backup restored onto another device does not bring them.
- **Server profiles**, without tokens, are in `servers.json`, and **sessions**, with their transcripts and drafts, in `sessions.json`, both in the app's `Application Support/Latch` folder, written with mode 0600 and data protection until first unlock. They are not encrypted beyond that and are included in device backups. A server restored without its token stays in Servers as "Needs its token again"; entering its token, or opening a pairing link to it, and saving reconnects its sessions.
- **Transcripts** keep the same limits as the Mac's: 400 messages and 200,000 characters of text per session. Photos sent are not saved.
- **Pairing links** are never saved on their own: a link only fills in the Add Server or Edit Server sheet, and nothing is kept until you tap Add or Save.
- **What the connection carries** is what the Mac's does: prompts, the agent's replies and reasoning, tool calls with their arguments and output, permission requests and answers, and photos; the server's host name, system, architecture and home folder; and for each agent on the server, its folder, the preset or custom command it runs, and a title: the first line of its first prompt, or of the history a resumed session replayed. Latch does not encrypt any of it; that is the network path's job.
- **Holding a server's token is a shell on it,** from the phone as from the Mac. See [SECURITY.md](../.github/SECURITY.md).

## Limitations

- No App Store or TestFlight build; you build and sign it yourself.
- No push notifications, and nothing happens on the phone while the app is suspended.
- No discovery of servers on the network: a server is paired by its string or QR code.
- One token per server, shared by every device. There is no per-device revocation; rotating the token disconnects every device until it is updated.
- Photos only: no files or folders, and no camera or clipboard images.
- Folders on the server are typed, not browsed.
- Sessions cannot be renamed or forked on the phone.
- The Mac app does not list or take up agents another device started; the phone can take up the Mac's remote sessions, not the other way round.
- A session taken up from an agent whose command the app does not know, such as one an older server did not report, is never started again by guess: once that agent stops, the session shows its history but cannot start it again.
- The Markdown renderer covers what Foundation's parser reads; HTML is shown as text.
- One window on iPad.
