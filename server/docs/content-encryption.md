# Content storage encryption

Inline uses server-side encryption at rest. The server can decrypt content to deliver messages and run enabled features; this is not end-to-end encryption. Publishing the source does not enable the deployment settings or migrate existing data.

## Coverage

| Data | Storage / delivery |
| --- | --- |
| Message text, entities, rich blocks, translations, existing attachment content | Existing authenticated encryption; legacy message text is included in the migration below |
| Thread titles, descriptions and emoji | Authenticated encryption; scoped keyed title lookup |
| Reactions | Authenticated encryption; keyed identity preserves uniqueness and removal |
| Staged filenames, preview site names, external-task URLs, voice waveforms | Authenticated storage codecs; normal API values remain unchanged |
| Legacy server drafts | Deprecated; compatible reads/clears retained, existing values encrypted by the migration |
| URL preview and image-job lookup fingerprints | HMAC-SHA-256, with compatible legacy reads during migration |
| Protocol replay results | Existing replay cipher and retained key ring; enabled separately and migrated by the same command |
| Capable Apple message notifications | Existing encrypted previews |
| Other Apple alerts, older clients and experimental Expo clients | Generic notification text and navigation IDs; no authored preview content |
| Media objects in R2 | Existing provider-managed encryption; no object rewrite or delivery change in this migration |

IDs, relationships, timestamps, sizes, MIME types, integrity digests and service/provider identifiers remain operational metadata. Keyed lookup tokens still reveal equality within their scope. The shared preview cache reveals repeated URLs across its users. Authorized recipients, enabled bots, AI services, transcription and task integrations process content as required by those features.

## Cryptography and compatibility

New text values use the `inline-content:v1:` envelope followed by base64(nonce, ciphertext, tag). Binary fields use the same marker followed by those raw bytes. AES-256-GCM uses random 12-byte nonces and 16-byte authentication tags. HKDF-SHA-256 derives separate field-encryption and lookup keys from the existing 32-byte hexadecimal `ENCRYPTION_KEY`; the field purpose is authenticated as AAD. There is a 1 MiB per-value ceiling, with existing title/emoji character limits retained. Empty strings, nulls and binary waveforms retain their API semantics.

This format authenticates a field purpose, not the row identity. It protects content in a database copy without the server key; it does not claim protection against a compromised running server or an administrator able to rewrite the database and its constraints. No new cryptographic service or dependency is required.

Drizzle codecs handle inserts, updates, returned values, projections and relational reads. Raw SQL bypasses them: raw writers must use the encryption helper, and queries must not compare randomized ciphertext with a newly encrypted value. Titles and reactions have dedicated keyed equality tokens instead.

Readers accept old plaintext during rollout and authenticate recognized encrypted values. Unknown marked versions and malformed ciphertext fail rather than silently becoming plaintext. Legacy plaintext beginning with the reserved marker is an explicit migration conflict; investigate it instead of overriding the check.

Titles retain their display casing. Their keyed lookup uses JavaScript Unicode lowercase and ASCII-space trimming, scoped to the space or home-thread owner. The old SQL fallback retains its existing database-collation behavior until migration. Some Unicode case equivalences (for example dotted capital I) differ by database collation; after migration lookup consistently uses the JavaScript normalization. This does not rename titles or merge rows. Verify representative titles for a deployment with locale-specific conventions.

The v1 root key is deliberately stable. **Do not replace `ENCRYPTION_KEY` to rotate it**: existing message ciphertext and the new lookup indexes depend on it. Back up and retain it separately from database backups. Automatic rotation, retained content-key envelopes and row-specific AAD are follow-up work; the existing replay key ring is independent and already supports retained keys.

## Coolify rollout checklist

Use the same release and keys for every API process and worker. This is a reader-first rollout followed by a runtime setting change; **do not enable new writes while any old binary is running**. No source checkout or handwritten migration script is needed in the container.

### 1. Back up and record the recovery point

