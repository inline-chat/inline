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
```

The default dispatch is the explicit release action: after configured environment
approvals, it can run production DDL and replace the serving Machines. Ordinary pushes and
pull requests only run CI. Production releases share a concurrency group and do
not cancel an in-progress deployment.

The workflow performs these steps:

1. Require a manual dispatch from `main`; freeze `github.sha` for that run.
2. Call the existing Server Tests workflow, irrespective of push path filters.
   It runs the server suite, builds runtime and Coolify images, and exercises
   packaged migrations and the final runtime artifact against disposable
   PostgreSQL. Publish that tested runtime image without rebuilding and record
   its immutable registry digest. A failing parallel test job prevents promotion
   even if an unused image was already pushed.
3. Before DDL, inspect the existing Fly fleet: require healthy managed public
   Machines, reject unmanaged public writers and record the current image/IDs.
   Pull that digest in a protected production migration job; verify its source
   revision label. Run `bun server/dist/migrate.js` followed by the read-only
   `bun server/dist/verify-migrations.js` using the job's direct DDL credential.
   A failure stops the release before API replacement.
4. Re-read the fleet immediately before replacement and require the recorded
   baseline to match. Replace that set with the same digest using blue-green. A service-free dark Machine is excluded. Refuse
   incomplete Machine observations; verify the final count, image digest,
   source revision and passing service checks.
5. Perform authenticated user-path checks and inspect recovery, errors, worker
   backlog and drain outcomes. The automated Machine checks are infrastructure
   evidence, not proof that every client or provider integration works.

The runtime image is `registry.fly.io/inline-api@sha256:...`. The source manifest,
source revision label and immutable digest identify the candidate. The checked-in
Fly config contains an image sentinel so an ordinary deploy cannot silently
build or select an unqualified checkout.

### Prepare an image for rehearsal or initial bootstrap

When no healthy public fleet exists yet, or an exact-image rehearsal is needed,
dispatch from `main` with `publish_only` enabled:

```sh
gh workflow run server-deploy.yml --ref main -f publish_only=true
```

This runs the entire reusable CI workflow and publishes its tested runtime image
without rebuilding. After all CI succeeds, the run summary records the selected
source SHA and immutable digest. It skips the production environment jobs,
fleet preflight, migrations, and deployment; it never receives the production
database credential. Registry publishing still requires the repository/org Fly
token. Use the recorded digest for the separately authorized clone rehearsal
and initial Machine bootstrap. This option does not bootstrap or migrate an app.

`publish_only` defaults to `false`. Routine releases retain the healthy-fleet
preflight before DDL and the immediate baseline recheck before replacement.

### Bootstrap the first API and finish cutover in the same run

After rehearsal and the GitHub setup below, dispatch:

```sh
gh workflow run server-deploy.yml --ref main -f bootstrap=true
```

`bootstrap` defaults to `false` and cannot be combined with `publish_only`.
It still runs the full reusable CI, publishes the qualified image, and uses the
normal packaged migration and verification job. Its pre-DDL inventory requires
no service-bearing or Fly-managed Machines and every existing rehearsal Machine
stopped with healthy, complete configuration. The workflow records their IDs/versions and requires
that snapshot to match immediately before creating the first API.

The initial deploy excludes those stopped rehearsal Machines and creates exactly
one managed API with six shared CPUs and 1536 MB memory, using the qualified
digest and `--ha=false`. Only `INLINE_PROCESS_ROLE=api` overrides the repo config;
`INLINE_INGRESS_HOST=api.inline.chat` remains in place from first boot. Readiness
and TLS can be checked through `inline-api.fly.dev`; authenticated qualification
uses a private proxy/loopback with the expected Host and origin-secret headers.
The workflow verifies the new Machine, source revision, image, capacity, and
unchanged rehearsal inventory, then waits at `production-cutover`.

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
  Only the migration command step receives it, by environment variable rather than a
  command argument. Do not put this DDL credential in the API app's Fly secrets.
- Supply an app-scoped `FLY_API_TOKEN` for `inline-api`. The reusable image
  publishing job requires a repository or organization secret; production jobs
  may use a separately scoped environment secret of the same name. Environment
  secrets cannot be forwarded to a reusable workflow through its caller.
- Audit API database grants: application DML and ledger `SELECT` are required;
  schema DDL belongs to the migration role. Repository configuration does not
  itself establish provider role separation.

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

Preserve public `0150_space-profiles` and forward `0151_insights-query-indexes`.
The current migrator wraps pending DDL in one transaction: locks from 0150 can
remain held while 0151 builds indexes. Qualify pending DDL on representative
isolated data and choose an appropriate production window. Large backfills or
`CREATE INDEX CONCURRENTLY` require a separately reviewed procedure; do not
rewrite historical migrations or place concurrent indexes in this transaction.

Coolify fallback means deploying a compatible API image against the **current
PlanetScale database**, with the same encryption keys, object storage and ingress
contract. Keep the fallback stopped until the manual failover. A hostname/IP
change does not stop its workers. Restoring a database backup is a separate
disaster-recovery action, not application rollback. There is no automatic schema
rollback or automatic cross-host traffic switch.

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
