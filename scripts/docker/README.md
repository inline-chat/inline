# Container builds

Build from the repository root with `landing/Dockerfile`, `server/Dockerfile`,
or `packages/mcp/Dockerfile`. All use the Bun version pinned in `package.json`.
Both server targets keep migrations explicit and refuse to start against a
database behind their packaged migration journal. The shared runtime target serves Bun
directly; see [the Fly container guide](../../server/docs/fly-container.md).
The website build stage also includes Node 26.8.2, matching CI: StyleX 0.19.1
media-query compilation fails when Vite runs under Bun. Bun still installs
dependencies and serves the release image; Node is only in the build stage.

`prune-workspace.ts` retains every workspace manifest, `bunfig.toml`, and the
committed `bun.lock`. Dependency stages use a frozen, filtered install. Only
the selected workspace and its local dependency sources enter the build stage.
The helper never resolves dependencies or overwrites an existing output directory.

CI runs `bun test scripts/docker`, a manifest/lockfile
contract check that does not install dependencies or build containers. Each
Docker build checks its final production dependency layout before producing the
release image:

- Website: starts the built SSR server and checks `/` and `/docs`.
- MCP: starts the built service and checks health and OAuth discovery.
- Server: loads bundled migration/verification commands without credentials
  and exercises Sharp and MessagePack. The existing database-backed server CI smoke covers full startup
  and HTTP behavior; this packaging check does not replace it.

These checks require no production credentials or external services. The final
deployment must also pass its runtime health/readiness check with real
configuration before replacing the previous container.

If moving builds to a registry, run these same Dockerfiles once, publish the
tested image with its full source commit as the tag, record its digest, and
promote that image without rebuilding. Preserve previous images and verify the
deployment platform's rollback behavior before changing an existing service.

Server releases use `server-context.ts` to export exact committed inputs. See
[the container guide](../../server/docs/fly-container.md) for build commands and
[the Fly deployment guide](../../server/docs/fly-deployment.md) for digest-only,
single-Machine updates. The server CI builds both Linux targets and runs the
packaged migrator and verifier against disposable PostgreSQL; it never publishes.
