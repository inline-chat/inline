// Opt-in bounded backfill. Never print connection strings, row data, keys or raw driver errors.
async function main() {
  const args = Bun.argv.slice(2)
  const flags = new Map<string, string>()
  for (let i = 0; i < args.length; i += 2) {
    const name = args[i]!
    const value = args[i + 1]
    if (!["--database", "--batch-size", "--max-batches", "--compatible-readers", "--backup-verified"].includes(name) ||
        value === undefined || flags.has(name)) throw new Error("Invalid arguments")
    flags.set(name, value)
  }
  const target = process.env["DATABASE_URL"]
  if (!target || !flags.get("--database") || decodeURIComponent(new URL(target).pathname.slice(1)) !== flags.get("--database") ||
      flags.get("--compatible-readers") !== "true" || flags.get("--backup-verified") !== "true" ||
      process.env["INLINE_PROTOCOL_ENCRYPT_REPLAY_RESULTS"] !== "true") throw new Error("Rollout prerequisites required")
  const limit = Number(flags.get("--batch-size") ?? 10)
  const maxBatches = Number(flags.get("--max-batches") ?? 1)
  if (!Number.isSafeInteger(limit) || limit < 1 || limit > 100 ||
      !Number.isSafeInteger(maxBatches) || maxBatches < 1 || maxBatches > 100) throw new Error("Invalid bounds")
  const { decodeInlineProtocolSecretKeyRing } = await import("../src/modules/inlineProtocol/keyCipher")
  const { makeReplayResultCipher } = await import("../src/modules/inlineProtocol/replayCipher")
  const cipher = makeReplayResultCipher(decodeInlineProtocolSecretKeyRing(
    process.env["INLINE_PROTOCOL_REPLAY_KEY_RING_JSON"] ?? "", "replay",
  ))
  const { closeDb } = await import("../src/db")
  try {
    const { InlineProtocolReplayRepository } = await import("../src/db/models/inlineProtocol")
    const repository = new InlineProtocolReplayRepository({ cipher, encryptWrites: true })
    for (let batch = 0; batch < maxBatches; batch++) {
      const encrypted = await repository.encryptCompletedBatch(limit)
      console.log(JSON.stringify({ batch: batch + 1, encrypted }))
      // Other workers can hold skipped rows. Zero means this pass found no unlocked work.
      if (encrypted === 0) break
    }
  } finally { await closeDb() }
}

await main().catch(() => {
  console.error("Replay migration stopped. Check rollout prerequisites, arguments, keys and database health.")
  process.exitCode = 1
})
