# Fly API deployment and schema migrations

## Decision

The API and the schema migrator are separate commands in the same immutable
image. Neither the Fly API command nor the Coolify API entrypoint writes schema
on startup. The API compares its packaged Drizzle journal with
`drizzle._migrations` before opening its listener. A missing or behind
required migration, a gap in the recorded sequence, or a mismatched active
SQL hash stops startup. `/readyz` also checks the required migration head,
so restoring an older database removes an already-running API from routing.
A database ahead of the image is accepted when its known sequence and required
head match. This permits expand/contract rollouts and a tested app rollback;
it is **not** proof that an arbitrary newer schema is compatible. Historical
SQL files changed across previous branches, so old hashes are not treated as
an exact schema fingerprint; schema compatibility still needs real tests.

The sole schema writer is `bun server/dist/migrate.js`, executed against a
direct PostgreSQL connection (never the PgBouncer transaction pool). It takes
a transaction-scoped PostgreSQL advisory lock on the same connection as the
DDL, checks that required migrations have no gaps through
the database head, runs Drizzle, and verifies the required resulting head.
Concurrent jobs fail before writing. It has a 5-second lock timeout, a
30-second statement timeout, and a 15-second idle-transaction timeout. The
runner must use the exact image selected for the API release. A failed
migration stops promotion; investigate before retrying.

## Dark validation then traffic cutover

The new Machine is test-only until the public IP is switched. The repository
has two deliberately separate configurations:

- `server/fly.dark-machine.json` starts `INLINE_PROCESS_ROLE=api` and has no
  `services` entry. It serves the full HTTP/WebSocket/authentication and
  broker-backed recovery stack, but it starts no shared worker or scheduler and
  Fly Proxy cannot route user traffic to it.
- `server/fly.toml` starts `INLINE_PROCESS_ROLE=all`, owns the shared workers
  and schedulers, and is the only configuration with a public HTTP service.

The dark process has the real database, broker, and application credentials.
No public routing makes it a safe transport and startup check, not a sandbox.
Do not exercise writes through it unless that exact test has been approved.
Do not treat a healthy dark Machine, a public-IP switch, or a failed service
check as a fence for an old writer.

1. Freeze the source revision; run CI, build the Fly Linux image, exercise it
   against an isolated database, and record its immutable digest. Inspect every
   pending migration for old-API compatibility, transaction duration, and lock
   impact. Confirm a current backup and a tested restore path before risky DDL.
2. Inspect the live API, Fly Machine, routing, secret names, database ledger,
   and direct connection mode. Run the packaged read-only gate with
   `bun server/dist/verify-migrations.js` against the selected database.
   A behind result is expected before a planned migration and blocks promotion
   until the controlled migration succeeds. Never use a stale backup for an
   API-host rollback.
3. If migrations are pending, run `bun server/dist/migrate.js` once in a
   controlled one-off execution of that exact image with the direct migration
   credential. Do not paste a database URL into command arguments or logs.
   The command is a no-op if the ledger is already current. Confirm its exit
   status and rerun the read-only gate before continuing.
4. Create the dark Machine from the immutable image and the separate Machine
   configuration. Confirm the intended app and the new Machine name first;
   neither is inferred from this repository. `inline-api-fra-1` is a suggested
   name only, not a name reserved or checked at Fly. Put the exact immutable
   digest into a temporary complete Machine config; never create from the
   checked-in placeholder. If this exact Machine will become the
   traffic-serving Machine, `FLY_DARK_APP` must equal `FLY_APP`: a Fly Machine
   cannot move to another app. A dark Machine in a separate app is
   validation-only; create a separate traffic-serving Machine in `FLY_APP`
   from the verified digest after it passes its own migration and fencing gate.

   ```sh
   dark_config="$(mktemp)"
   jq --arg image "$IMAGE_DIGEST" \
     '.image = $image' server/fly.dark-machine.json > "$dark_config"
   fly machine create "$IMAGE_DIGEST" --app "$FLY_DARK_APP" \
     --name "$DARK_MACHINE_NAME" --region fra \
     --machine-config "$dark_config"
   fly machine start "$DARK_MACHINE_ID" --app "$FLY_DARK_APP"
   fly machine status "$DARK_MACHINE_ID" --app "$FLY_DARK_APP" --display-config
   ```

   `IMAGE_DIGEST` must be a full immutable `registry/repository@sha256:...`
   reference. The read-back must show that image,
   `INLINE_PROCESS_ROLE=api`, and no `services` entry.
   It must also retain `fly_platform_version=v2` and
   `fly_process_group=app`; those metadata fields make this Machine eligible
   for the documented same-app `fly deploy --only-machines` promotion. Do not
   remove them or use that promotion command for a standalone Machine.
   Use a private operator tunnel or Machine console to check `/readyz`; do not
   add a public port, custom hostname, or `http_service` to this Machine.

