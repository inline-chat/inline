## Goal

Fix Docker deploy failures caused by Bun workspace installs missing newly added workspace manifests.

## Findings

- `packages/mcp/Dockerfile` and `server/Dockerfile` already include `packages/oauth-core/package.json`.
- `web/Dockerfile` and `admin/Dockerfile` still install dependencies from a stale workspace manifest set.
- Their dependency-install stages copy `server/package.json` and `packages/mcp/package.json`, both of which reference `@inline-chat/oauth-core`, so Bun fails when `packages/oauth-core/package.json` is absent.
- `server/Dockerfile` is the known-good baseline, so `web` and `admin` should mirror its install-stage workspace manifest list unless there is a deliberate reason to diverge.

## Plan

1. Add the missing workspace manifests to `web/Dockerfile` and `admin/Dockerfile`, matching the server image's install-stage package set.
2. Reproduce the manifest-only `bun install --frozen-lockfile` flow locally for the affected Dockerfiles.
