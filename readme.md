# Inline

[![Better Stack Badge](https://uptime.betterstack.com/status-badges/v2/monitor/1murw.svg)](https://uptime.betterstack.com/?utm_source=status_badge)

[Inline](https://inline.chat) is a chat app for teams.

## Development

```sh
bun dev
```

To get up to date and run the API:

```sh
git pull origin main
bun install
bun db:migrate
bun dev:server
```

Setup Swift:

```sh
# Install Swift Protobuf
brew install swift-protobuf
```

Development Setup

### Use xcconfig

1. Copy `Config.xcconfig.template` to `Config.xcconfig`
2. Edit `Config.xcconfig` and set your local development machine's IP address

## TBD
