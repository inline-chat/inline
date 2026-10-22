# Fly API deployment and schema migrations

## Release contract

Use one continuously running API initially, with temporary **blue-green** overlap.
The same runtime supports two continuously running APIs later. Redis is an
optional acceleration path; PostgreSQL holds durable updates, recovery state,
authorization and worker claims. Neither API boot nor restart migrates schema.
The portable image also runs on Coolify against the same authoritative database.

The API compares its packaged Drizzle journal with `drizzle._migrations` before
listening. A missing required migration, a gap before the known head, a mismatched
active SQL hash, or the superseded local 0150 index migration stops startup.
`/readyz` checks the required migration head and removes a running API from
routing if the database is restored behind it. Readiness remains false until
mandatory startup completes. Redis loss is reported as degraded broker health
but does not remove an otherwise healthy API from routing.

A database ahead of the image is accepted when its known required head matches.
This permits **tested additive** overlap and rollback; it does not establish
compatibility with arbitrary newer DDL. Historical branch SQL differs, so the
ledger is not an exact fingerprint of every historical file or manual change.

```text
new API + missing required migration -> refuse startup
old API + tested additive schema -> permit overlap and rollback
same required migration ID + different active hash -> refuse startup
```

## Manual release from main

`.github/workflows/server-deploy.yml` has only `workflow_dispatch`. Dispatch it
from `main` in GitHub Actions, or use:

```sh
gh workflow run server-deploy.yml --ref main
# One origin alone, when that is deliberately needed:
gh workflow run server-deploy.yml --ref main -f origins=fly
gh workflow run server-deploy.yml --ref main -f origins=nuremberg
```

The default `origins=both` releases the whole fleet. An NBG-only dispatch still
checks the healthy Fly alternative and runs the shared migration gate, but
does not replace Fly or change routing.

The default dispatch is the explicit release action: after configured environment
approvals, it can run production DDL and replace the serving Machines. Ordinary pushes and
pull requests only run CI. Production releases share a concurrency group and do
not cancel an in-progress deployment.

The workflow performs these steps:

1. Require a manual dispatch from `main`; freeze `github.sha` for that run.
2. Call the existing Server Tests workflow, irrespective of push path filters.
   It runs the server suite, builds runtime and Coolify images, and exercises
   packaged migrations and the final runtime artifact against disposable
   PostgreSQL. Only after all three jobs succeed, load the saved amd64 runtime
   and ARM64 Coolify archives and publish those exact bytes to public GHCR.
   Check source/architecture and anonymous access to both immutable digests.
   Ordinary test jobs remain read-only; only this manual publisher gets package-write access.
3. Before DDL, check required credentials, anonymous image access, the Fly
   fleet and selected-origin read-only bot/chat access. Check the Coolify app
   and its health configuration when Nuremberg is selected. Save a small
   `server-release-plan` artifact with source, both digests, migration head,
   Fly baseline and original Coolify image name/tag/serving revision.
   Pull the runtime digest in the protected migration job; verify its source
   revision label. Run `bun server/dist/migrate.js` followed by the read-only
   `bun server/dist/verify-migrations.js` using the job's direct DDL credential.
   A failure stops the release before API replacement.
4. Release Nuremberg first (`scripts/ci/nbg-release.ts`): PATCH the existing
   Docker Image app to the qualified ARM64 GHCR digest, deploy through Coolify's
   API, and require finished deployment, matching configured pin, health and
   direct readiness on the release revision. Smoke-test bot login, send/readback
   and HTTP 101 upgrades on `/realtime` and `/realtime/v3`. On a confirmed failure,
   restore both original image fields, redeploy, and verify the old revision's
   readiness. Cancel an active recorded deployment before restoring; ambiguous
   queue/controller state stops for reconciliation instead of racing a restore.
5. Re-read the Fly fleet immediately before replacement and require the recorded
   baseline to match. Replace that set with the same digest using blue-green. A service-free dark Machine is excluded. Refuse
   incomplete Machine observations; verify the final count, image digest,
   source revision and passing service checks, then smoke-test Fly directly and
   canonical routing separately. An NBG-only run checks canonical routing
   against the unchanged Fly revision instead.
6. The `Release outcome` job reports published, already current or failed per
   origin, including a partial release (Nuremberg done, Fly not). Bootstrap
   completion also requires the worker-activation job. Publication-only runs
   report image publication separately without claiming a server deployment.

