// Packaged operational entry point for data tasks (server/docs/data-tasks.md).
// The worker process applies pending tasks on its own; this inspects them,
// runs the same pass once (CI and local development), or reverts in an emergency.
// Never logs connection strings, row data or raw errors: tasks report IDs only.

const usage = `Usage: bun server/dist/data-task.js <command> [task] [options]

  list                    Tasks this image knows, and whether each completed
  plan <task> [--items]   Dry run: plan hash, tier counts and whether its limits pass
  status <task>           Ledger counts and the latest run
  run                     Apply pending tasks once, exactly as the worker does
  revert <task> --database <name> --backup-verified [--key <key>]...
                          Emergency: undo applied items (all, or the given keys)`

class CommandError extends Error {}

type Options = {
  command: "list" | "plan" | "status" | "run" | "revert"
  taskId?: string
  items: boolean
  database?: string
  backupVerified: boolean
  keys: string[]
}

export function parseDataTaskArgs(args: readonly string[]): Options {
  const [command, ...rest] = args
  if (command !== "list" && command !== "plan" && command !== "status" && command !== "run" && command !== "revert") {
    throw new CommandError("Unknown command")
  }
  const options: Options = { command, items: false, backupVerified: false, keys: [] }
  if (command === "plan" || command === "status" || command === "revert") {
    const taskId = rest.shift()
    if (!taskId || taskId.startsWith("--")) throw new CommandError("Missing task ID")
    options.taskId = taskId
  }
  const allowed: Record<Options["command"], readonly string[]> = {
    list: [],
    plan: ["--items"],
    status: [],
    run: [],
    revert: ["--database", "--backup-verified", "--key"],
  }
  const seen = new Set<string>()
  for (let index = 0; index < rest.length; index++) {
    const flag = rest[index]!
    if (!allowed[command].includes(flag) || (flag !== "--key" && seen.has(flag))) throw new CommandError(`Unexpected argument ${flag}`)
    seen.add(flag)
    if (flag === "--items") { options.items = true; continue }
    if (flag === "--backup-verified") { options.backupVerified = true; continue }
    const value = rest[++index]
    if (!value || value.startsWith("--")) throw new CommandError(`Missing value for ${flag}`)
    if (flag === "--database") options.database = value
    else if (flag === "--key") options.keys.push(value)
  }
  if (command === "revert") {
    if (!options.database) throw new CommandError("Revert needs --database with the target database's exact name")
    if (!options.backupVerified) throw new CommandError("Revert needs --backup-verified: confirm a restorable backup first")
  }
  return options
}

/** The target must be named on the command line, so a wrong DATABASE_URL can't be written to by accident. */
function assertTargetDatabase(expected: string): void {
  const target = process.env["DATABASE_URL"]
  if (!target || decodeURIComponent(new URL(target).pathname.slice(1)) !== expected) {
    throw new CommandError("--database does not match the configured database")
  }
}

const line = (value: unknown) => console.info(JSON.stringify(value))

export async function main(args: readonly string[] = Bun.argv.slice(2)): Promise<number> {
  if (args.length === 0 || args.includes("--help")) {
    console.info(usage)
    return args.length === 0 ? 2 : 0
  }
  let closeDb: (() => Promise<void>) | undefined
  try {
    const options = parseDataTaskArgs(args)
    if (options.database) assertTargetDatabase(options.database)
    const { dataTasks, findDataTask } = await import("../src/modules/dataTasks/registry")
    const task = options.taskId === undefined ? undefined : findDataTask(options.taskId)
    if (options.taskId !== undefined && !task) throw new CommandError("Unknown task ID; run `list`")

    const database = await import("../src/db")
    closeDb = database.closeDb
    const runner = await import("../src/modules/dataTasks/runner")

    switch (options.command) {
      case "list":
        for (const known of dataTasks) {
          const status = await runner.dataTaskStatus(known.id)
          line({ id: known.id, description: known.description, completed: status.completed, lastRun: status.lastRun?.status ?? null })
        }
        return 0
      case "plan": {
        const plan = await runner.planDataTask(task!)
        const violation = runner.planViolation(task!, plan) ?? null
        line({ task: task!.id, mode: "dry-run", hash: plan.hash, items: plan.items.length, tiers: plan.tiers, limits: task!.limits, violation })
        if (options.items) for (const item of plan.items) line({ key: item.key, tier: item.tier, noop: item.noop === true, plan: item.plan })
        return violation ? 3 : 0
      }
      case "status":
        line({ task: task!.id, ...(await runner.dataTaskStatus(task!.id)) })
        return 0
      case "run": {
        const { runPendingDataTasks } = await import("../src/modules/dataTasks/automatic")
        const reports = await runPendingDataTasks({ sourceCommit: process.env["SOURCE_COMMIT"] })
        for (const report of reports) line(report)
        return reports.every((report) => report.status === "completed" || report.status === "already-completed") ? 0 : 3
      }
      case "revert": {
        const summary = await runner.revertDataTask(task!, { keys: options.keys.length > 0 ? options.keys : undefined })
        line({ task: task!.id, mode: "revert", ...summary })
        return summary.skipped.length > 0 ? 3 : 0
      }
    }
    throw new CommandError("Unknown command")
  } catch (error) {
    if (error instanceof CommandError) {
      console.error(error.message)
      console.error(usage)
      return 2
    }
    const { DataTaskError } = await import("../src/modules/dataTasks/runner")
    if (error instanceof DataTaskError) {
      console.error(error.message)
      return 2
    }
    // Database errors may carry SQL or credentials.
    console.error("Data task command stopped. Check the target, `status` and database health. No error payload printed.")
    return 1
  } finally {
    await closeDb?.()
  }
}

if (import.meta.main) process.exitCode = await main()
