# Container builds

Build from the repository root with `landing/Dockerfile`, `server/Dockerfile`,
or `packages/mcp/Dockerfile`. All use the Bun version pinned in `package.json`.

`prune-workspace.ts` retains every workspace manifest, `bunfig.toml`, and the
committed `bun.lock`. Dependency stages use a frozen, filtered install. Only
the selected workspace and its local dependency sources enter the build stage.
The helper never resolves dependencies or overwrites an existing output directory.

CI runs `bun test scripts/docker/prune-workspace.test.ts`, a manifest/lockfile
contract check that does not install dependencies or build containers. Each
Docker build checks its final production dependency layout before producing the
release image:

- Website: starts the built SSR server and checks `/` and `/docs`.
- MCP: starts the built service and checks health and OAuth discovery.
- Server: checks packaged entrypoints/migrations and exercises Sharp and
  MessagePack. The existing database-backed server CI smoke covers full startup
  and HTTP behavior; this packaging check does not replace it.

These checks require no production credentials or external services. The final
deployment must also pass its runtime health/readiness check with real
configuration before replacing the previous container.

If moving builds to a registry, run these same Dockerfiles once, publish the
tested image with its full source commit as the tag, record its digest, and
promote that image without rebuilding. Preserve previous images and verify the
deployment platform's rollback behavior before changing an existing service.