In the database's Coolify **Backups** page, run **Backup Now** on its backup configuration and wait for success. Restore that backup into an isolated database and confirm it is readable. Retain the matching `ENCRYPTION_KEY` and all existing replay keys in your secret manager. The apply command's backup flag acknowledges this work; it cannot verify it for you. [Coolify backup instructions](https://coolify.io/docs/databases/backups)

Record the release/image being deployed, the previous release, the backup identifier and the database name. Use the database name from your database resource, not a connection URL, in the commands below. Run everything against the restored copy first, then repeat the same sequence in production.

### 2. Deploy compatible readers everywhere

In the application's **Configuration → Environment Variables**, use **Normal** view to add/update only the entries below. Keep secrets available at runtime; leave **Build Variable** disabled for keys. Save changes. [Coolify environment settings](https://coolify.io/docs/applications/configuration/environment-variables)

| Variable | Reader deployment | After every reader is upgraded |
| --- | --- | --- |
| `ENCRYPTION_KEY` | Keep the existing value | Keep the same value |
| `CONTENT_ENCRYPTION_WRITES` | `false` | `true` |
| `INLINE_PROTOCOL_REPLAY_KEY_RING_JSON` | Keep the existing ring; create only if absent | Keep the same ring and retained keys |
| `INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS` | Keep its existing value (default `false`) | `true` |

If a replay ring does not exist yet, generate a new one locally. On macOS this command copies the JSON directly to the clipboard without displaying it:

```sh
bun -e 'import { randomBytes } from "node:crypto"; process.stdout.write(JSON.stringify({activeId:"replay_v1",keys:{replay_v1:randomBytes(32).toString("base64")}}))' | pbcopy
```

Paste it into `INLINE_PROTOCOL_REPLAY_KEY_RING_JSON` as a single JSON value and save a copy in your secret manager. **Never replace an existing ring with this new one**: retained replay results require their original keys. Do not change the other protocol keys for this rollout.

Deploy this release to every API process and worker. The normal container startup applies migration `0149`; it adds columns/indexes and widens title/emoji storage without rewriting content. Check that migration and startup succeed on every instance. Schedule the deployment in a quiet window because the DDL takes PostgreSQL locks. Open existing chats and attachments before continuing.

### 3. Verify existing data without changing it

Open the running application container's **Terminal** in Coolify and run, replacing `YOUR_DATABASE_NAME`:

```sh
bun /usr/src/app/server/dist/encrypt-content.js --database YOUR_DATABASE_NAME
```

Proceed only when it exits successfully with `"status":"verified"`. Nonzero `remaining` counts are expected at this stage; they describe work still to do. A verification failure must be investigated before applying.

### 4. Enable writes, restart, then run one command

Set `CONTENT_ENCRYPTION_WRITES=true` and `INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS=true` in Coolify, save, and restart/redeploy **every writer** so the new runtime settings take effect. Keep the key values unchanged. Confirm all instances are healthy. Create/edit a thread, send a message, add/remove a reaction, and upload a file using a test account.

Then run this in one application container terminal:

```sh
bun /usr/src/app/server/dist/encrypt-content.js --database YOUR_DATABASE_NAME --apply --backup-verified --readers-ready
```

Keep the terminal open until completion. The command coordinates against duplicate runners, converts retained content in bounded transactions, verifies each conversion, and installs checks against plaintext regressions. No application startup hook automatically converts the database.

### 5. Confirm completion and keep the safe rollback release

Require `"status":"complete"`, all `remaining` counts equal to `0`, and exit code `0`. Rerun the read-only command from step 3; expect `"status":"verified"` with zero counts. Keep both write flags enabled.

Using a test account, check old/new messages; thread rename, move and title linking; reaction add/remove/retry; file and voice upload/playback; URL previews; reconnect/retry; and notification navigation on a real Apple device. Older/experimental clients now receive generic previews. Confirm the production logs contain no test message text. Save the completion counts with the release record, without copying any authored content or keys.

The reader-compatible release from step 2 is the oldest safe binary for rollback after encrypted writes begin. After completion checks are installed, that release must also run with both write flags enabled and the same keys. A server restart does not undo the data migration.

### If the command stops

| Output / situation | Action |
| --- | --- |
| Wrong target, missing acknowledgements or disabled writer flags | Correct the command or complete the preceding rollout step; rerun. Do not bypass the check. |
| Another backfill is running | Let the existing runner finish. One terminal is enough. |
| Interrupted / time budget reached | Committed conversions are retained. Rerun the same command. If it repeatedly stops in the same phase, use `--max-minutes 60` (maximum `120`) and, if database load permits, `--batch-size 500`. |
| Lock timeout / completion check failure | Check database contention and that every writer uses this release and enabled flags, then rerun in a quieter window. |
| Cipher/key/content verification or representation conflict | Stop the apply attempt. Check that the original keys are configured, reproduce against the restored copy and inspect the indicated phase privately. Do not replace keys, erase rows, clear plaintext manually or disable checks. |
| App errors after enabling writes | Roll back only to a compatible release with the same keys and enabled flags; investigate before retrying. |

A source checkout can run the same tool with `bun run db:encrypt-content --database YOUR_DATABASE_NAME` from `server/`.

## Safety and completion

The command checks the configured and actual database names, validates key configuration, takes a dedicated advisory lock, and processes bounded batches under row locks. The default is 100 rows per batch and 20 minutes; optional `--batch-size 1..500` and `--max-minutes 1..120` adjust these bounds. Existing database statement/lock timeouts also apply. It pauses briefly between batches.

It verifies plaintext/ciphertext agreement before clearing legacy message text, including empty strings and messages above the old 20 KB ceiling. Partial or disagreeing message copies are retained and reported as conflicts. New field values are read back and authenticated inside the transaction before commit. Preview identities and active image-job leases are preserved. The replay repository performs its own bounded conversion.

The command reports table names and counts, never row payloads, keys, connection strings or raw database errors. `status: complete` and exit code 0 mean the current rows covered by this migration have zero remaining legacy representations and the no-plaintext CHECK constraints have validated. These checks also reject subsequent plaintext writes and legacy URL fingerprints. They validate storage format, not application authorization or all historical ciphertext in every table.

On interruption, timeout, lock contention or a conflict, it exits nonzero with the failing stage. Committed transactions stay committed; a failed transaction rolls back. Conflicting message copies are retained, while other verified message conversions in the batch may already have committed. Resolve the cause and rerun the same command. It rescans from the start, authenticating completed conversions without rewriting them; it has no durable scan cursor. Repeated runs help finish interrupted conversion work, but a full verification scan still needs to fit within the time budget. Increase the bounded budget for a large database; if even 120 minutes is insufficient, plan a larger-database migration rather than assuming retries advance a saved cursor. Constraint validation can also time out on a large table: rerun during a quieter window and investigate persistent contention rather than disabling checks.

After the first encrypted write, rollback is limited to binaries that understand this format. After constraints are installed, disabling encrypted writes causes writes to fail. Do not drop the checks or revive old binaries as a rollback shortcut. Restore a verified backup with its matching keys in an isolated environment if recovery requires it.

Updates remove logical plaintext columns; they do not erase earlier bytes in WAL, replicas, dead tuples, snapshots or backups. Protect those copies with storage encryption, access restrictions and the deployment's retention policy. Do not claim historical plaintext has disappeared merely because the command completed.

## Diagnostics and processing files

`Log.traceContent` permits content only in `NODE_ENV=development` with a logger explicitly set to `LogLevel.TRACE`. It writes locally and never sends to Sentry. Production builds compile the production environment setting; ordinary log redaction remains enabled. Do not enable content traces on a host processing real user traffic.

Uploads may temporarily need readable files while hashing, resizing, transcoding or publishing. The affected staging paths create owner-only files; the host must still provide encrypted scratch storage and appropriate capacity. A temporary directory is not inherently encrypted. This change does not put large uploads into an unbounded RAM filesystem.

Compatibility GET routes are retained. Text placed in a URL can appear in reverse-proxy access logs or browser history even when database storage is encrypted. Keep query values out of proxy logs, prefer POST in new callers, and migrate old callers before retiring those routes. Provider encryption, host disk encryption, proxy settings, real-device notification navigation and backup restoration require deployment verification; source tests cannot prove them.
