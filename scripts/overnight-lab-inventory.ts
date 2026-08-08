import { readdir, readFile } from "node:fs/promises";
import { join, relative } from "node:path";

type ContextRecord = {
  path: string;
  title: string;
  lines: number;
  kind: string;
  topic: string;
  signal: string;
};

type WorktreeRecord = {
  path: string;
  head: string;
  branch: string;
  changedEntries: number;
};

const root = process.cwd();
const contextRoot = join(root, ".context");

async function markdownFiles(directory: string): Promise<string[]> {
  const entries = await readdir(directory, { withFileTypes: true });
  const nested = await Promise.all(entries.map(async (entry) => {
    const path = join(directory, entry.name);
    if (entry.isDirectory()) {
      if (relative(contextRoot, path).split("/")[0] === "overnight-lab") return [];
      return markdownFiles(path);
    }
    return entry.isFile() && entry.name.endsWith(".md") ? [path] : [];
  }));
  return nested.flat();
}

function firstHeading(content: string, fallback: string): string {
  return content.match(/^#\s+(.+)$/m)?.[1]?.trim() ?? fallback;
}

function classifyKind(path: string, title: string): string {
  const value = `${path} ${title}`.toLowerCase();
  if (value.includes("ground-truth")) return "ground truth";
  if (/(work.?log|checklist|decision-index)/.test(value)) return "worklog/checklist";
  if (/(investigation|audit|review|research|findings)/.test(value)) return "investigation/audit";
  if (/(spec|plan|blueprint|contract|proposal|architecture)/.test(value)) return "spec/plan";
  if (value.includes("changelog")) return "changelog";
  return "other context";
}

const topics: Array<[RegExp, string]> = [
  [/effect|server|postgres|database|migration/, "server/data/effect"],
  [/realtime|sync|websocket|sequence|cursor/, "realtime/sync"],
  [/bot|agent|cli|openclaw|hermes|claude|codex/, "bots/agents/cli"],
  [/grid|livekit|voice|audio|transcri/, "grid/media"],
  [/release|testflight|app.?store|sparkle|dmg|ship/, "release/operations"],
  [/security|privacy|auth|oauth|login|signup|encrypt|e2ee/, "security/identity"],
  [/thumbnail|document|attachment|upload|preview|photo|video/, "files/media/previews"],
  [/sidebar|navigation|home|inbox|all.?chats|command.?bar/, "navigation/discovery"],
  [/compose|message|draft|reaction|thread|reply/, "messaging/composer"],
  [/ios|iphone|ipad|uikit/, "iOS"],
  [/macos|appkit|sparkle/, "macOS"],
  [/android|expo|mobile/, "Android/mobile"],
  [/landing|web|desktop|windows/, "web/desktop"],
  [/fundrais|agreement|safe|investment/, "company/fundraising"],
];

function classifyTopic(path: string, title: string): string {
  const value = `${path} ${title}`.toLowerCase();
  return topics.find(([pattern]) => pattern.test(value))?.[1] ?? "other";
}

function statusSignal(content: string): string {
  const value = content.toLowerCase();
  if (/result:\s*(implemented|finalized)|status:\s*(complete|completed)|integration_accepted/.test(value)) return "claims implemented/finalized";
  if (/implementation started|status:\s*in[_ -]?progress|remaining gates|unfinished|partial/.test(value)) return "claims in progress/partial";
  if (/documentation-only|no product code|no implementation|proposal only|proposed architecture/.test(value)) return "proposal/investigation only";
  if (/blocked|release blocker|stop condition/.test(value)) return "contains blocker signal";
  return "status not explicit";
}

async function loadContexts(): Promise<ContextRecord[]> {
  const files = (await markdownFiles(contextRoot)).sort();
  return Promise.all(files.map(async (file) => {
    const content = await readFile(file, "utf8");
    const path = relative(root, file);
    const title = firstHeading(content, path.split("/").at(-1) ?? path);
    return {
      path,
      title,
      lines: content.split(/\r?\n/).length,
      kind: classifyKind(path, title),
      topic: classifyTopic(path, title),
      signal: statusSignal(content),
    };
  }));
}

async function loadWip(): Promise<string[]> {
  const content = await readFile(join(root, ".wip"), "utf8");
  return content.split(/\r?\n/).flatMap((line) => {
    const match = line.match(/^-\s+(.+)/);
    return match ? [match[1].trim()] : [];
  });
}

function command(args: string[], cwd = root): string {
  const result = Bun.spawnSync(args, { cwd, stdout: "pipe", stderr: "pipe" });
  return result.exitCode === 0 ? result.stdout.toString() : "";
}

function loadWorktrees(): WorktreeRecord[] {
  const porcelain = command(["git", "worktree", "list", "--porcelain"]);
  const blocks = porcelain.trim().split(/\n\n+/).filter(Boolean);
  return blocks.map((block) => {
    const values = new Map(block.split("\n").map((line) => {
      const separator = line.indexOf(" ");
      return separator < 0 ? [line, ""] : [line.slice(0, separator), line.slice(separator + 1)];
    }));
    const path = values.get("worktree") ?? "unknown";
    const status = path === "unknown" ? "" : command(["git", "status", "--porcelain=v1"], path);
    return {
      path,
      head: values.get("HEAD") ?? "unknown",
      branch: (values.get("branch") ?? "detached").replace("refs/heads/", ""),
      changedEntries: status.split(/\r?\n/).filter(Boolean).length,
    };
  });
}

function countBy(records: ContextRecord[], key: "kind" | "topic" | "signal"): Record<string, number> {
  return Object.fromEntries([...new Set(records.map((record) => record[key]))]
    .sort()
    .map((value) => [value, records.filter((record) => record[key] === value).length]));
}

const contexts = await loadContexts();
const wip = await loadWip();
const worktrees = loadWorktrees();
const commit = command(["git", "rev-parse", "HEAD"]).trim();
const generatedAt = new Date().toISOString();

const inventory = {
  generatedAt,
  commit,
  totals: { contextMarkdown: contexts.length, wipTopLevelEntries: wip.length, worktrees: worktrees.length },
  counts: { byKind: countBy(contexts, "kind"), byTopic: countBy(contexts, "topic"), bySignal: countBy(contexts, "signal") },
  contexts,
  wip,
  worktrees,
};

const lines = [
  "# Exhaustive WIP and Context Inventory",
  "",
  `Generated: ${generatedAt}. Source commit: \`${commit}\`.`,
  "",
  "> Status values are document signals, not current truth. Reconcile selected items with source, tests, live artifacts, and newer ground truth before transfer.",
  "",
  `- Context Markdown files: ${contexts.length}`,
  `- Top-level .wip entries: ${wip.length}`,
  `- Local worktrees: ${worktrees.length}`,
  "",
  "## Counts by topic",
  "",
  ...Object.entries(inventory.counts.byTopic).map(([name, count]) => `- ${name}: ${count}`),
  "",
  "## Local worktrees",
  "",
  "| Path | Branch | HEAD | Changed entries |",
  "|---|---|---:|---:|",
  ...worktrees.map((item) => `| \`${item.path}\` | \`${item.branch}\` | \`${item.head.slice(0, 12)}\` | ${item.changedEntries} |`),
  "",
  "## Top-level .wip entries",
  "",
  ...wip.map((item, index) => `${index + 1}. ${item}`),
  "",
  "## Every context document",
  "",
  "| Path | Title | Kind | Topic | Document signal | Lines |",
  "|---|---|---|---|---|---:|",
  ...contexts.map((item) => `| \`${item.path}\` | ${item.title.replaceAll("|", "\\|")} | ${item.kind} | ${item.topic} | ${item.signal} | ${item.lines} |`),
  "",
];

await Bun.write(join(root, ".context/overnight-lab/01-inventory.json"), `${JSON.stringify(inventory, null, 2)}\n`);
await Bun.write(join(root, ".context/overnight-lab/01-inventory.md"), `${lines.join("\n")}\n`);

console.log(JSON.stringify(inventory.totals));
