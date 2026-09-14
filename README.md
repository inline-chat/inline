# Inline

Inline is a chat app for work, built around a fast native experience, threads, and agentic workflows.

[Website](https://inline.chat) · [Documentation](https://inline.chat/docs)

This checkout is a **private repository preparation candidate**. It includes the server; publication remains pending security fixes and documentation review.

## Repository

| Path | Contents |
| --- | --- |
| `apple/` | Native iOS and macOS applications |
| `server/` | Bun/TypeScript backend |
| `landing/` | Website and product documentation |
| `proto/` | Canonical protocol schemas |
| `packages/` | Inline SDK, MCP server and shared libraries |
| `plugins/` | [Codex](plugins/codex/README.md), [OpenClaw](plugins/openclaw/README.md), [Hermes](plugins/hermes-agent/README.md), [Chat SDK adapter](plugins/chat-sdk/README.md) |
| `cli/`, `crates/` | Rust CLI and shared crates |
| `skills/inline/` | Distributable Inline skill |
| `desktop/` | Windows desktop application |
| `web/`, `mobile/` | Inactive drafts |

Integration packages are versioned independently. All workspaces are contained in this repository.

## Development

Use Bun 1.4.0; Rust tooling is pinned in `rust-toolchain.toml`.

```sh
bun install --frozen-lockfile
bun run check:codex-plugin
bun run build:integrations
```

Package READMEs describe their individual checks. Server development still requires separately provisioned local configuration and services. This repository does not yet promise supported self-hosting.

Private planning and operational guidance live separately. The core is licensed under **AGPL-3.0-only**. Existing public plugins, CLI, SDKs and related components retain **Apache-2.0**; third-party notices remain in force. See [LICENSING.md](LICENSING.md) for the exact scope and [LICENSE](LICENSE) for the core license.

## Contributions

External pull requests are currently closed. See [CONTRIBUTING.md](CONTRIBUTING.md) and [SUPPORT.md](SUPPORT.md).