5. Before making the new Machine public, re-read its complete live configuration
   and the old writer's state. Machine updates replace configuration rather than
   patching it, so start from the fresh read-back, preserve required settings,
   change the role to `all`, and apply the public service specification in
   `server/fly.toml`. This promotion path requires `FLY_DARK_APP == FLY_APP`.
   Fence the old API, including request-triggered autostart
   and every shared worker, before that update starts. Confirm the new Machine's
   service check, authenticated HTTP, both realtime transports, uploads, Bot
   API polling/webhooks, workers, and drain/restart before switching the public
   IP.
6. Keep the old app and a known-compatible image available but stopped after the
   public switch. On failure, select exactly one fenced writer and roll back
   only to an application image confirmed to work with the resulting schema.
   Never roll back the shared database merely to reverse an API-host deployment.

## Preparing the planned replacement app `inline-api`

The app name is infrastructure identity; the public API remains `api.inline.chat`.
This repository currently targets `inline-api`, but does not reserve the name
or create resources. Confirm that app name and the dark-Machine name before the
live operation. The image is independent of the Fly app name and can be built
and tested before cutover.

Prepare the exact committed image on an approved Linux builder:

```sh
revision=$(git rev-parse HEAD)
context="$(mktemp -d)/context"
bun --no-env-file scripts/docker/server-context.ts "$revision" "$context"
docker build --platform linux/amd64 --target runtime \
  --build-arg SOURCE_COMMIT="$revision" \
  -f "$context/server/Dockerfile" \
  -t "registry.fly.io/inline-api:$revision" "$context"
```

Run the Linux packaging and disposable-database checks before publishing. Record
the commit, source manifest, image digest, and migration head together. The
working tree may contain unrelated work; it is not included in this context.
The Cloudflare ingress implementation must be committed and qualified before
selecting a production cutover image. The public configuration requires the
Cloudflare origin secret to be staged in the target app's secret store; do not
put it in a build argument, this file, or a command line.

For the separately authorized live operation, check app availability, account
ownership, deploy access, secret names, target IPs, `api.inline.chat`
certificate, and Cloudflare origin policy. An existing image in the same Fly
organization can be reused across apps; the new name does not require a
rebuild. The dark Machine is created before the public Machine is made
routable, as described above.

