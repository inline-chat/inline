# Server container

`server/Dockerfile` is the canonical build for Fly and Coolify. Both targets
share frozen dependencies, compiled commands, the migration journal, and image
smoke checks. Build from the repository root:

- `runtime`: unprivileged Bun API, used by Fly and ordinary Docker hosts.
- `coolify` (default): the same runtime plus the existing curl/wget probe tools.

## Reproducible release build

Commit the intended changes first. Export only the selected commit's workspace
manifests and server dependency sources into a new directory outside the checkout:

```sh
revision=$(git rev-parse HEAD)
context="$(mktemp -d)/context"
bun --no-env-file scripts/docker/server-context.ts "$revision" "$context"
docker build --platform linux/amd64 --target runtime \
  --build-arg SOURCE_COMMIT="$revision" \
  -f "$context/server/Dockerfile" -t "inline-server:$revision" "$context"
```

The exporter never reads working-tree source files, rejects symlinks in selected
inputs, excludes hidden files, environment files, common credential files and generated
outputs, and writes `source.json` with the exact commit and Git blob identities.
A dirty checkout is permitted: its changes are **not** in this context. Review
the selected commit before building. The Dockerfile-specific ignore is a second
filter; it also protects ordinary root-context development builds. Extend it
when adding a server workspace dependency outside the existing source roots.

For a local working-tree build, use `bun run --cwd server container:build`.
Its revision is marked `working-tree`; that image is for local checking only.
Coolify supplies `SOURCE_COMMIT` for its own builds. Runtime credentials belong
in the deployment platform's secret store and are never build arguments.

After Linux image and disposable-database checks pass, push the exact tested
image using the separately authorized release process. Record its registry
`@sha256:` digest and deploy that digest without rebuilding. Neither the context
exporter nor repository CI publishes or deploys anything.

## Packaged commands

```sh
bun server/dist/migrate.js
bun server/dist/verify-migrations.js
bun server/dist/encrypt-content.js --database TARGET
bun server/dist/livekit-cutover-preflight.js --expect-provider self_hosted
```

The migrator and verifier use the direct database connection. Existing
`server/scripts/{migrate,verify-migrations,livekit-cutover-preflight}.ts` paths
remain compatibility entrypoints inside the image. Their dependency graphs
are bundled, so adding an import cannot silently require another Docker copy.
Image smoke executes migration and verification `--help` paths with no runtime
credentials, and exercises native Sharp and MessagePack. CI additionally runs
migration, verification, and the bundled HTTP/WebSocket/drain artifact smoke
against disposable PostgreSQL in the final Linux image.

## Runtime

The command is `bun server/dist/index.js`: one process serving HTTP and
WebSockets on port 8000. Production requires an explicit
`INLINE_PROCESS_ROLE`: `api` serves the application and broker-backed realtime
recovery without shared workers, while `all` also owns the shared workers and
schedulers. The runtime target has no nginx, process supervisor, bundled
database, health wrapper, or migration-on-start wrapper. Fly Proxy provides
public TLS and routes directly to the traffic-serving `all` process.

Connected sessions are authenticated on admission. A committed revocation
closes local sockets immediately and publishes a peer invalidation. To catch
missed invalidations without a database lookup on every frame or legacy RPC,
the server revalidates distinct connected sessions in batches of at most 512.
The default interval is 15 seconds and the maximum authority age is 30 seconds.
If the database cannot refresh that authority before expiry, the affected
sockets close and must authenticate again. Slow queries do not extend the
deadline. These durations are configurable through
`SESSION_AUTHORITY_RECONCILIATION_INTERVAL_MS` and
`SESSION_AUTHORITY_MAX_AGE_MS`; extending them also extends the missed-event
revocation window. The maximum age must be at least two seconds so the
reconciler has a usable refresh window; a lower value is rejected in favor of
the safe 30-second default. Database outages can therefore cause reconnects
even when the WebSocket transport is healthy.

Use Fly **service-level** HTTP checks against `/readyz` on port 8000 for the
traffic-serving Machine. The checked-in health check sends
`X-Forwarded-Proto: https`, so `force_https` cannot turn the probe into an
unfollowed redirect. A Docker `HEALTHCHECK` or a top-level monitoring check is
not a replacement for a service routing check. The Fly configuration allows
45 seconds for SIGTERM shutdown, leaving five seconds after the configured
40-second drain deadline. Health failure does not itself guarantee restart or
safe promotion of another API.

For one continuously running traffic-serving API, leave autostop off and use
Fly's `on-failure` restart policy with ten retries. Service autostart can revive
that stopped Machine when a request arrives after a clean exit or exhausted
retries. The dark Machine deliberately has no service, so it cannot be
request-started. Neither feature restarts a process that remains running but is
unhealthy; monitor readiness outside the Machine and alert on sustained
failure. One traffic-serving Machine still has a host-failure window.

## Ingress configuration

`server/fly.toml` targets the authenticated Cloudflare origin: it requires
`INLINE_INGRESS_MODE=cloudflare`, the canonical `api.inline.chat` host, and
`cf-connecting-ip` as the client identity. The origin secret stays in Fly's
secret store. The runtime rejects ordinary public requests unless the host,
origin secret, and Cloudflare client-IP header agree; `/readyz` remains
available to Fly's private service check.

The same settings are used by the dark Machine because its private `/readyz`
probe must exercise the deployed startup contract. Do not use a source image
without the ingress implementation: setting these variables on an older image
does not add the forwarding boundary. The dark Machine has no Fly Proxy
service, so it receives no public traffic; its normal routes remain protected
if an operator explicitly accesses it during an approved test.

App names, regions, resource sizes, health checks and non-secret environment
settings are ordinary version-controlled configuration. Credentials belong in
Fly secrets; never place them in this file, build arguments, or source control.

## Migrations and deployment

Starting or restarting this image never runs schema migrations. It verifies
the packaged migration history against the database before listening, and
`/readyz` checks the required migration head. The explicit migration command
and the current one-API and future multi-Machine release procedures are in
[the Fly deployment guide](fly-deployment.md). The Fly configuration does not
automatically run migrations or create additional active APIs.

The temporary dark Machine runs as `api`, not `all`: it keeps HTTP, WebSockets,
authentication, broker/cache subscriptions and repair available for isolated
validation, but it does not start shared workers or schedulers. It is not a
second public API. Its absence from Fly Proxy routing is the fence against user
traffic; do not send a test mutation unless that test is separately approved.
At cutover, independently fence the old traffic-serving writer before making
the new `all` Machine routable. A public-IP change, DNS change, or failing
health check is not a writer fence.

[server/fly.toml](../fly.toml) is the committed traffic-serving configuration.
It names the planned replacement app, `inline-api`; the name and the new
Machine name must be confirmed before any live operation. The deployment
command supplies the app and immutable image explicitly. Its image placeholder
must be replaced via `--image`. [server/fly.dark-machine.json](../fly.dark-machine.json)
is the separate, service-free dark-Machine configuration. Machine identity and
the currently serving topology must be checked before applying either file;
committing them changes no running deployment.

## Validation

The Docker build checks required artifacts and executes Sharp and MessagePack
against the final production dependency layout as the runtime user. Full
qualification additionally requires Linux amd64 startup against an isolated
database, direct and proxied HTTP/WSS tests, uploads, restart/drain behavior,
and a sustained resource test. macOS dependency checks are not Linux-image proof.

The base runtime version is intentionally unchanged from the existing image.
Record the built image digest for promotion and rollback. A slimmer base,
reduced dependency set, different Bun version, or native-module changes need
their own compatibility and measured-size checks.
