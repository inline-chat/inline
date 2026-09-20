# Licensing

Inline's core is licensed under the **GNU Affero General Public License, version 3 only** (`AGPL-3.0-only`). The full text is in [LICENSE](LICENSE). This is the default for Inline-authored material unless an exception below or a more specific notice applies.

## Apache-2.0 components

The following components are licensed under **Apache License 2.0** (`Apache-2.0`). Their license is independent of the core's license.

| Paths | Components |
| --- | --- |
| `plugins/chatgpt/`, `plugins/openclaw/`, `plugins/hermes-agent/`, `plugins/chat-sdk-plugin/` | Integrations |
| `packages/sdk/`, `packages/mcp/`, `packages/bot-client/`, `packages/oauth-core/`, `packages/protocol/`, `packages/bot-api-types/` | SDK, MCP, authentication, protocol and bot libraries |
| `cli/`, `crates/` | CLI and shared Rust crates |
| `skills/inline/` | Distributable Inline skill |
| `proto/core.proto` | Public protocol schema |
| `Cargo.toml`, `Cargo.lock`, `rust-toolchain.toml`, `.cargo/config.toml` | Rust workspace configuration |
| `.agents/plugins/marketplace.json` | Plugin marketplace entry |
| `.github/workflows/integrations.yml`, `.github/workflows/cli-release.yml`, `.github/workflows/npm-publish.yml` | Integration and release workflows |
| `scripts/check-agent-release-group.mjs`, `scripts/check-codex-plugin.mjs`, `scripts/release-cli.ts`, `scripts/release-cli.test.ts`, `scripts/release-npm.ts`, `scripts/release-npm.test.ts` | Integration and release tooling |

See [LICENSE-APACHE](LICENSE-APACHE) and component-local license files. Rust workspace license metadata applies to the Rust workspace, not to the repository's core applications or server.

## Third-party material

Third-party code, fonts, assets and bundled adapters are covered by their respective licenses and copyright notices. For example, `vendor/agent-client-protocol/` is licensed under Apache-2.0; `.codex/skills/postgres/` carries PlanetScale's MIT license; the generated emoji autocomplete data is covered by the [Unicode License v3](LICENSE-UNICODE); and the bundled Amp adapter and Apple vendored components have their own notices. A component's more specific license or notice takes precedence over the repository default.

Preserve the applicable license and copyright notices when redistributing individual components.
