// Packaged operational entry point. Never log connection strings, keys, row data or raw errors.
import postgres from "postgres"
import { sql } from "drizzle-orm"
import { assertContentEncryptionConfigured, contentEncryptionWritesEnabled } from "../src/modules/encryption/contentEncryption"

class BackfillCommandError extends Error {}
let phase = "arguments"

export function parseContentBackfillOptions(args: readonly string[]) {
  const booleans = new Set(["--apply", "--backup-verified", "--readers-ready"])
  const values = new Set(["--database", "--batch-size", "--max-minutes"])
  const parsed = new Map<string, string>()
  for (let i = 0; i < args.length; i++) {
    const flag = args[i]!
    if (parsed.has(flag) || (!booleans.has(flag) && !values.has(flag))) throw new BackfillCommandError("Invalid backfill arguments")
    if (booleans.has(flag)) parsed.set(flag, "true")
    else {
      const value = args[++i]
      if (!value || value.startsWith("--")) throw new BackfillCommandError("Missing argument value")
      parsed.set(flag, value)
    }
  }
  const batchSize = Number(parsed.get("--batch-size") ?? 100)
  const maxMinutes = Number(parsed.get("--max-minutes") ?? 20)
  if (!Number.isSafeInteger(batchSize) || batchSize < 1 || batchSize > 500 ||
      !Number.isSafeInteger(maxMinutes) || maxMinutes < 1 || maxMinutes > 120 || !parsed.get("--database")) {
    throw new BackfillCommandError("Invalid backfill bounds or target")
  }
  const apply = parsed.has("--apply")
  if (apply && (!parsed.has("--backup-verified") || !parsed.has("--readers-ready"))) {
    throw new BackfillCommandError("Backup and compatible-reader acknowledgements are required")
  }
  return { apply, database: parsed.get("--database")!, batchSize, maxMinutes }
}

async function main() {
  const options = parseContentBackfillOptions(Bun.argv.slice(2))
  phase = "configuration"
  const target = process.env["DATABASE_URL"]
  if (!target || decodeURIComponent(new URL(target).pathname.slice(1)) !== options.database) {
    throw new BackfillCommandError("Database confirmation does not match")
  }
  assertContentEncryptionConfigured()
  if (options.apply && !contentEncryptionWritesEnabled()) throw new BackfillCommandError("Enable encrypted writers before migration")

  // One dedicated connection owns the session lock, independent of the application's query pool.
  const coordinator = postgres(target, { max: 1, connect_timeout: 5, idle_timeout: 0 })
  let closeDb: (() => Promise<void>) | undefined
  let stopped = false
  const onStop = () => { stopped = true }
  process.on("SIGTERM", onStop)
  process.on("SIGINT", onStop)
  const deadline = Date.now() + options.maxMinutes * 60_000
  const assertRunning = () => {
    if (stopped || Date.now() >= deadline) throw new BackfillCommandError("Backfill interrupted; rerun to resume")
  }
  try {
    phase = "coordination"
    const [lock] = await coordinator<{ acquired: boolean }[]>`
      select pg_try_advisory_lock(hashtextextended('inline-content-backfill-v1', 0)) as acquired
    `
    if (!lock?.acquired) throw new BackfillCommandError("Another content backfill is running")
    phase = "database initialization"
    const database = await import("../src/db")
    closeDb = database.closeDb
    const [actual] = await database.db.execute<{ name: string }>(sql`select current_database() as name`)
    if (actual?.name !== options.database) throw new BackfillCommandError("Application database does not match target")
    phase = "preflight"
    const { contentTables, backfillContentBatch, remainingPlaintext, constrainEncryptedContent } =
      await import("./helpers/content-backfill")
    const { backfillMessageTextBatch } = await import("./helpers/backfill-message-text")
    const initial = await remainingPlaintext()

    // Require encrypted replay writers too, so completion checks cannot break later requests.
    const replayRing = process.env["INLINE_PROTOCOL_REPLAY_KEY_RING_JSON"]
    const replayEnabled = process.env["INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS"] === "true"
    if (options.apply && (!replayRing || !replayEnabled)) {
      throw new BackfillCommandError("Replay encryption rollout is required")
    }
    const { decodeInlineProtocolSecretKeyRing } = await import("../src/modules/inlineProtocol/keyCipher")
    const { makeReplayResultCipher } = await import("../src/modules/inlineProtocol/replayCipher")
    const { InlineProtocolReplayRepository } = await import("../src/db/models/inlineProtocol")
    const replay = replayRing ? new InlineProtocolReplayRepository({
      cipher: makeReplayResultCipher(decodeInlineProtocolSecretKeyRing(replayRing, "replay")), encryptWrites: replayEnabled,
    }) : undefined

    console.info(JSON.stringify({ mode: options.apply ? "apply" : "verify", remaining: initial }))
    phase = "messages"
    let afterMessage = 0n
    while (true) {
      assertRunning()
      const batch = await backfillMessageTextBatch({ apply: options.apply, afterId: afterMessage, batchSize: options.batchSize })
      console.info(JSON.stringify({ table: "messages", scanned: batch.scanned, changed: batch.migrated, conflicts: batch.conflicts }))
      if (batch.conflicts > 0) throw new BackfillCommandError("Conflicting message representations")
      if (batch.done) break
      afterMessage = BigInt(batch.lastId)
      await Bun.sleep(25)
    }
    for (const table of contentTables) {
      phase = table.name
      let afterId: string | undefined
      while (true) {
        assertRunning()
        const batch = await backfillContentBatch({ table, apply: options.apply, afterId, batchSize: options.batchSize })
        console.info(JSON.stringify({ table: table.name, scanned: batch.scanned, changed: batch.changed }))
        if (batch.done) break
        afterId = batch.lastId
        await Bun.sleep(25)
      }
    }
    if (options.apply && replay && replayEnabled) {
      phase = "replay"
      while (true) {
        assertRunning()
        const changed = await replay.encryptCompletedBatch(Math.min(10, options.batchSize))
        console.info(JSON.stringify({ table: "replay", changed }))
        if (changed === 0) break
        await Bun.sleep(25)
      }
    }
    phase = "completion checks"
    const remaining = await remainingPlaintext()
    if (options.apply) {
      if (Object.values(remaining).some((count) => count !== 0)) throw new BackfillCommandError("Remaining plaintext; rerun after checking writers")
      assertRunning()
      await constrainEncryptedContent()
    }
    console.info(JSON.stringify({ status: options.apply ? "complete" : "verified", remaining }))
  } finally {
    process.off("SIGTERM", onStop)
    process.off("SIGINT", onStop)
    try { await closeDb?.() } finally { await coordinator.end({ timeout: 5 }) }
  }
}

if (import.meta.main) await main().catch((error: unknown) => {
  console.error(JSON.stringify({ status: "stopped", phase, reason: error instanceof BackfillCommandError
    ? error.message : "Data verification, encryption configuration or database operation failed" }))
  console.error("Content backfill stopped safely. Check target, acknowledgements, keys, compatible writers, conflicts and database health. Rerun the same command after resolving the cause; committed batches are preserved. No row/error payload printed.")
  process.exitCode = 1
})
