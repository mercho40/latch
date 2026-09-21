# Security

## Reporting a vulnerability

Please report vulnerabilities privately through [GitHub's private vulnerability reporting](https://github.com/mercho40/latch/security/advisories/new), not in a public issue. Include the Latch commit, the macOS version, and the steps to reproduce. Do not include real credentials, tokens, or private source code; a mock agent that reproduces the problem is ideal.

Latch is maintained by one person and is pre-release. Expect an acknowledgement within a week. There are no supported release branches yet: fixes land on `main`.

## What Latch is, from a security point of view

Latch launches coding-agent executables on your Mac, in the workspace you choose, with your user's privileges. That is its purpose, so:

- **Latch is not sandboxed,** and neither are the agents it launches. An agent can do anything your user account can do.
- **Approval sheets are not a security boundary.** They relay the permission requests an agent chooses to make. An agent that does not ask is not stopped. Restricting what an agent may do is the agent's job; Latch's job is to make sure a decision you did not make is never sent.
- **A custom agent command is code you chose to run.** Latch does not vet it.

## Boundaries Latch does maintain

Reports against any of these are in scope:

- **The XPC service admits only the app.** The embedded agent service accepts same-user peers whose code signature satisfies the app's identifier, and nothing else.
- **No approval without a decision.** Approval has no default key; Return and Escape cancel. Pending requests are cancelled when the prompt ends, is stopped, or the agent disconnects or exits, and a stale sheet cannot answer a different request. Only option kinds the agent explicitly offered can be selected.
- **Commands are not shell-evaluated.** Agent commands are split into arguments with quote and backslash handling; there is no shell expansion, substitution, or pipeline. Latch does not run shell startup files to find agents.
- **Notifications carry no content.** Notification text names the workspace folder only: no prompt text, tool name, or argument.
- **The transcript renders no remote content.** There is no web view; HTML is not rendered and remote resources are never loaded. Links open only for `http` and `https` URLs without embedded credentials.
- **Error text crossing XPC is bounded and redacted.** Arbitrary error metadata and agent stderr are not forwarded as display text. Redaction of free-form agent prose is best effort.
- **Inputs are bounded.** JSON payloads across the service boundary, the saved session library, the transcript history, and the pending-permission queue all have fixed limits.

## Known limitations

- Builds are ad-hoc signed. With an ad-hoc signature the XPC admission check binds to the bundle identifier rather than to a Team ID, so it does not defend against another local process running as you that presents the same identifier. This will tighten when Developer ID signing is in place.
- If the app or its service is killed outright, agent processes it launched are not cleaned up.
- Session transcripts are stored unencrypted in `~/Library/Application Support/Latch/sessions.json`, readable by anything running as your user.

The design for the planned iOS pairing and remote access, which does not exist yet, is in the [roadmap](../docs/roadmap.md#security-model).
