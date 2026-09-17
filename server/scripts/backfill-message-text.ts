// Defaults to verification only. Deliberately never logs the connection string, row data or raw errors.
const args = Bun.argv.slice(2)
const value = (flag: string) => {
  const index = args.indexOf(flag)
  return index === -1 ? undefined : args[index + 1]
}

async function main() {
  const allowed = new Set(["--apply", "--backup-verified", "--database", "--after-id", "--batch-size", "--max-batches"])
  for (let i = 0; i < args.length; i++) {
    const arg = args[i]!
    if (!allowed.has(arg)) throw new Error("Invalid arguments")
    if (!["--apply", "--backup-verified"].includes(arg)) i++
  }
  const target = process.env["DATABASE_URL"]
  const database = value("--database")
  if (!target || !database || decodeURIComponent(new URL(target).pathname.slice(1)) !== database) {
    throw new Error("An exact database-name confirmation is required")
  }
  const apply = args.includes("--apply")
  if (apply && !args.includes("--backup-verified")) throw new Error("Verify backup restoration and keys before applying")
  const maxBatches = Number(value("--max-batches") ?? 1)
  const batchSize = Number(value("--batch-size") ?? 100)
  let afterId = BigInt(value("--after-id") ?? "0")
  if (!Number.isSafeInteger(maxBatches) || maxBatches < 1 || maxBatches > 100) throw new Error("Invalid batch count")
  const { closeDb } = await import("../src/db")
  try {
    const { assertEncryptionConfigured } = await import("../src/modules/encryption/encryption")
    assertEncryptionConfigured()
    const { backfillMessageTextBatch } = await import("./helpers/backfill-message-text")
    for (let batch = 0; batch < maxBatches; batch++) {
      const summary = await backfillMessageTextBatch({ apply, afterId, batchSize })
      console.log(JSON.stringify({ mode: apply ? "apply" : "verify", ...summary }))
      afterId = BigInt(summary.lastId)
      if (summary.conflicts > 0) { process.exitCode = 2; break }
      if (summary.done) break
    }
  } finally {
    await closeDb()
  }
}

await main().catch(() => {
  console.error("Backfill stopped. Check arguments, target, key availability and database health. No error payload printed.")
  process.exitCode = 1
})
