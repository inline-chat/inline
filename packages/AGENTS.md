# Instructions for packages

## Scope

- `packages/` contains the protocol, SDK, MCP, bot client, Bot API types, and OAuth packages. OpenClaw lives in `plugins/openclaw/`; URL preview lives in `server/packages/url-preview/`.
- Keep package identifiers and versions independent. Use package exports instead of relative imports across package roots.

## Checks and releases

- Run the relevant package's `typecheck`, `lint`, `test`, or `build` script from its directory at useful checkpoints; check `package.json` for the scripts it actually provides.
- Follow `proto/AGENTS.md` for schema changes. Keep generated outputs consistent with their source contracts.
- Before an authorized npm release, check dependent package versions and the release workflow. Do not publish packages just to test local changes.