After a partial failure use **Re-run failed jobs**: successful jobs and the
original release plan are retained. Nuremberg resumes a recorded deployment
and rechecks the exact pin, readiness and smoke paths. Without a usable receipt,
it redeploys the same qualified digest; a matching source label alone never
skips deployment. Fly already on the selected digest is verified without
replacement. A full rerun that rebuilds different bytes cannot reuse the old
plan: start a new dispatch instead. Retained Actions artifacts expire after
90 days; keep needed recovery records before expiry.

Coolify's API on the existing installation does not expose an independent
running-container digest. Its receipt establishes the pinned controller
configuration and successful deployment, supplemented by direct runtime checks.
The smoke test's WebSocket checks prove upgrades, not authenticated sessions,
reconnect/replay or cross-origin recovery. Keep watching errors, worker backlog
and drain outcomes after release.

Both image references use `ghcr.io/inline-chat/inline-server@sha256:...`. The source manifest,
source revision label and immutable digest identify the candidate. The checked-in
Fly config contains an image sentinel so an ordinary deploy cannot silently
build or select an unqualified checkout.

Before activation, verify the effective process configuration as well as the
profile. Fly app secrets override same-named profile environment values. Require
`INLINE_REALTIME_DISTRIBUTED=1`; the legacy `REALTIME_DISTRIBUTED` must be absent
or `1`, because conflicting settings refuse startup. Also verify the effective
ingress mode, direct-IP source and query-pool cap match the qualified profile.
Keep credential values out of receipts and logs; a list of secret names alone
does not establish these effective settings.

### Release contract with a warm fallback

Since October 16, 2026, `api.inline.chat` uses Cloudflare load balancing with
Fly preferred and a running Nuremberg fallback. The workflow's default
`origins=both` updates and verifies Nuremberg before Fly in the same run.
A `fly`-only release leaves Nuremberg on its previous revision; the
run summary says so, and the requirements below then apply manually.

Before releasing the next selected `main` SHA to Fly, qualify that same SHA's
ARM64 image on Nuremberg against the intended schema and runtime configuration.
Record the selected SHA, both immutable image digests, each origin's effective
image/configuration, the compatible rollback release, and the unchanged
Cloudflare pool identities/order. Apply DDL once through the existing migration
gate only after old/new/rollback schema compatibility is established. Replace
and qualify Nuremberg before replacing Fly, keeping another ready origin during
each replacement. Verify direct HTTP/V2/V3 and cross-node recovery, then verify
canonical routing and both effective release identities after the Fly rollout.

