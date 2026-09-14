# Licensing

Inline's core is licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). The full text is in [LICENSE](LICENSE). This is the default for Inline-authored material unless an exception below or a more specific notice applies.

## Existing public components

The following components retain **Apache License 2.0** (`Apache-2.0`). Their license is independent of the core's license.

| Paths | Components |
| --- | --- |
| `plugins/codex/`, `plugins/openclaw/`, `plugins/hermes-agent/`, `plugins/chat-sdk/` | Public integrations |
| `packages/sdk/`, `packages/mcp/`, `packages/bot-client/`, `packages/oauth-core/`, `packages/protocol/`, `packages/bot-api-types/` | Public SDK, MCP, authentication, protocol and bot libraries |
| `cli/`, `crates/` | CLI and shared Rust crates |
| `skills/inline/` | Distributable Inline skill |
| `proto/core.proto` | Public protocol schema |
| `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `.cargo/config.toml` | Rust workspace configuration |
| `.agents/plugins/marketplace.json` | Plugin marketplace entry |
| `.github/workflows/integrations.yml`, `.github/workflows/cli-release.yml`, `.github/workflows/npm-publish.yml` | Public integration and release workflows |
| `scripts/check-agent-release-group.mjs`, `scripts/check-codex-plugin.mjs`, `scripts/release-cli.ts`, `scripts/release-cli.test.ts`, `scripts/release-npm.ts`, `scripts/release-npm.test.ts` | Public integration and release tooling |

See [LICENSES/Apache-2.0.txt](LICENSES/Apache-2.0.txt) and component-local license files. Rust workspace license metadata applies to the Rust workspace, not to the repository's core applications or server.

## Third-party material and earlier versions

Third-party code, fonts, assets and bundled adapters retain their existing licenses and copyright notices. For example, `vendor/agent-client-protocol/` remains Apache-2.0; the bundled Amp adapter and Apple vendored components have their own notices. A component's more specific license or notice takes precedence over the repository default.

This policy describes the current source tree. It does not revoke or replace license grants made for earlier versions. Preserve the applicable license and copyright notices when redistributing individual components.