See Fly's [app creation](https://fly.io/docs/flyctl/apps-create/),
[registry and cross-app image reuse](https://fly.io/docs/blueprints/using-the-fly-docker-registry/),
and [app secrets](https://fly.io/docs/apps/secrets/) documentation.

## Updating an approved traffic-serving Machine

After the migration gate passes, the old writer is fenced, and the complete
target Machine configuration has been read back and reviewed, use the committed
public configuration and immutable image digest:

```sh
fly deploy --config server/fly.toml --app "$FLY_APP" \
  --image "$IMAGE_DIGEST" --only-machines "$FLY_MACHINE_ID" \
  --update-only --ha=false --strategy immediate
```

`IMAGE_DIGEST` must be a full `registry/repository@sha256:...` reference, not a
mutable tag. Check the app and Machine ID together immediately before execution.
`--only-machines` restricts the update; `--update-only` prevents creating a new
Machine; `--ha=false` disables spare-Machine creation. Immediate replacement
accepts a short outage while the single traffic-serving API drains and restarts.
The configuration alone cannot enforce a single writer: verify all other API
Machines and the fallback host are fenced. Do not use this managed-deployment
command to promote a detached dark Machine without first reviewing its complete
live configuration and Fly's resulting service diff.

After deployment, read back the image digest and effective Machine settings,
then run the user-path checks above. A failed smoke check stops the procedure
for manual investigation. No automatic rollback or routing switch is armed.
The operator chooses whether to restore a compatible image, after fencing the
failed writer. A health check only controls routing; it does not prove recovery.

## After multi-Machine behavior is qualified

Use Fly's release phase for ordinary additive migrations:

```toml
[deploy]
  release_command = "bun server/dist/migrate.js"
  release_command_timeout = "10m"
  strategy = "rolling"
```

Fly runs the command once per deploy attempt in a temporary Machine built from
the new image, before it changes API Machines; a nonzero exit stops that
deploy. The temporary Machine has network and app secrets but no volumes.
`/readyz` is the service-level routing check. Rolling and blue/green overlap
old and new versions, so migrations must follow **expand → deploy → backfill →
contract in a later release**. Do not drop a column, change a meaning, or
make an old writer invalid while it may still serve traffic or be rolled back.
Large backfills and DDL needing `CREATE INDEX CONCURRENTLY` need their own
reviewed job: the current Drizzle migrator wraps migrations in a transaction.

Serialize deployments per environment in the release pipeline, pin the image
digest, use an app-scoped Fly deploy token, and record the source revision,
image digest, migration result, Fly release, health checks, and authenticated
smoke result. A schema migration may commit even if subsequent API rollout
fails; rollback is an app-image decision against the resulting schema.

## Options and tradeoffs

| Method                                          | Security and failure mode                                                                                                                                                                  | Performance and cost                                                                                                                 | Fit                                                                                                   |
| ----------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ------------------------------------------------------------------------------------------------------------------------------------ | ----------------------------------------------------------------------------------------------------- |
| Migrate in every API startup                    | Every API needs DDL credentials; concurrent boots can race and a restart can mutate the database.                                                                                          | Adds migration work and potential DDL locks to every boot.                                                                           | Reject.                                                                                               |
| Controlled one-off job before promotion         | Can use a separate direct DDL role and a short-lived execution identity; operator/pipeline must keep image and target aligned.                                                             | No standing migration Machine; one bounded job per release.                                                                          | Recommended for dark validation and the current one-API traffic cutover.                              |
| Fly `release_command`                           | One job per deploy attempt and deploy stops on failure. Fly gives the release Machine the app's secrets, so the normal API Machines can also access any DDL credential stored on that app. | Temporary VM billed only while running; no standing service. Default VM size follows the app and can be reduced after qualification. | Recommended automatic path after multi-Machine qualification if shared-secret exposure is acceptable. |
| Separate migration Fly app or trusted CI runner | Strongest credential split: deploy token and DDL role can be confined to the migrator; more configuration and a second failure surface.                                                    | No continuously running worker required; stopped Fly Machines incur only rootfs cost. Additional pipeline maintenance.               | Use if least-privilege DDL isolation is required.                                                     |

For every option, keep credentials in managed secrets and use strict TLS to
PlanetScale. The API role needs application DML and `SELECT` on
`drizzle._migrations`, not schema DDL once the migration runner has a separate
role. The current credentials and provider role grants must be audited before
claiming that separation exists. Do not activate PgBouncer until its separate
role timeout defaults and exact image are qualified; migrations remain direct.

One running API has the lowest Fly compute cost and a host-failure window.
Two continuously running APIs roughly double API compute plus connections but
provide a healthy alternative during host failure. Rolling/canary/blue-green
temporarily add compute during replacement; blue/green starts a full new set
before traffic moves. Migration checking reads roughly 151 small ledger rows
once on startup and one small head query per `/readyz` probe, not per user
request. DDL locks and data rewrite are the performance risk, not the gate.

Fly references: [release commands and strategies](https://fly.io/docs/reference/configuration/#the-deploy-section),
[service health checks](https://fly.io/docs/reference/health-checks/),
[secrets](https://fly.io/docs/apps/secrets/),
[scoped tokens](https://fly.io/docs/security/tokens/), and
[Machine pricing](https://fly.io/docs/about/pricing/).
