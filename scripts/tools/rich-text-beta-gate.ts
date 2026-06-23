import { dirname, resolve } from "node:path"
import { fileURLToPath } from "node:url"

type Step = {
  name: string
  cwd: string
  cmd: string[]
}

export type BetaGateOptions = {
  help: boolean
  errors: string[]
  liveLogPaths: string[]
  requireMediaUpload: boolean
  requireOpenClawSignals: boolean
}

type StepResult = {
  name: string
  ok: boolean
  output: string
}

const scriptDir = dirname(fileURLToPath(import.meta.url))
const scriptsDir = resolve(scriptDir, "..")
const rootDir = resolve(scriptsDir, "..")
const richApiTypecheckSteps: Step[] = [
  {
    name: "server typecheck",
    cwd: resolve(rootDir, "server"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "markdown package typecheck",
    cwd: resolve(rootDir, "packages/markdown"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "protocol package typecheck",
    cwd: resolve(rootDir, "packages/protocol"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "SDK package typecheck",
    cwd: resolve(rootDir, "packages/sdk"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "Bot API types package typecheck",
    cwd: resolve(rootDir, "packages/bot-api-types"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "Bot API package typecheck",
    cwd: resolve(rootDir, "packages/bot-api"),
    cmd: ["bun", "run", "typecheck"],
  },
  {
    name: "OpenClaw package typecheck",
    cwd: resolve(rootDir, "packages/openclaw"),
    cmd: ["bun", "run", "typecheck"],
  },
]

export function parseBetaGateArgs(args: string[]): BetaGateOptions {
  const options: BetaGateOptions = {
    help: false,
    errors: [],
    liveLogPaths: [],
    requireMediaUpload: false,
    requireOpenClawSignals: false,
  }

  for (let index = 0; index < args.length; index += 1) {
    const arg = args[index]
    switch (arg) {
      case "--help":
      case "-h":
        options.help = true
        break
      case "--live-log": {
        const path = args[index + 1]
        if (!path || path.startsWith("--")) {
          options.errors.push("--live-log requires a path")
          break
        }
        appendUniqueLiveLogPath(options.liveLogPaths, path)
        index += 1
        break
      }
      case "--openclaw-live-log": {
        const path = args[index + 1]
        if (!path || path.startsWith("--")) {
          options.errors.push("--openclaw-live-log requires a path")
          break
        }
        appendUniqueLiveLogPath(options.liveLogPaths, path)
        options.requireOpenClawSignals = true
        index += 1
        break
      }
      case "--require-openclaw-signals":
        options.requireOpenClawSignals = true
        break
      case "--require-media-upload":
        options.requireMediaUpload = true
        break
      default:
        options.errors.push(`unknown argument: ${arg}`)
        break
    }
  }

  if (options.requireMediaUpload && options.liveLogPaths.length === 0) {
    options.errors.push("--require-media-upload requires at least one --live-log or --openclaw-live-log")
  }

  return options
}

function appendUniqueLiveLogPath(paths: string[], path: string): void {
  if (!paths.includes(path)) {
    paths.push(path)
  }
}

export function buildSteps(options: BetaGateOptions): Step[] {
  const steps: Step[] = [
    {
      name: "scripts test",
      cwd: scriptsDir,
      cmd: ["bun", "run", "test"],
    },
    {
      name: "scripts typecheck",
      cwd: scriptsDir,
      cmd: ["bun", "run", "typecheck"],
    },
    {
      name: "scripts lint",
      cwd: scriptsDir,
      cmd: ["bun", "run", "lint"],
    },
    ...richApiTypecheckSteps,
    {
      name: "macOS rich text testbook preflight",
      cwd: rootDir,
      cmd: ["scripts/macos/open-debug-app.sh", "--no-build", "--no-stop", "--rich-text-testbook-preflight"],
    },
  ]

  if (options.liveLogPaths.length > 0) {
    steps.push({
      name: "strict rich text live log check",
      cwd: scriptsDir,
      cmd: [
        "bun",
        "run",
        "rich-text:check-live-log",
        "--strict-signals",
        "--strict-media",
        ...(options.requireMediaUpload ? ["--require-media-upload"] : []),
        ...(options.requireOpenClawSignals ? ["--require-openclaw-signals"] : []),
        ...options.liveLogPaths,
      ],
    })
  }

  return steps
}

async function main(args: string[]): Promise<number> {
  const options = parseBetaGateArgs(args)
  if (options.help) {
    printUsage()
    return 0
  }
  if (options.errors.length > 0) {
    for (const error of options.errors) {
      console.error(error)
    }
    printUsage()
    return 2
  }

  const results: StepResult[] = []
  for (const step of buildSteps(options)) {
    const result = await runStep(step)
    results.push(result)
    if (!result.ok) {
      printSummary(results, options)
      return 1
    }
  }

  printSummary(results, options)
  return 0
}

async function runStep(step: Step): Promise<StepResult> {
  console.log(`\n### ${step.name}`)
  console.log(`$ ${step.cmd.map(shellQuote).join(" ")}`)

  const proc = Bun.spawn(step.cmd, {
    cwd: step.cwd,
    stdout: "pipe",
    stderr: "pipe",
  })
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ])
  const output = `${stdout}${stderr}`
  if (output.trim()) {
    console.log(output.trimEnd())
  }

  return {
    name: step.name,
    ok: exitCode === 0,
    output,
  }
}

function printSummary(results: StepResult[], options: BetaGateOptions): void {
  const failed = results.filter((result) => !result.ok)
  console.log("\n### Rich text beta automated gate")
  for (const result of results) {
    console.log(`- ${result.ok ? "pass" : "fail"}: ${result.name}`)
  }

  const preflight = results.find((result) => result.name === "macOS rich text testbook preflight")
  const report = preflight ? extractLineValue(preflight.output, "Report") : undefined
  const snapshot = preflight ? extractLineValue(preflight.output, "Snapshot") : undefined
  if (report) console.log(`- report: ${report}`)
  if (snapshot) console.log(`- snapshot: ${snapshot}`)
  if (options.liveLogPaths.length > 0) {
    console.log(`- live logs: ${options.liveLogPaths.join(", ")}`)
    const modes = [
      "strict signals",
      "strict media",
      ...(options.requireMediaUpload ? ["media upload required"] : []),
      ...(options.requireOpenClawSignals ? ["OpenClaw required"] : []),
    ]
    console.log(`- live log mode: ${modes.join(", ")}`)
  } else {
    console.log("- live logs: not supplied")
  }

  if (failed.length === 0) {
    const liveTail = options.liveLogPaths.length > 0
      ? "Manual active-window and human live UI review still remain."
      : "Manual active-window and live ChatGPT/OpenClaw review still remain."
    console.log(`\nAutomated rich text beta gate passed, including rich API/server/package type boundaries. ${liveTail}`)
  } else {
    console.log("\nAutomated rich text beta gate failed. Fix the failing step before manual/live beta sign-off.")
  }
}

function extractLineValue(text: string, label: string): string | undefined {
  const prefix = `${label}: `
  return text
    .split(/\r?\n/)
    .find((line) => line.startsWith(prefix))
    ?.slice(prefix.length)
}

function shellQuote(value: string): string {
  if (/^[A-Za-z0-9_./:=@+-]+$/.test(value)) return value
  return JSON.stringify(value)
}

function printUsage(): void {
  console.log(
    [
      "usage: bun run tools/rich-text-beta-gate.ts [--live-log <path> ...] [--openclaw-live-log <path> ...] [--require-media-upload] [--require-openclaw-signals]",
      "",
      "Runs scripts test/typecheck/lint, rich API/server/package typechecks, and the macOS rich text testbook preflight.",
      "When live logs are supplied, also runs the strict live log checker with --strict-signals and --strict-media.",
      "--require-media-upload makes the live log step fail unless rich media resolution succeeded and at least one file upload completed.",
      "--openclaw-live-log also enables --require-openclaw-signals.",
    ].join("\n"),
  )
}

if (import.meta.main) {
  const code = await main(process.argv.slice(2))
  process.exit(code)
}
