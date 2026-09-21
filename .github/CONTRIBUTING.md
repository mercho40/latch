# Contributing

Latch is early and maintained by one person, so review time is the scarce resource.

- **Bug reports are welcome.** Include the Latch commit, macOS and Xcode versions, which agent you were running, and what you expected. Do not paste credentials, tokens, or private source into an issue. Security problems go through [SECURITY.md](SECURITY.md) instead.
- **Open an issue before a pull request** for anything beyond a small fix. Latch is deliberately small; a feature can be well built and still not belong. The [roadmap](../docs/roadmap.md) lists what is explicitly out of scope.
- **Small, focused pull requests** with tests are the ones that get merged.

## Ground rules for changes

- AppKit and the system frameworks only. No third-party dependencies, no web views, no SwiftUI in the macOS app.
- Swift 6 language mode with strict concurrency. Do not silence a data-race diagnostic with `@unchecked Sendable`; fix the isolation.
- Every behaviour change comes with a test. UI behaviour is tested against real windows (`WindowFixture`) and mock ACP agents, not by inspection.
- Performance claims come with a measurement. Several parts of the transcript look old-fashioned on purpose; read [AGENTS.md](../AGENTS.md) before modernising them.
- Commit messages say what changed and why, in the imperative, and state what was verified.

## Before you open a pull request

```sh
swift test --package-path Packages/LatchACP
swift test --package-path Packages/LatchServiceProtocol
swift test --package-path Packages/LatchAgentCore
swift test --package-path Apps/LatchMac
bash Scripts/test-mac-app.sh
```

None of these need network or model access. See [building and testing](../docs/building-and-testing.md) for the rest.

## License

Contributions are accepted under the project's [Apache-2.0 license](../LICENSE), as its section 5 provides. There is no contributor license agreement.
