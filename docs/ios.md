# Latch for iPhone and iPad

The iOS app is a control surface for agents running on a [`latch-server`](server.md). It lists the sessions on your servers, streams their conversations, sends prompts and photos, and answers permission requests and the agent's questions. It never runs an agent itself, and it cannot reach agents that the Mac runs under its own service: only agents on a `latch-server`. To follow the same agent from the Mac and the iPhone, start it in a remote session on a server; a server can run [on the Mac itself](server.md#on-a-mac).

It is built in the same repository as the Mac app, from UIKit, with no web views and no third-party code. It runs on iOS and iPadOS 18 or later.

## What you need

- A Mac with Xcode 27, to build the app. There is no other way to get it onto a phone.
- A `latch-server` the phone can reach, set up as in [Running latch-server](server.md), with the agents installed and signed in there.
- A network path the app will send the token over. Before it sends anything, the app checks where it actually connected. It sends the token only to a loopback address, or to a tailnet address (`100.64.0.0/10` or `fd7a:115c:a1e0::/48`) reached through a tunnel (`utun`) interface from a tailnet address of the phone's own, which is how Tailscale connects on iOS. A name that resolves somewhere else, a tailnet address routed over Wi-Fi while Tailscale is off, or one carried by another VPN, which gives the phone an address of its own, never receives the token. A VPN that hands out addresses in `100.64.0.0/10` itself would pass the check. In practice:
  - **Over Tailscale:** install Tailscale on the phone and the server, run the server on its tailnet address, and pair with its MagicDNS name or tailnet address. Tailscale has to be connected on the phone whenever Latch connects.
  - **On a local network:** run the server with `--listen` on its LAN address and `--allow-unencrypted-network`, and turn on Allow unencrypted network for the server in the app. The token and the whole session then cross that network in the clear; use this only on a network you trust. The switch is not tied to a network: whenever the app is open it connects to the server's address on whatever network the phone is on, and on a café's Wi-Fi that reuses the same addresses, whoever answers there receives the token. Turn the switch off, or remove the server, before you take the phone off that network. iOS asks once whether Latch may use the local network.
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

