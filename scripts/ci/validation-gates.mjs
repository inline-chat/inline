import { execFileSync } from "node:child_process"
import { appendFileSync, readFileSync } from "node:fs"
import { pathToFileURL } from "node:url"

export const validationJobs = {
  apple: ["contracts", "swift-main", "swift-utilities", "macos-app", "ios-app"],
  integrations: ["landing", "codex-plugin", "mcp", "openclaw", "openclaw-source", "hermes", "chat-sdk", "shared-packages", "rust-workspace", "workflow-and-release-contracts", "candidate-packages", "packed-consumers", "openclaw-admission", "hermes-admission", "local-integration"],
  server: ["container", "container-arm", "test"],
}

// Only known unrelated paths may skip Apple validation. Unknown inputs fail open
// to the full suite; main and manual runs always qualify every Apple lane.
export function selectAppleJobs(eventName, paths) {
  if (eventName !== "pull_request" || !paths?.length) return validationJobs.apple
  // Swift secure-transport tests consume canonical trust roots from this package.
  if (paths.some((file) => file.startsWith("packages/protocol/"))) return validationJobs.apple
  const unrelated = /^(server\/|landing\/|packages\/|plugins\/|cli\/|crates\/|vendor\/|skills\/|docs\/|admin\/|\.cargo\/|\.codex\/|\.agents\/|Cargo\.(toml|lock)$|rust-toolchain\.toml$|[^/]+\.md$)/
  return paths.every((file) => unrelated.test(file)) ? [] : validationJobs.apple
}

export function checkResults(kind, needs, selected = validationJobs[kind]) {
  const jobs = validationJobs[kind]
  if (!jobs) throw new Error(`unknown validation workflow: ${kind}`)
  if (!Array.isArray(selected) || new Set(selected).size !== selected.length || selected.some((job) => !jobs.includes(job))) {
    throw new Error("invalid selected job inventory")
  }
  const expected = kind === "apple" ? ["changes", ...jobs] : jobs
  if (JSON.stringify(Object.keys(needs).sort()) !== JSON.stringify([...expected].sort())) throw new Error("validation dependency inventory differs from policy")
  for (const job of expected) {
    const result = needs[job]?.result
    const intentionalSkip = kind === "apple" && job !== "changes" && !selected.includes(job)
    if (result !== "success" && !(intentionalSkip && result === "skipped")) throw new Error(`${job}: ${result ?? "missing result"}`)
  }
}

if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) {
  if (process.argv[2] === "select-apple") {
    let paths
    try {
      const event = JSON.parse(readFileSync(process.env.GITHUB_EVENT_PATH, "utf8"))
      const { base, head } = event.pull_request ?? {}
      if (/^[a-f0-9]{40}$/.test(base?.sha) && /^[a-f0-9]{40}$/.test(head?.sha)) {
        paths = execFileSync("git", ["diff", "--name-only", "-z", "--no-renames", `${base.sha}...${head.sha}`], { encoding: "utf8" }).split("\0").filter(Boolean)
      }
    } catch {
      console.log("Diff unavailable; selecting all Apple jobs")
    }
    const selected = selectAppleJobs(process.env.GITHUB_EVENT_NAME, paths)
    appendFileSync(process.env.GITHUB_OUTPUT, `selected=${JSON.stringify(selected)}\nrun=${selected.length > 0}\n`)
    const summary = `Apple validation: ${selected.length ? "all five lanes selected" : "known unrelated PR paths; five lanes skipped"}. Changed paths: ${paths?.length ?? "unavailable"}.\n`
    console.log(summary)
    if (process.env.GITHUB_STEP_SUMMARY) appendFileSync(process.env.GITHUB_STEP_SUMMARY, summary)
  } else {
    const kind = process.argv[2]
    const selected = process.env.SELECTED_JOBS === undefined ? validationJobs[kind] : JSON.parse(process.env.SELECTED_JOBS)
    checkResults(kind, JSON.parse(process.env.RESULTS_JSON ?? "{}"), selected)
    console.log(`${kind}: every selected validation job passed`)
  }
}