The default release enforces the ordering, immutable pins and origin checks above.
Cloudflare pool identity/order and schema-compatibility decisions remain
operator checks, and a green `fly`-only run is not completion of the fleet
release. Deliberate mixed-version
overlap needs a recorded compatibility decision and an owner/deadline for
finishing it; it must not leave an indefinitely stale standby. See
[the standby release procedure](hetzner-standby.md#rolling-upgrades-and-removing-a-node).

### Prepare an image for rehearsal or initial bootstrap

For an exact-image rehearsal, manually dispatch from the selected branch in
`inline-chat/inline` with `publish_only` enabled. For example, to qualify the HA
candidate without merging it or changing production:

```sh
gh workflow run server-deploy.yml --ref codex/multi-node-ha -f publish_only=true
```

This runs the entire reusable CI workflow and publishes its tested amd64 runtime
and native ARM64 Coolify images without rebuilding. After all CI succeeds, the
run summary records the selected source SHA and both immutable digests.
Tags, pull-request refs and fork repositories are rejected. It skips the
production environment jobs, fleet preflight, migrations, and deployment; it
never receives the production database credential. Registry publishing uses the
job's short-lived `GITHUB_TOKEN`, not a Fly token. Use the recorded digest for the separately authorized clone rehearsal
and initial Machine bootstrap. This option does not bootstrap or migrate an app.

`publish_only` defaults to `false`; a branch dispatch without it fails before
publication. Production and bootstrap dispatches still require `main` and cannot
run in publish-only mode. Routine releases retain the healthy-fleet
preflight before DDL and the immediate baseline recheck before replacement.

### Bootstrap the first API and finish cutover in the same run

After rehearsal and the GitHub setup below, dispatch:

```sh
gh workflow run server-deploy.yml --ref main -f origins=fly -f bootstrap=true
```

`bootstrap` defaults to `false` and cannot be combined with `publish_only`.
It still runs the full reusable CI, publishes the qualified image, and uses the
normal packaged migration and verification job. Its pre-DDL inventory permits
stopped, service-free, unmanaged rehearsal Machines and optionally one healthy
managed API-only Machine with the production ingress host and expected size.
It records rehearsal IDs/versions and the existing API's ID/version/digest/revision,
then requires that snapshot to match immediately before deployment.

The initial deploy excludes those stopped rehearsal Machines and creates exactly
one managed API with six shared CPUs and 1536 MB memory, using the qualified
digest and `--ha=false`. Only `INLINE_PROCESS_ROLE=api` overrides the repo config;
`INLINE_INGRESS_HOST=api.inline.chat` remains in place from first boot. Readiness
and TLS can be checked through `inline-api.fly.dev`; authenticated qualification
uses a private proxy/loopback with the expected Host and origin-secret headers.
The workflow verifies the new Machine, source revision, image, capacity, and
unchanged rehearsal inventory, then waits at `production-cutover`.

If a previous bootstrap created the API but stopped before cutover, dispatch
`bootstrap=true` again. The same strict preflight must pass; the new run qualifies
its own image, applies the idempotent migration job, and blue-greens only the
existing API to that image while keeping its role `api`. Rehearsal Machines remain
untouched. Every deployment polls for the expected image and service readiness
before postflight checks: at most 30 reads, each capped at five seconds, with
five-second intervals. An API that remains unhealthy fails the gate.

Before approving that job, qualify authenticated paths, transfer the production
hostname and routing while both APIs are alive, verify traffic on the new API,
then disable autostart and stop the old all-role API. Attaching the Fly certificate
can itself move hostname routing; treat it as a live cutover action. The final
job rechecks the exact bootstrap Machine ID/version/digest and API-only role. A
separate read-only credential verifies the configured predecessor exists and
every nondestroyed legacy Machine is observable and stopped, including detached
workers; all legacy services must explicitly have `autostart=false`.

Only then does the same workflow blue-green the selected bootstrap Machine to
the standard `all` role with the same qualified digest. It neither rebuilds nor
reruns migrations. The API keeps serving while its replacement starts; the
intentional worker pause avoids overlap with unfenced legacy workers. Final
checks require one healthy public Machine with the expected digest, revision,
production ingress host, and `all` role. A failed gate stops this continuation;
it does not roll back DDL or automatically re-enable the predecessor.

### Required GitHub setup

- Create a `production` environment restricted to `main`; configure reviewer
  approval according to the release policy.
- Before any bootstrap dispatch, create `production-cutover`, restrict it to
  `main`, and configure a required reviewer. Verify the protection is active;
  merely naming an environment in YAML does not make it approval-gated. Set its
  `PREDECESSOR_FLY_APP=inline-fra-standby` and
  `PREDECESSOR_MACHINE_ID=683d52ea309078` variables. Store the temporary read-only
  legacy-app credential as its environment-only `LEGACY_FLY_READ_TOKEN`; it is
  exposed only to the predecessor readback step. The new-app `FLY_API_TOKEN`
  continues to authorize deployment to `inline-api`.
- Store `PRODUCTION_DATABASE_MIGRATION_URL` only in `production`. It must be a
  direct PostgreSQL endpoint reachable from the hosted runner with verified TLS.
  Preflight checks that it is configured; only the migration command step uses
  it against the database, by environment rather than a command argument. Do
  not put this DDL credential in either API's runtime secrets.
- Supply an app-scoped `FLY_API_TOKEN` for `inline-api` in `production`.
  Registry publication and migrations no longer require Fly registry access.
- Make the GHCR `inline-server` package public before production release.
  New packages default to private even for public source repositories; anonymous
  manifest checks deliberately fail until visibility is public. A publish-only
  run can create the package without accessing production, after which its
  visibility can be configured and the failed publisher rerun.
- Audit API database grants: application DML and ledger `SELECT` are required;
  schema DDL belongs to the migration role. Repository configuration does not
  itself establish provider role separation.

- For Nuremberg, in `production`: secrets `NBG_ORIGIN_IP` and
  `COOLIFY_NBG_TOKEN` (team-scoped API access to read/update/deploy/cancel the
  selected app); variables `COOLIFY_URL` (HTTPS origin) and
  `NBG_COOLIFY_APP_UUID`. Use an expiring token with a renewal owner. No SSH
  key, loopback registry tunnel or host registry credential is required.
  Coolify's digest representation uses image name `ghcr.io/inline-chat/inline-server@sha256`
  and the 64-character digest as image tag, producing `repo@sha256:<digest>`
  on older and newer versions. Retain the existing app's runtime configuration.
- Set `FLY_ORIGIN_IP` in `production` to the Fly ingress address. Smoke requests
  keep `api.inline.chat` as Host/SNI and pin the connection to each origin.
- For smoke tests: secret `SMOKE_BOT_TOKEN` for a dedicated smoke bot and
  variable `SMOKE_CHAT_ID` for a private chat that only the bot and operators
  can read. Never point it at a teammate or customer chat.

After hosted qualification succeeds, audit remaining consumers before removing
obsolete CI SSH secrets. This workflow no longer consumes `NBG_SSH_HOST`,
`NBG_SSH_KEY`, `NBG_KNOWN_HOSTS` or `STANDBY_RELEASE_SSH_KEY`; local emergency
tools may still have their own independent host access.

If the direct database is not reachable from GitHub, use a trusted private
runner or a separately scoped migration execution environment. Do not silently
move DDL credentials into Fly API secrets: Fly release Machines inherit those
same app-scoped secrets.

## Blue-green and graceful shutdown

Fly blue-green starts a replacement beside each selected running Machine,
waits for health checks, then changes routing and stops the old set. One normally
becomes two temporarily and returns to one; two normally become four temporarily
and return to two. `--ha=false` suppresses automatic spare creation. This
preserves the current capacity policy without a server topology flag.

The workflow uses the equivalent of:

```sh
fly deploy --config server/fly.toml --image "$IMAGE_DIGEST" \
  --only-machines "$PUBLIC_MACHINE_IDS" --strategy bluegreen --ha=false \
  --signal SIGTERM --wait-timeout 5m --yes
```

Both generations can run `INLINE_PROCESS_ROLE=all`. Database claims and ownership
tokens coordinate durable workers; webhook delivery remains at-least-once, with
`x-inline-update-id` available for receiver deduplication. Keep Grid provider
targets stable during routine releases; changing providers requires draining
old-target effects and a separate cutover.

On SIGTERM, the old process withdraws admission/readiness, drains admitted HTTP,
realtime and tracked background work, and disconnects clients for reconnect and
durable catch-up. WebSockets are not transferred between processes. Fly allows
45 seconds, with a 40-second application drain budget. Forced termination after
that deadline still requires durable retries; graceful shutdown is not crash
recovery. Monitor timeouts and reconnect/catch-up outcomes.

## Migration safety and rollback

The migrator uses one direct PostgreSQL connection and a transaction-scoped
advisory lock shared with its DDL. It validates history, applies pending Drizzle
migrations and verifies the resulting head. Competing migration jobs fail before
writing. Lock timeout is five seconds, statement timeout is 30 seconds, and idle
transaction timeout is 15 seconds. These are not a total transaction deadline.

Use **expand -> deploy -> backfill -> contract in a later release**. Old and new
binaries overlap, and a migration can commit even if API deployment later fails.
Never remove a column or change its meaning while an old binary or rollback
candidate still requires it. Test the chosen rollback image on the resulting
schema before promotion.

Retain each rollback image together with its compatible Machine configuration
in the protected recovery capture. An image-only rollback is insufficient:
binaries that predate optional ingress reject `cloudflare-optional`, so restore their strict
`cloudflare` ingress configuration and preserve its origin-attribution secret
alongside the old image. Those binaries also lack the query-pool cap and can use
10 query plus one health connection each. Such a legacy rollback needs a
separate ingress and whole-fleet connection-budget plan; do not count the new
cap as a limit on an old binary. If that plan requires withdrawing an origin,
first verify a ready alternative and its routing. This is not an instruction
to stop the current warm Nuremberg fallback during an ordinary compatible
rollback. Verify the selected image, effective settings, schema compatibility
and authenticated serving path before returning traffic.

Preserve public `0150_space-profiles` and forward `0151_insights-query-indexes`.
The current migrator wraps pending DDL in one transaction: locks from 0150 can
remain held while 0151 builds indexes. Qualify pending DDL on representative
isolated data and choose an appropriate production window. Large backfills or
`CREATE INDEX CONCURRENTLY` require a separately reviewed procedure; do not
rewrite historical migrations or place concurrent indexes in this transaction.

Coolify fallback means deploying a compatible API image against the **current
PlanetScale database**, with the same encryption keys, object storage and ingress
contract. The current Nuremberg fallback stays running so Cloudflare can route
new connections to it automatically when the preferred Fly pool is unhealthy.
A stopped fallback supplies only manual recovery capacity. Existing WebSockets
need reconnect/catch-up; a hostname or pool change neither moves their sockets
nor stops their workers. Restoring a database backup is a separate
disaster-recovery action, not application rollback. There is no automatic schema
rollback.

## Initial app setup and regional reliability

`inline-api` is the intended Fly app identity; `api.inline.chat` stays public.
The routine workflow requires an already bootstrapped healthy public Machine.
Before first use, confirm account/app ownership, stage runtime secrets, allocate
networking and certificates, enforce the Cloudflare origin policy, and qualify
one Machine from the tested image. A new app or cross-host cutover is a separate
operation from replacing an existing managed fleet.

`fly.dark-machine.json` remains an optional service-free validation configuration.
It uses the same image and real dependencies with `INLINE_PROCESS_ROLE=api`,
which omits shared workers. It is not a sandbox, cannot receive Fly Proxy traffic,
and must not be promoted implicitly. A validation-only Machine in another app
cannot be moved into `inline-api`. Verify actual old/new binary compatibility
and stop the retired host's workers before completing a cross-host cutover.

Redis can be added or replaced without changing database authority. A regional
broker outage leaves connected clients using slower PostgreSQL recovery;
typing/presence may disappear and cross-instance private bot operations return
retryable failure. This does not make PostgreSQL or the single API region highly
available. A Redis regional replica with managed failover or Sentinel is a
separate availability decision. Two unrelated Redis servers are not a failover
pair; do not introduce NATS solely for this release's optional fast path.

## Qualification boundaries

Local tests cover source behavior; CI Linux builds cover packaging; provider
readback and real user-path exercises cover the live release. Do not substitute
one for another. Before rollout, record pending migration/lock evidence, the
compatible rollback digest, broker-loss repair behavior, shared-worker overlap,
client reconnect, and supported uploads/Bot API/realtime paths. `/readyz` and
`fly deploy` success alone are insufficient.

References: [Fly deployments](https://docs.fly.io/launch/deploy/),
[seamless deployments](https://docs.fly.io/blueprints/seamless-deployments/),
[Fly app secrets](https://fly.io/docs/apps/secrets/),
[GitHub reusable workflows](https://docs.github.com/en/actions/concepts/workflows-and-actions/reusing-workflow-configurations),
and [Redis Sentinel](https://redis.io/docs/latest/operate/oss_and_stack/management/sentinel/).

### Preparing optional Cloudflare ingress

`INLINE_INGRESS_MODE=cloudflare-optional` permits direct requests for the configured
`INLINE_INGRESS_HOST`. Application authentication remains in force. A valid
`INLINE_ORIGIN_SECRET` authenticates Cloudflare client-IP attribution, but is no
longer required to admit a normal request. Without a valid secret, all supplied
Cloudflare and competing forwarding headers are discarded.

This mode also requires `INLINE_INGRESS_DIRECT_IP_SOURCE`:

- `fly-client-ip`: only behind Fly's HTTP proxy, with no alternate public path
  to the application port. Fly supplies this header; with Cloudflare in front it
  identifies Cloudflare's edge unless the origin attribution secret is valid.
- `x-real-ip`: only behind a qualified reverse proxy that overwrites this header
  and prevents direct public access to the application port.
- `socket`: trust only the socket peer. This is safe from forwarding-header
  spoofing but can group users behind a proxy into one rate-limit identity.

Keep `INLINE_TRUSTED_CLIENT_IP_HEADER=cf-connecting-ip`: the ingress policy
normalizes the validated chosen address into that header for HTTP and realtime.
Do not select a header fallback solely because a client can send it. Verify the
proxy overwrite and port isolation using forged-header requests in the actual
hosting environment before enabling the mode. Host validation still applies.

The checked-in Fly profile enables `cloudflare-optional` ingress with the
provider-owned `fly-client-ip` fallback and `INLINE_REALTIME_DISTRIBUTED=1` for
deployment overlap. Existing strict origins keep their running configuration
until this profile is deliberately deployed. Optional-mode unit tests are not
deployment proof. Before changing DNS, deploy the qualified image/config,
verify canonical public TLS and renewal, test an ordinary route
without the origin secret, then authenticate and reconnect real clients. A
successful `/readyz` alone does not prove bypass readiness.