`--host` is the name or address the phone connects to. The command prints the `latch://…?token=…` pairing string and, below it, a QR code of the same string. Scan the code with the Camera app and tap the link: Latch opens with Add Server filled in and the note "From a pairing link. Check the host, then tap Add." Opening a link connects nowhere: tap Test Connection to try the server first. When it answers, the sheet names the server after the host name it reports, unless another server here already has that name, and says "Tap Add to use this server."; when it does not, it says why. Nothing is saved until you tap Add. The code holds the token; see [Running latch-server](server.md#the-token) for how to handle it. With no server added yet, the sessions list, or on iPad the column beside it, shows the pairing command with a Copy Command button, to paste into the server's terminal.

Without the Camera, copy the pairing string to the phone some other trusted way, open Servers (the server icon above the sessions list), tap Add Server, and use the Paste button, which fills in the host, port, token and name. Or type the name, host, port and token. Test Connection reports the server's host name, system and version, or why it could not connect; a server that answers is named after its host name unless you typed a name. The Add Server sheet also has the Allow unencrypted network switch and the server's own Custom Agent command, which runs on the server.

After Add, the app shows what to do next: if the server already runs agents that no session on this device follows, the list opens its "On <server>" group; if it runs none and has no sessions here, New Session opens.

A link to a server that is already added, at the same host and port, does not add it twice. The app asks "“vps” is already added" and offers Update Token, Add as New Server and Cancel. Update Token opens that server's editor with the new token; it is used once you tap Save.

To rotate a token, run `latch-server token --rotate` on the server, then `pair --host … --qr` again, scan the code and choose Update Token, or paste the new string into the server's editor. The server keeps its identity, so its sessions attach again to agents that kept running. In the editor a token field left empty keeps the current token.

Removing a server, from the editor or by swiping in Servers, asks first. Its sessions stay on the device, under Removed Server, and their agents keep running on the server. Stop Agent in its sessions first if you want them stopped. Adding a server at the same address, host and port, again offers them back: "Reconnect 2 sessions on “vps”?". Reconnect puts them on the new server, and each whose agent still runs there attaches to it again. Not Now leaves them under Removed Server, and while an old session is on the device its agent is not listed under "On <server>"; remove the old session to take its agent up from there instead.

## If a server does not connect

Test Connection, and a session's banner, say why. Servers checks every server as it opens: one that did not answer shows "Can’t connect" under its address with a few words on why, such as "Needs “Allow unencrypted network”", "Token not accepted" or "Didn’t answer", and Test Connection in its editor gives the whole sentence. The usual causes:

- **"Latch did not send the token … is neither this device nor on a Tailscale network."** Tailscale is off on the phone, another VPN is on instead, or the host is not the server's tailnet name or address. Connect Tailscale and check the host. For a server you added, the message offers Allow unencrypted network; do not turn it on to get past this over a network you do not control, since the token would then cross it in the clear. For a server from a pairing link, which anyone can make, it asks you to check the host and Tailscale instead.
- **"<server> refused the token."** The token was rotated, or mistyped. Run `latch-server pair --host NAME --qr` again, scan it and choose Update Token. The server's log shows `wrong token`.
- **"<server> is not answering at <address>."** On the server, `systemctl --user status latch-server` shows whether it is running, and its `listening on` line the address it serves. That has to be the address the phone uses, such as its tailnet address rather than `127.0.0.1`.
- **On a local network,** if you declined the app's request to use it, turn it back on in Settings → Privacy & Security → Local Network → Latch.

## Sessions

The sessions list has a section per server, most recently active first, and a Removed Server section for sessions whose server is gone. The dot beside a server's name is green when it answered the last time it was asked for its agents, red when it did not, and grey before it has been asked; Servers shows the same dot for its own checks. With Differentiate Without Color on, the dot is a symbol whose shape says the same. Each server's menu (the `…` button) offers New Session, Refresh and Server Settings. Pulling the list down checks every link and asks every server again.

A session's row shows its title over the agent's name and folder. The title is the first line of the first prompt until the agent gives the conversation a title of its own, as Claude Code does after a turn, and then the agent's, as it changes; a name you choose with Rename… is never replaced. After a relaunch the title stands as it was, and only a rename changes it. Its state follows the Mac's sidebar. Words lead the second line, so the title keeps the row's width: "Needs approval" with an orange mark at the row's end while a permission decision waits, and "Needs answer" while a question does; "Connecting…", "Reconnecting…" or "Stopping…", from Stop until the agent ends the turn; "Can’t connect" when the server cannot be reached; "Couldn’t start" when the server answered and the agent did not start; "Stopped". Otherwise the end of the row has a spinner and how long the turn has run while it works, a dot for a reply that finished while you were elsewhere, or when it was last active. At accessibility text sizes the state goes on a line of its own under the agent and folder.

A session's context menu offers Rename…, Copy Path, Mark as Read or Mark as Unread, Remove from iPhone (or iPad) and Stop Agent. Swiping a row from its leading edge marks it read or unread, and from its trailing edge offers Remove and Stop Agent. A new name is kept on this device only; the server, and other devices, keep the first prompt as the agent's title.

**Agents another device started.** Under each server, a row "On <server>" shows how many agents run there that no session on this device follows. Tap it to list them, each by its first prompt, or by its folder until it has one, with its agent and whether it is working or waiting for you. The closed row says "Waiting for you" when one of them waits for a decision or an answer, and opens by itself the first time one does; closed again, it stays closed. Tapping an agent takes it up in a new session. The app replays the agent's events from the start, so the conversation so far appears, including history the agent replayed when a session was resumed. The session then follows the agent like any other.

**New Session** (the `+` button, or a server's section) asks for a server, a folder on it and an agent. The folder is typed, because Latch cannot browse the server. It starts from the folder and agent last used on that server, or from the server's home folder. The home folder reads as `~`, and a folder in it as `~/latch`; Create writes the path out in full, so the session keeps an absolute path. The clock button beside the folder lists up to eight folders in use on that server, by this device's sessions and by the agents the server runs. The agents offered are fx, Codex, Claude Code and OpenCode, and Custom when you have set a Custom Agent command for that server in its sheet; the command runs on the server. Whether an agent is installed is the server's to say; the session reports it when it starts. Create starts the agent at once and opens the session with the composer ready for the first prompt.

**Paths.** The app keeps each server's home folder, as the server reports it whenever the app connects to it, by the server's address. With it, a folder in the home is shown as `~/…`: in a session's subtitle and empty page, and in New Session. Copy Path, VoiceOver and the saved session keep the whole path. Until the app has heard from a server, its paths are shown in full.

## A conversation

A session opens pushed over the list on iPhone, or beside it on iPad. The title names the session, and the line under it the server and folder, such as "vps · ~/latch". Tapping the title offers Rename…, Copy Path and Server Settings.

- **Replies** are Markdown, parsed by Foundation and drawn with UIKit: headings, emphasis, inline code, lists, quotes, rules, code blocks with their language and a Copy button, and tables as a grid. Wide code and tables scroll sideways, and fade out at the edge they continue past. HTML is shown as text, images as their alt text, and nothing remote is loaded. Only `http` and `https` links without a user name or password, and `mailto` links, open, with a tap.
- **Message menus.** A long press, or a secondary click, on a message lifts it and offers a menu, as Messages does. A prompt offers Copy and Select Text. A reply offers Copy, which copies the text as shown, Copy as Markdown, which copies it as the agent wrote it, and Select Text; then Copy Code for its code, or Copy Code 1 to Copy Code 4, each with its block's language, when it has several; then Open for up to three of its links. A tool call offers Copy Command, or Copy Title, and Copy Details when it has any; a thought offers Copy, and Select Text while it is open. Text is not selectable until you choose Select Text, so a long press never starts a selection mid-word.
- **Tool calls** are compact rows with a symbol for the kind of call, such as a read, an edit or a command, and their status; Claude Code compacting the conversation has a symbol of its own. Tap one that has details to see them. An edit's details show the lines it changed as a diff, three lines of context around each change, added lines in green and removed ones in red, and say how many unchanged lines lie between. A command's output shows as it ran, without the Markdown fence Claude Code wraps it in, and an image or a resource the call returned is named in grey, such as "[Image: image/png · 3 KB]", rather than shown. A long title wraps at the parts of a path or name, never mid-word.
- **A turn cut short.** When the agent stops a reply at its length limit, stops a turn at its limit of steps, or declines to go on, a grey line at the end of the turn says so.
- **Thinking.** What the agent thought on the way, such as Claude Code's thinking, is a row of its own, folded to "Thinking" and its first words. Tap it for the whole thought, in grey, as plain text.
- **Subagents.** A call that runs a subagent, such as Claude Code's Agent tool, is one row for everything the subagent did: its title, its status and how many steps it has taken, and while it works, the step it is on. Tap it for its details, then its calls, words and thinking under it, indented, in the order they came, even when it ran beside another; a subagent it ran opens the same way. Tapped again, they fold back into its row.
- **The plan.** While the agent keeps a plan, such as Claude Code's to-do list, a bar over the composer says how far it has got, "Plan · 2 of 5", and the step it is on. Tap it for every step, the finished ones struck through; tap again to close it. It goes when the agent clears its plan.
- **The composer** grows with the draft, which is saved with the session, and asks the agent by name. Send becomes Stop while a turn runs, and the conversation shows "Stopping…" from Stop until the agent ends the turn. Typing `/` at the start of the draft lists the commands the agent offers.
- **Writing while the agent works.** Once there is something to send while a turn runs, Send comes back, with Stop beside it. With an agent that steers, as Claude Code does, the message goes into the turn: the composer clears, the agent takes it at its next step, and the conversation shows it where it went in. With an agent that does not, or one the turn no longer takes, behind a message already waiting, or while Stop ends the turn, it waits in a panel over the composer, under the plan, marked with a clock: "Sends when the agent finishes", or "2 messages send in turn when the agent finishes". Each goes in order as a turn ends. A waiting message shows its first line, and its photos as "+ 1 photo"; Edit puts it back in the composer, before what is there, and × takes it out. Stop, Stop Agent, or a session that loses its agent gives everything still waiting back to the composer, photos included, so nothing written is lost; with no session on screen the text goes back into the saved draft. Messages waiting when iOS ends the app come back in the composer the next time.
- **Context.** Once the agent says how much of its context window the conversation fills, as Claude Code does, the composer shows it before Send, such as "25%", in amber from 80%, when the agent is about to compact the conversation. Tap it for the tokens, such as "50,000 of 200,000 tokens", and what the conversation has cost so far when the agent says; VoiceOver reads all of it.
- **Photos.** The `+` button in the composer picks up to four photos from your library. A photo can also be pasted into the composer, or dropped anywhere on the session's page. Each is sent as a JPEG no larger than 2048 pixels on its longest side, and only to an agent that accepts images; for one that does not, the app says so and keeps the draft. There are no file or folder attachments. A photo sent from this device shows as a small picture above its message, from a copy of at most 256 pixels that the app keeps on this device only; see [Privacy and security](#privacy-and-security). A photo sent from another device, or whose copy is gone, is listed by name.
- **The session's `…` menu** has the model, effort and permission mode, as the agent offers them, with their descriptions, then any other option the agent offers under its own name, such as Claude Code's Fast mode. Nothing is hard-coded, and a pick is checked once the agent confirms it. The same menu has Fork Conversation and Resume Conversation…, where the agent offers them, Rename…, Copy Path, Start Agent when the agent is not running, and Stop Agent.
- **Jump to Latest** appears when you scroll away from the end; while you are at the end, a streaming reply keeps it in view. Opening a row there keeps the row in view instead, once following the end would scroll it away.

**Resume Conversation…** In a new session, before its first prompt, with an agent that lists its saved conversations, as Claude Code does, the session's menu and its empty page offer Resume Conversation…. It lists the agent's other conversations in the session's folder, including those started on its own command line on the server, newest first, each by its title and when it last changed. The one you choose goes on in this session: the agent starts again on it, the conversation's history appears as the agent replays it, and the session takes the conversation's title, or "Resumed Conversation" without one, which the agent's own later title replaces. Cancel leaves the session as it was. When the agent cannot list them, an alert says why.

**Fork Conversation.** With an agent that forks its conversations, as Claude Code does, the session's menu offers Fork Conversation once the conversation has begun, while the agent is not working. The agent copies the conversation, and a new session, "<title> (fork)", opens beside this one with the transcript so far and an empty composer, and goes on with the copy separately from here. The copy is the agent's, under its own ID; nothing in the first session changes.

**Approvals.** A permission request opens a sheet over whatever is on screen: what the agent wants to do, in its own heading when it gives one, such as Claude Code's "Ready to code?", or the tool call's title, with a command set in monospace; why, when the agent says; the tool call's details; one button per option the agent offers, in its order; and Cancel Request. When Claude Code asks to leave plan mode, the plan it wants to carry out is shown in place of the details, as Markdown in a frame. Every button says Latch's own label, Allow Once, Always Allow, Reject Once or Always Reject, whatever the agent named the option; the agent's own words for it, such as "Yes, and don't ask again for git commands", are shown under the label in smaller grey text, never in its place, so no option can pass itself off as another. VoiceOver names each button by its label and reads the agent's words as its value. The sheet says that “Always” is remembered by the agent, not by Latch, and that Cancel Request declines only this request. No option is the default, and the sheet cannot be swiped away. When the options do not fit beside the details, as at large text sizes, they scroll with them. It closes when you decide, or when the agent closes the request, such as when another device answered it first.

**Questions.** When the agent asks you something, such as Claude Code's multiple-choice questions or a form from an MCP server, a sheet shows it: the question as the heading, then each question under its short title, such as "Database". A question with one answer lists its options with a circle each, and one with any number of answers a box each; each option shows the agent's description of it and, when the agent gives one, a preview such as a mockup or a snippet, in monospace, scrolling sideways when a line is long. A long preview shows its first six lines and a Show All button. When the agent accepts an answer of your own, an Other box follows the options: what you type there takes the place of the options, so typing clears the choice and choosing clears the box, and what shows chosen is what is sent. A form can also ask for text, a number, or a switch. Submit sends your answers once every required question has one, and every number typed is a number; Skip answers nothing, which Claude Code takes as you skipping the question and goes on; Cancel Request refuses the question, which ends the step that asked it. Like a permission request, the sheet cannot be swiped away, and it closes on its own when the agent withdraws the question, as when the turn is stopped.

One sheet shows at a time: a question waits while a permission request is on screen, and a request while a question is. With both waiting, the request comes first.

**Stop Agent and Remove** are different. Stop Agent, from the session's menu, a row's swipe actions or its context menu, asks "Stop <agent> on <server>?" and stops the agent on the server; the conversation stays on the device, and the session offers Start Agent, which resumes the agent's saved session if the agent can load one. Remove from iPhone (or iPad) forgets the session on this device and leaves its agent running, where "On <server>" offers it again. The first time, it says so and asks. Removing a session whose agent is stopped asks every time, because nothing on the server keeps that conversation.

**The banner** under the title says what is wrong and what fixes it. "Reconnecting to <server>…" means the link dropped: the agent keeps working on the server, and the app catches up when it answers again, with nothing sent twice. A failure names whose it is, such as "Can’t connect to <server>" with Retry and Server Settings, or "<agent> can’t start on <server>" with the agent's own words and Latch's advice. An agent stopped by another device or the server says so, and Retry starts it again.

## Attention, and the badge

While the app is open, a session that is not on screen shows a banner under the navigation bar's buttons, on iPad across the session's column, when its agent finishes a turn, waits for a permission decision or an answer to its question, or is stopped on its server by another device or the server itself. It gives the session's title and says what happened in the agent's name: "Codex on vps needs approval: …" with what the agent asks, "Claude Code on vps asks: …" with its question, "Codex finished.", or "Codex was stopped on vps." A decision's or a question's banner stays eight seconds, and comes with a warning haptic; the others stay four, or eight while VoiceOver runs. Tapping the banner opens the session. Nothing is posted to Notification Center. A finished turn also leaves the unread dot on the session's row; a turn that failed, or ended because its agent was stopped, leaves none.

The app icon's badge counts the sessions waiting for a decision or an answer. The first time a request or a question waits in a session you are not looking at, never at launch, iOS shows its standard prompt asking whether Latch may send notifications. Latch asks only for the badge, so allowing it never brings alerts or sounds. The badge changes only while the app runs, so it can be out of date after the app has been in the background.

## iPad

On iPad the sessions list is a sidebar beside the open session. Before a session is chosen, the column beside it says "No Session Selected" and offers New Session. In a window narrow enough for compact width, the two collapse into one stack with the open session on top, and widening it again shows both. The app has one window.

## Menu bar and keyboard

The app's commands are in the iPadOS menu bar, from iPadOS 26, and before it in the list that holding ⌘ on a hardware keyboard shows, much as the Mac app's menus have them. New Session is in File, Servers where the Settings item goes, and Jump to Latest in View. A Session menu has Send, Stop, Add Photos…, Fork Conversation, Resume Conversation…, Rename…, Copy Path, Start Agent, Stop Agent…, and Previous and Next Session. An item that does not apply is dimmed. The Session menu's items act on the open session wherever the keyboard focus is, the sessions list included, unless a sheet or alert is over it.

| Keys | Action |
| --- | --- |
| ⌘N | New Session |
| ⌘, | Servers |
| ⌥⌘↑ and ⌥⌘↓ | Previous and next session, in the list's order, as on the Mac; ⌘[ and ⌘] do the same, unlisted |
| ⌘↩ | Send, or while the agent works, send into its turn or after it |
| ⌘. | Stop the turn |
| ⇧⌘A | Add Photos |
| ⌥⌘C | Copy Path, as Finder's Copy as Pathname |
| ⌘↓ | Jump to Latest |
| Escape | Cancel Request, in a permission or question sheet |
| ⌘↩ | Submit, in a question sheet |

On an iPhone with a hardware keyboard, the composer's keys below, and Escape and ⌘↩ in a permission or question sheet, work as on iPad.

In the composer, Return sends, as in Messages, and Shift-Return starts a new line. While the agent's `/` commands are listed, the up and down arrows move through them, Return or Tab takes one, and Escape puts the list away.

## Accessibility

- **VoiceOver.** The conversation has rotors for Your Messages, Replies, Thinking, Tool Calls and Code, to move turn by turn through a long one; rows folded into a subagent's are passed over until it is opened. A subagent's row says how many steps it has taken and, while it works, the latest. The plan bar reads as one summary, such as "Plan, 2 of 5 done, now: Write the tests", and once open, its steps one by one with whether each is done. A reply's actions include what its menu offers: Copy, Copy as Markdown, each code block, and its links. While the agent works, Send's hint says whether a message goes into the turn or waits for it to end; one that waits is announced as such, and the panel of waiting messages reads its heading, then each message, photos included, with its Edit and Remove buttons. Tables are read row by row with their column names, and a command in a permission request symbol by symbol. In a question, each option is a button that says when it is chosen, and a preview is read whole, however much of it shows; Submit says what is still to answer while it is dimmed. A server's header in the sessions list is a heading, with its menu's actions. A failure you can act on takes the VoiceOver cursor. Reconnecting, and the end of a turn in the session on screen, are read out without moving it, after what is being read; a turn elsewhere has its banner.
- **Text size.** The app follows Dynamic Type through the accessibility sizes. At those sizes a session's state goes on a line of its own in the list, New Session opens at full height on iPhone, and a permission request's options, or a question's buttons, scroll with it.
- **Display settings.** With Differentiate Without Color, server state is a symbol as well as a colour. Panels are stronger with Increase Contrast, and monospaced text heavier with Bold Text.

## In the background

iOS suspends the app soon after it leaves the screen, and its connections to the servers drop. Nothing is stopped or detached: agents keep working on the server, a turn runs to its end, and a permission request or a question waits there, unanswered. A message waiting over the composer for the turn to end waits too, and goes once the app is open again and has seen the turn end. The app saves every session as it goes to the background.

When you open the app again it checks every link at once, attaches each session again from where it had got to, catches up on what the agent did, raises any permission request or question still waiting, and lists each server's agents again. A turn that finished meanwhile shows on its row. After a relaunch, the sessions that left an agent on a server attach before you open any, and the session that was open is shown again.

**There are no push notifications.** iOS wakes a suspended app for a remote event only through Apple's push notification service, and a push has to come from a provider holding credentials tied to an Apple Developer account. `latch-server` runs on your machine with no such credentials, and Latch has no hosted relay to send them for it. So a request that arrives while the app is suspended reaches you when you next open the app, not before. The [roadmap](roadmap.md) keeps this for a later relay.

## Privacy and security

- **Tokens** are in the Keychain, one item per server, readable after the device's first unlock and only on this device. They are not synced through iCloud Keychain, and a backup restored onto another device does not bring them. iOS keeps Keychain items when an app is deleted; the app removes any token its server list does not name each time it reads the list, so installing it again, with no list, removes the old tokens.
- **Server profiles**, without tokens, are in `servers.json`, and **sessions**, with their transcripts, the agent's thinking included, and drafts, with the text of any messages waiting for a turn to end, in `sessions.json`, both in the app's `Application Support/Latch` folder, written with mode 0600 and data protection until first unlock. They are not encrypted beyond that and are included in device backups. A server restored without its token stays in Servers as "Needs its token again"; entering its token, or opening a pairing link to it, and saving reconnects its sessions.
- **Transcripts** keep the same limits as the Mac's: 400 messages and 200,000 characters of text per session. The photos themselves are not saved with them.
- **Pictures of sent photos.** For each photo sent from this device, the app keeps a JPEG of at most 256 pixels on its longest side, to show above the message. They are in the app's `Caches/SentImages` folder, with data protection until first unlock; iOS may delete them to free space, and they are not included in device backups. They go when their session is removed from the device.
- **What the app remembers about servers,** in its preferences, which are included in device backups: each saved server's home folder, by address, as it last reported it; and the name and address of each server you removed, so that adding one at that address again can offer its sessions back.
- **Pairing links** are never saved on their own, and never connect on their own: a link only fills in the Add Server or Edit Server sheet, the server is reached only when you tap Test Connection or Add, and nothing is kept until you tap Add or Save.
- **What the connection carries** is what the Mac's does: prompts, the agent's replies and reasoning, tool calls with their arguments and output, permission requests and answers, the agent's questions and your answers, and photos; the server's host name, system, architecture and home folder; and for each agent on the server, its folder, the preset or custom command it runs, and a title: the first line of its first prompt, or of the history a resumed session replayed. Latch does not encrypt any of it; that is the network path's job.
- **Holding a server's token is a shell on it,** from the phone as from the Mac. See [SECURITY.md](../.github/SECURITY.md).

## Limitations

- No App Store or TestFlight build; you build and sign it yourself.
- No push notifications, and nothing happens on the phone while the app is suspended.
- No discovery of servers on the network: a server is paired by its string or QR code.
- One token per server, shared by every device. There is no per-device revocation; rotating the token disconnects every device until it is updated.
- Photos only, picked, pasted or dropped: no files or folders, and no taking a photo with the camera.
- Folders on the server are typed, or picked from those in use there, not browsed.
- Only an agent that forks its conversations, such as Claude Code, can fork a session on the phone; the Mac opens an empty session beside one whose agent cannot. A rename stays on the device that made it.
- The Mac app does not list or take up agents another device started; the phone can take up the Mac's remote sessions, not the other way round.
- A session taken up from an agent whose command the app does not know, such as one an older server did not report, is never started again by guess: once that agent stops, the session shows its history but cannot start it again.
- The Markdown renderer covers what Foundation's parser reads; HTML is shown as text.
- One window on iPad.
