# imsg-companion

A small macOS background agent that connects Messages on a Mac to a self-hosted assistant (HomeChat). It reads threads read-only through [`IMsgCore`](https://github.com/openclaw/imsg) (pinned), uplinks scrubbed messages over HTTPS, and sends a reply only after the owner approves its exact text in HomeChat.

- Design: [`docs/specs/2026-11-14-imsg-standalone-agent-design.md`](docs/specs/2026-11-14-imsg-standalone-agent-design.md)
- Uplink contract: [`docs/specs/2026-11-08-imsg-uplink-contract.md`](docs/specs/2026-11-08-imsg-uplink-contract.md)
- Implementation plan: [`docs/plans/2026-11-15-imsg-standalone-agent.md`](docs/plans/2026-11-15-imsg-standalone-agent.md)

Status: under construction. It never writes the Messages database, marks messages read or sends typing indicators.

## Build and test

```sh
swift build
swift test
```

Requires macOS 14+ and Xcode 27 (Swift 6.4). Tests use synthetic `chat.db` fixtures only.

## Licence

MIT. `IMsgCore` is MIT-licensed by its authors.
