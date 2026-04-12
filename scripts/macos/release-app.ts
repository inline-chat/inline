import { spawnSync } from "bun";
import { mkdirSync, rmSync, writeFileSync, existsSync } from "fs";
import { basename, resolve } from "path";
import { createInterface } from "node:readline";

type TaskStatus = "pending" | "running" | "success" | "failed" | "skipped";

type Task = {
  id: string;
  title: string;
  enabled: boolean;
  skipReason?: string;
  softFail?: boolean;
  dryRun?: (ctx: ReleaseContext, ui: Ui) => Promise<void> | void;
  run: (ctx: ReleaseContext, ui: Ui) => Promise<void> | void;
};

type ReleaseOptions = {
  channel: "stable" | "beta";
  derivedData: string;
  appPath: string;
  dmgPath: string;
  sparkleDir: string;
  releaseTag: string;
  skipGithubRelease: boolean;
  skip: Set<string>;
  fromTask: string;
  dryRun: boolean;
  pauseBeforeNotarize: boolean;
  rollback: boolean;
  rollbackToBuild: string;
  rollbackStepsBack: number;
};

type ParsedArgs = Omit<ReleaseOptions, "channel" | "releaseTag"> & {
  channel?: "stable" | "beta";
  releaseTag?: string;
};

type RollbackMetadata = {
  selectedBuild: string;
  selectedUrl: string;
  removedBuilds: string[];
};

type ReleaseContext = ReleaseOptions & {
  rootDir: string;
  tempDir: string;
  signingKeyPath: string;
  signUpdatePath: string;
  appcastPath: string;
  appcastOutputPath: string;
  rollbackMetaPath: string;
  buildNumber: string;
  version: string;
  commit: string;
  commitLong: string;
  baseUrl: string;
  dmgUrl: string;
  appcastUrl: string;
  rollbackSelectedBuild: string;
  rollbackSelectedUrl: string;
  rollbackRemovedBuilds: string[];
};

function usage(): string {
  return [
    "Usage: bun run macos/release-app.ts [options]",
    "",
    "Options:",
    "  --channel stable|beta            Update channel (default: beta; prompts if omitted in an interactive terminal)",
    "  --derived-data <path>            Xcode derived data (default: <root>/build/InlineMacDirect)",
    "  --app-path <path>                App path (default: <derived-data>/Build/Products/Release/Inline.app)",
    "  --dmg-path <path>                DMG path (default: <root>/build/macos-direct/Inline.dmg)",
    "  --sparkle-dir <path>             Sparkle tools dir (default: <root>/.action/sparkle)",
    "  --release-tag <tag>              Attach DMG to GitHub release/tag (default: beta->tip, stable->empty)",
    "  --skip-github-release            Skip GitHub release/tag steps",
    "  --from <id>                      Resume from a task id without rerunning earlier steps (preflight still runs)",
    "  --skip <ids>                     Skip steps (comma-separated or repeatable)",
    "                                  Known ids: build, upload-sentry-dsyms, post-check, upload-dmg, verify-dmg, gen-appcast, validate-appcast, upload-appcast, github",
    "                                  Aliases: upload (upload-dmg+upload-appcast), appcast (gen+validate+upload)",
    "  --rollback                       Roll back the live appcast to an older build already present in the channel feed",
    "  --rollback-to-build <build>      Target build to restore (default: previous appcast item)",
    "  --rollback-steps-back <n>        Pick the Nth previous appcast item (default: 1)",
    "  --pause-before-notarize          Pause after app/DMG build so you can test locally, then continue notarization",
    "  --dry-run                         Print what would run, without executing the pipeline",
    "  --skip-build                      Alias for --skip build",
    "  -h, --help                       Show help",
    "",
    "Notes:",
    "  - This script intentionally does not auto-load scripts/.env. Export env vars in your shell.",
    "  - Skipped steps stay visible in the TUI as disabled, so you can see the full pipeline at a glance.",
    "  - --rollback only republishes appcast.xml; it does not rebuild or downgrade already-installed builds.",
  ].join("\n");
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv: string[], rootDir: string): ParsedArgs {
  let channel: "stable" | "beta" | undefined;
  let derivedData = resolve(rootDir, "build/InlineMacDirect");
  let appPath = "";
  let dmgPath = resolve(rootDir, "build/macos-direct/Inline.dmg");
  let sparkleDir = resolve(rootDir, ".action/sparkle");
  let releaseTag: string | undefined;
  let skipGithubRelease = false;
  const skip = new Set<string>();
  let fromTask = "";
  let dryRun = false;
  let pauseBeforeNotarize = false;
  let rollback = false;
  let rollbackToBuild = "";
  let rollbackStepsBack = 1;

  const resolveFromRoot = (p: string): string => {
    if (!p) return p;
    return p.startsWith("/") ? resolve(p) : resolve(rootDir, p);
  };

  const eat = (i: number) => argv[i + 1] ?? "";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--channel") {
      const v = eat(i);
      if (v !== "stable" && v !== "beta") die(`Invalid --channel: ${v}`);
      channel = v;
      i++;
      continue;
    }
    if (arg === "--derived-data") {
      derivedData = resolveFromRoot(eat(i));
      i++;
      continue;
    }
    if (arg === "--app-path") {
      appPath = resolveFromRoot(eat(i));
      i++;
      continue;
    }
    if (arg === "--dmg-path") {
      dmgPath = resolveFromRoot(eat(i));
      i++;
      continue;
    }
    if (arg === "--sparkle-dir") {
      sparkleDir = resolveFromRoot(eat(i));
      i++;
      continue;
    }
    if (arg === "--release-tag") {
      releaseTag = eat(i);
      i++;
      continue;
    }
    if (arg === "--skip-github-release") {
      skipGithubRelease = true;
      continue;
    }
    if (arg === "--from") {
      fromTask = eat(i).trim();
      if (!fromTask) die(`Missing value for ${arg}`);
      i++;
      continue;
    }
    if (arg === "--rollback") {
      rollback = true;
      continue;
    }
    if (arg === "--rollback-to-build") {
      rollbackToBuild = eat(i).trim();
      if (!rollbackToBuild) die(`Missing value for ${arg}`);
      i++;
      continue;
    }
    if (arg === "--rollback-steps-back") {
      const raw = eat(i).trim();
      const value = Number.parseInt(raw, 10);
      if (!Number.isInteger(value) || value < 1) {
        die(`Invalid --rollback-steps-back: ${raw}`);
      }
      rollbackStepsBack = value;
      i++;
      continue;
    }
    if (arg === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (arg === "--pause-before-notarize") {
      pauseBeforeNotarize = true;
      continue;
    }
    if (arg === "--skip-build") {
      skip.add("build");
      continue;
    }
    if (arg === "--skip") {
      const v = eat(i);
      for (const part of v.split(",")) {
        const id = part.trim();
        if (id) skip.add(id);
      }
      i++;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      console.log(usage());
      process.exit(0);
    }
    die(`Unknown argument: ${arg}\n\n${usage()}`);
  }

  if (!appPath) {
    appPath = resolve(derivedData, "Build/Products/Release/Inline.app");
  }

  if (rollbackToBuild && !rollback) {
    die("--rollback-to-build requires --rollback");
  }
  if (rollbackStepsBack !== 1 && !rollback) {
    die("--rollback-steps-back requires --rollback");
  }
  if (rollback && rollbackToBuild && rollbackStepsBack !== 1) {
    die("Use either --rollback-to-build or --rollback-steps-back, not both.");
  }
  if (rollback && skip.size > 0) {
    die("--skip is not supported with --rollback.");
  }
  if (rollback && pauseBeforeNotarize) {
    die("--pause-before-notarize is not supported with --rollback.");
  }
  if (rollback && releaseTag) {
    die("--release-tag is not supported with --rollback.");
  }
  if (rollback && skipGithubRelease) {
    die("--skip-github-release is not supported with --rollback.");
  }

  return {
    channel,
    derivedData,
    appPath,
    dmgPath,
    sparkleDir,
    releaseTag,
    skipGithubRelease,
    skip,
    fromTask,
    dryRun,
    pauseBeforeNotarize,
    rollback,
    rollbackToBuild,
    rollbackStepsBack,
  };
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function commandExists(cmd: string): boolean {
  const res = spawnSync({ cmd: ["bash", "-lc", `command -v ${cmd} >/dev/null 2>&1`] });
  return res.exitCode === 0;
}

function trimTrailingSlash(s: string): string {
  return s.replace(/\/+$/g, "");
}

function nowIsoCompact(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function readPlistString(plistPath: string, key: string): string {
  const res = spawnSync({
    cmd: ["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, plistPath],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (res.exitCode !== 0) return "";
  return new TextDecoder().decode(res.stdout).trim();
}

function git(rootDir: string, args: string[]): string {
  const res = spawnSync({ cmd: ["git", "-C", rootDir, ...args], stdout: "pipe", stderr: "pipe" });
  if (res.exitCode !== 0) return "";
  return new TextDecoder().decode(res.stdout).trim();
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function promptPickChannel(): Promise<"stable" | "beta"> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q: string) => new Promise<string>((res) => rl.question(q, res));
  try {
    // Require an explicit interaction when the operator didn't pass --channel.
    // Enter defaults to beta (safer default for local runs).
    // We still show the prompt so the operator is aware of the selection.
    while (true) {
      const answer = (await ask("Select channel: [1] stable  [2] beta (default)  > ")).trim().toLowerCase();
      if (!answer || answer === "2" || answer === "beta" || answer === "b") return "beta";
      if (answer === "1" || answer === "stable" || answer === "s") return "stable";
      console.log("Please enter 1/stable or 2/beta.");
    }
  } finally {
    rl.close();
  }
}

function ansiStrip(s: string): string {
  return s.replace(/\x1b\[[0-9;]*m/g, "");
}

const color = {
  reset: "\x1b[0m",
  dim: "\x1b[2m",
  bold: "\x1b[1m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  gray: "\x1b[90m",
};

class Ui {
  private frame = 0;
  private lastRenderAt = 0;
  private currentTaskId = "";
  private currentLog: string[] = [];
  private lastError = "";
  private tasks: Array<{ id: string; title: string; status: TaskStatus; note?: string }> = [];
  private ticker: Timer | null = null;
  private hintLine = "";

  constructor(private readonly interactive: boolean) {}

  setHintLine(hint: string) {
    this.hintLine = hint;
    this.render(true);
  }

  init(tasks: Task[]) {
    this.tasks = tasks.map((t) => ({
      id: t.id,
      title: t.title,
      status: t.enabled ? "pending" : "skipped",
      note: !t.enabled ? t.skipReason : undefined,
    }));
    this.render(true);
  }

  setRunning(taskId: string) {
    this.currentTaskId = taskId;
    this.currentLog = [];
    this.lastError = "";
    this.setStatus(taskId, "running");
    this.startTicker();
  }

  setSkipped(taskId: string, reason?: string) {
    this.setStatus(taskId, "skipped", reason);
    this.stopTicker();
  }

  setSuccess(taskId: string, note?: string) {
    this.setStatus(taskId, "success", note);
    this.stopTicker();
  }

  setFailed(taskId: string, message: string) {
    this.lastError = message;
    this.setStatus(taskId, "failed");
    this.stopTicker();
  }

  log(line: string) {
    const cleaned = ansiStrip(line).replace(/\r/g, "").trimEnd();
    if (!cleaned) return;
    this.currentLog.push(cleaned);
    if (this.currentLog.length > 200) this.currentLog.splice(0, this.currentLog.length - 200);
    this.render(false);
  }

  info(line: string) {
    if (this.interactive) this.log(line);
    else console.log(line);
  }

  error(line: string) {
    if (this.interactive) this.log(line);
    else console.error(line);
  }

  private setStatus(taskId: string, status: TaskStatus, note?: string) {
    const t = this.tasks.find((x) => x.id === taskId);
    if (t) {
      t.status = status;
      if (note) t.note = note;
    }
    this.render(true);
  }

  private statusBadge(status: TaskStatus): string {
    switch (status) {
      case "pending":
        return `${color.gray}[TODO]${color.reset}`;
      case "running": {
        const sp = ["|", "/", "-", "\\"][this.frame % 4];
        return `${color.blue}[ ${sp} ]${color.reset}`;
      }
      case "success":
        return `${color.green}[ OK ]${color.reset}`;
      case "failed":
        return `${color.red}[FAIL]${color.reset}`;
      case "skipped":
        return `${color.gray}[SKIP]${color.reset}`;
    }
  }

  private render(force: boolean) {
    if (!this.interactive) return;
    const now = Date.now();
    if (!force && now - this.lastRenderAt < 60) return;
    this.lastRenderAt = now;
    this.frame++;

    const lines: string[] = [];
    lines.push(`${color.bold}Inline macOS Release${color.reset}`);
    if (this.hintLine) lines.push(`${color.gray}${this.hintLine}${color.reset}`);
    lines.push(`${color.gray}Press Ctrl+C to cancel.${color.reset}`);
    lines.push("");

    for (const t of this.tasks) {
      const badge = this.statusBadge(t.status);
      const isCurrent = t.id === this.currentTaskId && t.status === "running";
      const title = isCurrent ? `${color.bold}${t.title}${color.reset}` : t.title;
      const note = t.note ? ` ${color.gray}(${t.note})${color.reset}` : "";
      lines.push(`${badge} ${title}${note}`);
    }

    const tail = this.currentLog.slice(-10);
    lines.push("");
    lines.push(`${color.bold}Logs${color.reset} ${color.gray}(latest)${color.reset}`);
    if (tail.length === 0) {
      lines.push(`${color.gray}${color.dim}(no output yet)${color.reset}`);
    } else {
      for (const l of tail) lines.push(`${color.gray}${l}${color.reset}`);
    }

    if (this.lastError) {
      lines.push("");
      lines.push(`${color.red}${color.bold}Error${color.reset}`);
      lines.push(`${color.red}${this.lastError}${color.reset}`);
    }

    // Clear screen + move cursor to top-left.
    process.stdout.write("\x1b[2J\x1b[H" + lines.join("\n") + "\n");
  }

  getCurrentTaskId(): string {
    return this.currentTaskId;
  }

  private startTicker() {
    if (!this.interactive) return;
    if (this.ticker) return;
    this.ticker = setInterval(() => this.render(false), 120);
  }

  private stopTicker() {
    if (!this.ticker) return;
    clearInterval(this.ticker);
    this.ticker = null;
  }
}

async function runStreaming(
  ui: Ui,
  cmd: string[],
  opts: { cwd: string; env?: Record<string, string> },
): Promise<void> {
  const proc = Bun.spawn(cmd, {
    cwd: opts.cwd,
    env: { ...process.env, ...(opts.env ?? {}) },
    stdout: "pipe",
    stderr: "pipe",
  });

  const forward = async (stream: ReadableStream<Uint8Array> | null, prefix: string) => {
    if (!stream) return;
    const reader = stream.getReader();
    const dec = new TextDecoder();
    let buf = "";
    while (true) {
      const { done, value } = await reader.read();
      if (done) break;
      buf += dec.decode(value, { stream: true });
      let idx: number;
      while ((idx = buf.indexOf("\n")) !== -1) {
        const line = buf.slice(0, idx);
        buf = buf.slice(idx + 1);
        ui.log(prefix + line);
      }
    }
    if (buf.trim().length) ui.log(prefix + buf);
  };

  await Promise.all([forward(proc.stdout, ""), forward(proc.stderr, "")]);
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Command failed (${exitCode}): ${cmd.map((c) => (c.includes(" ") ? JSON.stringify(c) : c)).join(" ")}`);
  }
}

function computeSkipOptions<T extends { skip: Set<string> }>(opts: T): T {
  // Expand convenience groups/aliases.
  if (opts.skip.has("upload")) opts.skip.add("upload-dmg");
  if (opts.skip.has("upload")) opts.skip.add("upload-appcast");
  if (opts.skip.has("appcast")) opts.skip.add("gen-appcast");
  if (opts.skip.has("appcast")) opts.skip.add("validate-appcast");
  if (opts.skip.has("appcast")) opts.skip.add("upload-appcast");
  if (opts.skip.has("github")) opts.skip.add("github");
  return opts;
}

function taskEnabled(opts: ReleaseOptions, id: string): boolean {
  return !opts.skip.has(id);
}

const KNOWN_SKIP_IDS = new Set([
  "build",
  "upload-sentry-dsyms",
  "post-check",
  "upload-dmg",
  "verify-dmg",
  "gen-appcast",
  "validate-appcast",
  "upload-appcast",
  "github",
  // Convenience aliases (expanded in computeSkipOptions)
  "upload",
  "appcast",
]);

function validateSkipIds(skip: Set<string>) {
  const unknown = [...skip].filter((id) => !KNOWN_SKIP_IDS.has(id));
  if (unknown.length) {
    die(`Unknown --skip id(s): ${unknown.join(", ")}\nKnown ids: ${[...KNOWN_SKIP_IDS].sort().join(", ")}`);
  }
}

function formatCmd(args: string[]): string {
  return args
    .map((arg) => (/^[A-Za-z0-9_./:=+-]+$/.test(arg) ? arg : JSON.stringify(arg)))
    .join(" ");
}

function buildResumeCommand(ctx: ReleaseContext, fromTask: string): string {
  const args = ["bun", "run", "scripts/macos/release-app.ts", "--channel", ctx.channel, "--from", fromTask];
  const defaultDerivedData = resolve(ctx.rootDir, "build/InlineMacDirect");
  const defaultAppPath = resolve(defaultDerivedData, "Build/Products/Release/Inline.app");
  const defaultDmgPath = resolve(ctx.rootDir, "build/macos-direct/Inline.dmg");
  const defaultSparkleDir = resolve(ctx.rootDir, ".action/sparkle");
  const defaultReleaseTag = ctx.rollback ? "" : ctx.channel === "beta" ? "tip" : "";
  const concreteSkipIds = [...ctx.skip]
    .filter((id) => !["upload", "appcast", "github"].includes(id))
    .sort();

  if (ctx.rollback) {
    args.push("--rollback");
    if (ctx.rollbackToBuild) args.push("--rollback-to-build", ctx.rollbackToBuild);
    else if (ctx.rollbackStepsBack !== 1) args.push("--rollback-steps-back", String(ctx.rollbackStepsBack));
  } else if (ctx.releaseTag !== defaultReleaseTag) {
    args.push("--release-tag", ctx.releaseTag);
  }

  if (ctx.skipGithubRelease) args.push("--skip-github-release");
  if (concreteSkipIds.length) args.push("--skip", concreteSkipIds.join(","));
  if (ctx.pauseBeforeNotarize) args.push("--pause-before-notarize");
  if (ctx.derivedData !== defaultDerivedData) args.push("--derived-data", ctx.derivedData);
  if (ctx.appPath !== defaultAppPath) args.push("--app-path", ctx.appPath);
  if (ctx.dmgPath !== defaultDmgPath) args.push("--dmg-path", ctx.dmgPath);
  if (ctx.sparkleDir !== defaultSparkleDir) args.push("--sparkle-dir", ctx.sparkleDir);

  return formatCmd(args);
}

async function main() {
  const rootDir = resolve(import.meta.dir, "../..");
  const interactive = Boolean(process.stdout.isTTY && process.stderr.isTTY && !process.env.CI);
  const ui = new Ui(interactive);

  let keepTempDir = false;
  const parsedRaw = parseArgs(process.argv.slice(2), rootDir);
  if (!parsedRaw.rollback) {
    validateSkipIds(parsedRaw.skip);
  }
  const parsed0 = parsedRaw.rollback ? parsedRaw : computeSkipOptions(parsedRaw);
  let channel = parsed0.channel;
  if (!channel) {
    if (!interactive) {
      channel = "beta";
      console.log("No --channel provided; defaulting to beta.");
    } else {
      channel = await promptPickChannel();
      console.log(`Using channel: ${channel}`);
    }
  }
  const releaseTag = parsed0.rollback ? "" : parsed0.releaseTag || (channel === "beta" ? "tip" : "");
  const opts: ReleaseOptions = {
    channel,
    derivedData: parsed0.derivedData,
    appPath: parsed0.appPath,
    dmgPath: parsed0.dmgPath,
    sparkleDir: parsed0.sparkleDir,
    releaseTag,
    skipGithubRelease: parsed0.skipGithubRelease || parsed0.skip.has("github"),
    skip: parsed0.skip,
    fromTask: parsed0.fromTask,
    dryRun: parsed0.dryRun,
    pauseBeforeNotarize: parsed0.pauseBeforeNotarize,
    rollback: parsed0.rollback,
    rollbackToBuild: parsed0.rollbackToBuild,
    rollbackStepsBack: parsed0.rollbackStepsBack,
  };

  // Temp dir is created up-front so we can point to it on failures.
  const tempRoot = resolve(rootDir, "build/macos-release-tmp");
  mkdirSync(tempRoot, { recursive: true });
  const nonce = Math.random().toString(16).slice(2, 8);
  const tempDir = resolve(tempRoot, `release-app.${nowIsoCompact()}.${nonce}`);
  mkdirSync(tempDir, { recursive: true });

  const ctx: ReleaseContext = {
    rootDir,
    tempDir,
    signingKeyPath: resolve(tempDir, "signing.key"),
    signUpdatePath: resolve(tempDir, "sign_update.txt"),
    appcastPath: resolve(tempDir, "appcast.xml"),
    appcastOutputPath: resolve(tempDir, "appcast_new.xml"),
    rollbackMetaPath: resolve(tempDir, "rollback_meta.json"),
    buildNumber: "",
    version: "",
    commit: "",
    commitLong: "",
    baseUrl: "",
    dmgUrl: "",
    appcastUrl: "",
    rollbackSelectedBuild: "",
    rollbackSelectedUrl: "",
    rollbackRemovedBuilds: [],
    ...opts,
  };

  ui.setHintLine(
    opts.rollback
      ? `Rollback  Channel: ${opts.channel}${opts.rollbackToBuild ? `  Build: ${opts.rollbackToBuild}` : `  Steps back: ${opts.rollbackStepsBack}`}${opts.fromTask ? `  From: ${opts.fromTask}` : ""}${opts.dryRun ? "  Dry run" : ""}`
      : `Release  Channel: ${opts.channel}${opts.releaseTag ? `  Tag: ${opts.releaseTag}` : ""}${opts.fromTask ? `  From: ${opts.fromTask}` : ""}${opts.pauseBeforeNotarize ? "  Pause before notarize" : ""}${opts.dryRun ? "  Dry run" : ""}`,
  );

  const tasks: Task[] = [];

  const runPreflight: Task["run"] = async (ctx, ui) => {
    const missing: string[] = [];
    for (const c of ["bun", "python3", "curl", "git"]) {
      if (!commandExists(c)) missing.push(c);
    }
    if (ctx.rollback) {
      // Rollback only needs feed editing + upload tooling.
    } else if (taskEnabled(opts, "build")) {
      for (const c of ["xcodebuild", "xcrun", "codesign", "security", "create-dmg", "rsync", "unzip", "perl"]) {
        if (!commandExists(c)) missing.push(c);
      }
    }
    if (!ctx.rollback && taskEnabled(opts, "upload-sentry-dsyms")) {
      if (!commandExists("ditto")) {
        ui.info("Warning: upload-sentry-dsyms is best-effort and will fail because `ditto` is missing.");
      }
      if (!process.env.SENTRY_AUTH_TOKEN && !commandExists("sentry")) {
        ui.info("Warning: upload-sentry-dsyms is best-effort and will be skipped after a failure unless SENTRY_AUTH_TOKEN or an authenticated `sentry` CLI session is available.");
      }
    }
    if (!ctx.rollback && taskEnabled(opts, "post-check")) {
      for (const c of ["hdiutil", "spctl", "lipo"]) {
        if (!commandExists(c)) missing.push(c);
      }
    }
    if (!ctx.rollback && !opts.skipGithubRelease && opts.releaseTag) {
      if (!commandExists("gh")) missing.push("gh");
    }
    if (ctx.pauseBeforeNotarize && taskEnabled(opts, "build") && !interactive) {
      if (ctx.dryRun) ui.info("Warning: --pause-before-notarize requires an interactive terminal when executing the build.");
      else throw new Error("--pause-before-notarize requires an interactive terminal.");
    }
    if (missing.length) {
      if (ctx.dryRun) {
        ui.info(`Warning: missing command(s): ${missing.join(", ")}`);
        return;
      }
      throw new Error(`Missing required command(s): ${missing.join(", ")}`);
    }
  };

  tasks.push({
    id: "preflight",
    title: "Preflight checks",
    enabled: true,
    dryRun: async (ctx, ui) => {
      ui.info("Checking tool availability only.");
      await runPreflight(ctx, ui);
    },
    run: runPreflight,
  });

  if (opts.rollback) {
    tasks.push({
      id: "fetch-appcast",
      title: "Fetch current appcast",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info("  curl -fsSL <PUBLIC_RELEASES_R2_PUBLIC_BASE_URL>/mac/<channel>/appcast.xml -o <temp>/appcast.xml");
        ui.info("Requires env:");
        ui.info("  PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
      },
      run: async (ctx, ui) => {
        ctx.baseUrl = trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
        await runStreaming(ui, ["curl", "-fsSL", ctx.appcastUrl, "-o", ctx.appcastPath], { cwd: ctx.rootDir });
      },
    });

    tasks.push({
      id: "prepare-rollback",
      title: "Generate rolled-back appcast",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(
          ctx.rollbackToBuild
            ? `  python3 scripts/macos/rollback_appcast.py --appcast <temp>/appcast.xml --output <temp>/appcast_new.xml --metadata-output <temp>/rollback_meta.json --target-build ${ctx.rollbackToBuild}`
            : `  python3 scripts/macos/rollback_appcast.py --appcast <temp>/appcast.xml --output <temp>/appcast_new.xml --metadata-output <temp>/rollback_meta.json --steps-back ${ctx.rollbackStepsBack}`,
        );
      },
      run: async (ctx, ui) => {
        await runStreaming(
          ui,
          [
            "python3",
            resolve(ctx.rootDir, "scripts/macos/rollback_appcast.py"),
            "--appcast",
            ctx.appcastPath,
            "--output",
            ctx.appcastOutputPath,
            "--metadata-output",
            ctx.rollbackMetaPath,
            ...(ctx.rollbackToBuild
              ? ["--target-build", ctx.rollbackToBuild]
              : ["--steps-back", String(ctx.rollbackStepsBack)]),
          ],
          { cwd: ctx.rootDir },
        );

        const metadata = JSON.parse(await Bun.file(ctx.rollbackMetaPath).text()) as RollbackMetadata;
        ctx.rollbackSelectedBuild = metadata.selectedBuild;
        ctx.rollbackSelectedUrl = metadata.selectedUrl;
        ctx.rollbackRemovedBuilds = metadata.removedBuilds;
        ctx.buildNumber = metadata.selectedBuild;
        ctx.dmgUrl = metadata.selectedUrl;

        ui.info(`Rollback target build: ${ctx.rollbackSelectedBuild}`);
        if (ctx.rollbackRemovedBuilds.length > 0) {
          ui.info(`Removing newer builds from feed: ${ctx.rollbackRemovedBuilds.join(", ")}`);
        }
      },
    });

    tasks.push({
      id: "verify-rollback-dmg",
      title: "Verify rollback DMG availability",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info("  curl -fsI <selected-rollback-dmg-url>");
      },
      run: async (ctx, ui) => {
        if (!ctx.dmgUrl) {
          throw new Error("Rollback DMG URL missing. prepare-rollback must run first.");
        }
        for (let attempt = 1; attempt <= 3; attempt++) {
          ui.info(`curl -I ${ctx.dmgUrl} (attempt ${attempt}/3)`);
          const res = spawnSync({ cmd: ["curl", "-fsI", ctx.dmgUrl], stdout: "pipe", stderr: "pipe" });
          if (res.exitCode === 0) return;
          if (attempt === 3) {
            const err = new TextDecoder().decode(res.stderr).trim();
            throw new Error(`Rollback DMG not reachable at ${ctx.dmgUrl}${err ? `\n${err}` : ""}`);
          }
          await sleep(1000);
        }
      },
    });

    tasks.push({
      id: "validate-appcast",
      title: "Validate rolled-back appcast",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info("  python3 scripts/macos/validate_appcast.py --appcast <temp>/appcast_new.xml --require-build <selected-build> --require-url <selected-rollback-dmg-url>");
      },
      run: async (ctx, ui) => {
        if (!ctx.buildNumber || !ctx.dmgUrl) {
          throw new Error("Rollback metadata missing. prepare-rollback must run first.");
        }
        await runStreaming(
          ui,
          [
            "python3",
            resolve(ctx.rootDir, "scripts/macos/validate_appcast.py"),
            "--appcast",
            ctx.appcastOutputPath,
            "--require-build",
            ctx.buildNumber,
            "--require-url",
            ctx.dmgUrl,
          ],
          { cwd: ctx.rootDir },
        );
      },
    });

    tasks.push({
      id: "upload-appcast",
      title: "Upload rolled-back appcast to R2",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  UPLOAD_MODE=appcast CHANNEL=${ctx.channel} APPCAST_PATH=<temp>/appcast_new.xml BUILD_NUMBER=<selected-build> bun run scripts/macos/release-direct.ts`);
        ui.info("Requires env:");
        ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT");
      },
      run: async (ctx, ui) => {
        if (!ctx.buildNumber) {
          throw new Error("Rollback build number missing. prepare-rollback must run first.");
        }
        requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
        requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
        requireEnv("PUBLIC_RELEASES_R2_BUCKET");
        requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
        await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
          cwd: ctx.rootDir,
          env: {
            UPLOAD_MODE: "appcast",
            CHANNEL: ctx.channel,
            APPCAST_PATH: ctx.appcastOutputPath,
            BUILD_NUMBER: ctx.buildNumber,
          },
        });
      },
    });
  } else {
    tasks.push({
      id: "build",
      title: "Build, sign, DMG, notarize (build-direct.sh)",
      enabled: taskEnabled(opts, "build"),
      skipReason: taskEnabled(opts, "build") ? undefined : "operator requested",
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  bash scripts/macos/build-direct.sh`);
        ui.info("With env:");
        ui.info(`  CHANNEL=${ctx.channel}`);
        ui.info(`  DERIVED_DATA=${ctx.derivedData}`);
        ui.info(`  DMG_PATH=${ctx.dmgPath}`);
        ui.info(`  SPARKLE_DIR=${ctx.sparkleDir}`);
        ui.info(`  PAUSE_BEFORE_NOTARIZE=${ctx.pauseBeforeNotarize ? "1" : "0"}`);
        ui.info("build-direct.sh enforces signing/notarization env vars.");
      },
      run: async (ctx, ui) => {
        // Let build-direct.sh enforce its own env requirements. We only pass paths/options through.
        ui.info(`Running build script; output in ${ctx.tempDir}`);
        await runStreaming(ui, ["bash", resolve(ctx.rootDir, "scripts/macos/build-direct.sh")], {
          cwd: ctx.rootDir,
          env: {
            CHANNEL: ctx.channel,
            DERIVED_DATA: ctx.derivedData,
            DMG_PATH: ctx.dmgPath,
            SPARKLE_DIR: ctx.sparkleDir,
            PAUSE_BEFORE_NOTARIZE: ctx.pauseBeforeNotarize ? "1" : "0",
          },
        });
      },
    });

    tasks.push({
      id: "upload-sentry-dsyms",
      title: "Upload dSYMs to Sentry",
      enabled: taskEnabled(opts, "upload-sentry-dsyms"),
      skipReason: taskEnabled(opts, "upload-sentry-dsyms") ? undefined : "operator requested",
      softFail: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  bun run scripts/macos/upload-dsyms.ts --search-root ${resolve(ctx.derivedData, "Build/Products/Release")}`);
        ui.info("Auth:");
        ui.info("  Uses SENTRY_AUTH_TOKEN if set, otherwise resolves the token from `sentry auth token`.");
        ui.info("Optional env:");
        ui.info("  SENTRY_ORG (default: usenoor), SENTRY_PROJECT (default: inline-ios-macos), SENTRY_API_URL (default: https://us.sentry.io)");
        ui.info("Behavior:");
        ui.info("  This step is best-effort; failures are logged and the release continues.");
      },
      run: async (ctx, ui) => {
        const searchRoot = resolve(ctx.derivedData, "Build/Products/Release");
        if (!existsSync(searchRoot)) {
          throw new Error(`Release products directory not found at ${searchRoot}`);
        }
        await runStreaming(
          ui,
          ["bun", "run", resolve(ctx.rootDir, "scripts/macos/upload-dsyms.ts"), "--search-root", searchRoot],
          { cwd: ctx.rootDir },
        );
      },
    });

    tasks.push({
      id: "post-check",
      title: "Post-check DMG (staple, codesign, gatekeeper)",
      enabled: taskEnabled(opts, "post-check"),
      skipReason: taskEnabled(opts, "post-check") ? undefined : "operator requested",
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  bash scripts/macos/post-check.sh`);
        ui.info("With env:");
        ui.info(`  DMG_PATH=${ctx.dmgPath}`);
        ui.info(`  APP_PATH=${ctx.appPath}`);
      },
      run: async (ctx, ui) => {
        await runStreaming(ui, ["bash", resolve(ctx.rootDir, "scripts/macos/post-check.sh")], {
          cwd: ctx.rootDir,
          env: {
            DMG_PATH: ctx.dmgPath,
          },
        });
      },
    });

    tasks.push({
      id: "upload-dmg",
    title: "Upload DMG to R2",
    enabled: taskEnabled(opts, "upload-dmg"),
    skipReason: taskEnabled(opts, "upload-dmg") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  UPLOAD_MODE=dmg CHANNEL=${ctx.channel} DMG_PATH=${ctx.dmgPath} BUILD_NUMBER=<from app plist> bun run scripts/macos/release-direct.ts`);
      ui.info("Requires env:");
      ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT, PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
    },
    run: async (ctx, ui) => {
      // Validate local artifacts.
      if (!existsSync(ctx.appPath)) throw new Error(`App not found at ${ctx.appPath}`);
      if (!existsSync(ctx.dmgPath)) throw new Error(`DMG not found at ${ctx.dmgPath}`);

      // Pull build number from the built app for consistency (works with --skip build).
      const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
      ctx.buildNumber = readPlistString(infoPlist, "CFBundleVersion") || "";
      if (!ctx.buildNumber) throw new Error(`Unable to read CFBundleVersion from ${infoPlist}`);

      // R2 URL context.
      // release-direct.ts will also check these, but validating here gives a clearer error.
      requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
      requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
      requireEnv("PUBLIC_RELEASES_R2_BUCKET");
      requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
      ctx.baseUrl = trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
      ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
      ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;

      await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
        cwd: ctx.rootDir,
        env: {
          UPLOAD_MODE: "dmg",
          CHANNEL: ctx.channel,
          DMG_PATH: ctx.dmgPath,
          BUILD_NUMBER: ctx.buildNumber,
        },
      });
    },
    });

    tasks.push({
      id: "verify-dmg",
    title: "Verify DMG availability (HEAD request)",
    enabled: taskEnabled(opts, "verify-dmg"),
    skipReason: taskEnabled(opts, "verify-dmg") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  curl -fsI <PUBLIC_RELEASES_R2_PUBLIC_BASE_URL>/mac/${ctx.channel}/<build>/Inline.dmg (retry up to 5x)`);
      ui.info("Requires env:");
      ui.info("  PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
    },
    run: async (ctx, ui) => {
      if (!ctx.dmgUrl) {
        // If upload-dmg was skipped, we still want a consistent URL for verification/appcast.
        const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
        ctx.buildNumber = ctx.buildNumber || readPlistString(infoPlist, "CFBundleVersion") || "";
        if (!ctx.buildNumber) throw new Error(`Unable to read CFBundleVersion from ${infoPlist}`);
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
      }

      for (let attempt = 1; attempt <= 5; attempt++) {
        ui.info(`curl -I ${ctx.dmgUrl} (attempt ${attempt}/5)`);
        const res = spawnSync({ cmd: ["curl", "-fsI", ctx.dmgUrl], stdout: "pipe", stderr: "pipe" });
        if (res.exitCode === 0) return;
        if (attempt === 5) {
          const err = new TextDecoder().decode(res.stderr).trim();
          throw new Error(`DMG not reachable at ${ctx.dmgUrl}${err ? `\n${err}` : ""}`);
        }
        await sleep(2000);
      }
    },
    });

    tasks.push({
      id: "gen-appcast",
    title: "Generate appcast (sign_update + update_appcast.py)",
    enabled: taskEnabled(opts, "gen-appcast"),
    skipReason: taskEnabled(opts, "gen-appcast") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  <sparkle>/bin/sign_update -f <temp>/signing.key ${ctx.dmgPath} | tee <temp>/sign_update.txt`);
      ui.info(`  curl -fsSL <PUBLIC_RELEASES_R2_PUBLIC_BASE_URL>/mac/${ctx.channel}/appcast.xml -o <temp>/appcast.xml (optional)`);
      ui.info("  python3 scripts/macos/update_appcast.py");
      ui.info("Requires env:");
      ui.info("  SPARKLE_PRIVATE_KEY (or MACOS_SPARKLE_PRIVATE_KEY), PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
    },
    run: async (ctx, ui) => {
      if (!existsSync(ctx.dmgPath)) throw new Error(`DMG not found at ${ctx.dmgPath}`);
      if (!existsSync(ctx.appPath)) throw new Error(`App not found at ${ctx.appPath}`);

      // Sparkle keys: accept CI-style aliases.
      if (!process.env.SPARKLE_PRIVATE_KEY && process.env.MACOS_SPARKLE_PRIVATE_KEY) {
        process.env.SPARKLE_PRIVATE_KEY = process.env.MACOS_SPARKLE_PRIVATE_KEY;
      }
      const sparklePrivateKey = requireEnv("SPARKLE_PRIVATE_KEY");

      const signUpdateBin = resolve(ctx.sparkleDir, "bin/sign_update");
      if (!existsSync(signUpdateBin)) {
        throw new Error(`Sparkle tool not found: ${signUpdateBin}\nExpected Sparkle tools under --sparkle-dir (default: <root>/.action/sparkle).`);
      }

      // Ensure URLs/metadata.
      if (!ctx.dmgUrl || !ctx.appcastUrl) {
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
        ctx.buildNumber = ctx.buildNumber || readPlistString(infoPlist, "CFBundleVersion") || "";
        if (!ctx.buildNumber) throw new Error(`Unable to read CFBundleVersion from ${infoPlist}`);
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
      }

      // Read build metadata from the built app where possible.
      const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
      ctx.version = readPlistString(infoPlist, "CFBundleShortVersionString") || ctx.buildNumber;
      ctx.commit = readPlistString(infoPlist, "InlineCommit") || git(ctx.rootDir, ["rev-parse", "--short", "HEAD"]);
      ctx.commitLong = git(ctx.rootDir, ["rev-parse", "HEAD"]);

      writeFileSync(ctx.signingKeyPath, sparklePrivateKey);

      try {
        // sign_update writes to stdout; use tee so the operator sees output while
        // we also persist the exact payload used for appcast generation.
        await runStreaming(
          ui,
          [
            "bash",
            "-lc",
            `set -euo pipefail; ${JSON.stringify(signUpdateBin)} -f ${JSON.stringify(ctx.signingKeyPath)} ${JSON.stringify(ctx.dmgPath)} | tee ${JSON.stringify(ctx.signUpdatePath)}`,
          ],
          { cwd: ctx.rootDir },
        );
      } finally {
        // Never keep Sparkle private key material around longer than necessary.
        try {
          rmSync(ctx.signingKeyPath, { force: true });
        } catch {
          // ignore
        }
      }
      ui.info(`Wrote ${basename(ctx.signUpdatePath)} to ${ctx.signUpdatePath}`);

      // Fetch existing appcast (optional).
      const curlRes = spawnSync({
        cmd: ["curl", "-fsSL", ctx.appcastUrl, "-o", ctx.appcastPath],
        stdout: "pipe",
        stderr: "pipe",
      });
      if (curlRes.exitCode !== 0) {
        ui.info(`No existing appcast found at ${ctx.appcastUrl}; creating a new one.`);
        // Ensure file doesn't exist (update_appcast.py treats missing as "new").
        try {
          rmSync(ctx.appcastPath, { force: true });
        } catch {
          // ignore
        }
      }

      await runStreaming(ui, ["python3", resolve(ctx.rootDir, "scripts/macos/update_appcast.py")], {
        cwd: ctx.rootDir,
        env: {
          INLINE_BUILD: ctx.buildNumber,
          INLINE_VERSION: ctx.version,
          INLINE_CHANNEL: ctx.channel,
          INLINE_DMG_URL: ctx.dmgUrl,
          INLINE_MIN_MACOS: "15.0",
          INLINE_COMMIT: ctx.commit,
          INLINE_COMMIT_LONG: ctx.commitLong,
          SIGN_UPDATE_PATH: ctx.signUpdatePath,
          APPCAST_PATH: ctx.appcastPath,
          APPCAST_OUTPUT: ctx.appcastOutputPath,
        },
      });
    },
    });

    tasks.push({
      id: "validate-appcast",
    title: "Validate appcast",
    enabled: taskEnabled(opts, "validate-appcast"),
    skipReason: taskEnabled(opts, "validate-appcast") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info("  python3 scripts/macos/validate_appcast.py --appcast <temp>/appcast_new.xml --require-build <build> --require-url <dmg-url>");
    },
    run: async (ctx, ui) => {
      if (!ctx.buildNumber) {
        const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
        ctx.buildNumber = readPlistString(infoPlist, "CFBundleVersion") || "";
        if (!ctx.buildNumber) throw new Error(`Unable to read CFBundleVersion from ${infoPlist}`);
      }
      if (!ctx.dmgUrl) {
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
      }

      await runStreaming(ui, ["python3", resolve(ctx.rootDir, "scripts/macos/validate_appcast.py"), "--appcast", ctx.appcastOutputPath, "--require-build", ctx.buildNumber, "--require-url", ctx.dmgUrl], {
        cwd: ctx.rootDir,
      });
    },
    });

    tasks.push({
      id: "upload-appcast",
    title: "Upload appcast to R2",
    enabled: taskEnabled(opts, "upload-appcast"),
    skipReason: taskEnabled(opts, "upload-appcast") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  UPLOAD_MODE=appcast CHANNEL=${ctx.channel} APPCAST_PATH=<temp>/appcast_new.xml BUILD_NUMBER=<from app plist> bun run scripts/macos/release-direct.ts`);
      ui.info("Requires env:");
      ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT");
    },
    run: async (ctx, ui) => {
      if (!ctx.buildNumber) {
        const infoPlist = resolve(ctx.appPath, "Contents/Info.plist");
        ctx.buildNumber = readPlistString(infoPlist, "CFBundleVersion") || "";
        if (!ctx.buildNumber) throw new Error(`Unable to read CFBundleVersion from ${infoPlist}`);
      }

      requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
      requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
      requireEnv("PUBLIC_RELEASES_R2_BUCKET");
      requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
      await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
        cwd: ctx.rootDir,
        env: {
          UPLOAD_MODE: "appcast",
          CHANNEL: ctx.channel,
          APPCAST_PATH: ctx.appcastOutputPath,
          BUILD_NUMBER: ctx.buildNumber,
        },
      });
    },
    });

  // `github` is controllable via both `--skip-github-release` and `--skip github`.
  // Keep the `enabled` computation consistent with other tasks by also checking `taskEnabled`.
    const githubEnabled = Boolean(opts.releaseTag && !opts.skipGithubRelease && taskEnabled(opts, "github"));
    tasks.push({
      id: "github",
    title: "Update GitHub tag/release and upload DMG",
    enabled: githubEnabled,
    skipReason: githubEnabled
      ? undefined
      : opts.skipGithubRelease || opts.skip.has("github")
        ? "operator requested"
        : "no --release-tag",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  git tag -fa ${ctx.releaseTag} -m "Latest Sparkle release" HEAD`);
      ui.info(`  git push --force origin ${ctx.releaseTag}`);
      ui.info(`  gh release view ${ctx.releaseTag} || gh release create ${ctx.releaseTag} ...`);
      ui.info(`  gh release upload ${ctx.releaseTag} ${ctx.dmgPath} --clobber`);
    },
    run: async (ctx, ui) => {
      if (!ctx.releaseTag) throw new Error("Internal error: github task enabled without releaseTag");
      if (!existsSync(ctx.dmgPath)) throw new Error(`DMG not found at ${ctx.dmgPath}`);

      // Force-update tag and attach DMG.
      await runStreaming(ui, ["git", "-C", ctx.rootDir, "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com", "tag", "-fa", ctx.releaseTag, "-m", "Latest Sparkle release", "HEAD"], {
        cwd: ctx.rootDir,
      });
      await runStreaming(ui, ["git", "-C", ctx.rootDir, "push", "--force", "origin", ctx.releaseTag], { cwd: ctx.rootDir });

      const prereleaseFlag = ctx.channel === "beta" ? ["--prerelease"] : [];
      const viewRes = spawnSync({ cmd: ["gh", "release", "view", ctx.releaseTag], stdout: "pipe", stderr: "pipe" });
      if (viewRes.exitCode !== 0) {
        await runStreaming(ui, ["gh", "release", "create", ctx.releaseTag, "--title", ctx.releaseTag, ...prereleaseFlag, "--notes", "Automated macOS direct release."], { cwd: ctx.rootDir });
      } else if (ctx.channel === "beta") {
        await runStreaming(ui, ["gh", "release", "edit", ctx.releaseTag, "--prerelease"], { cwd: ctx.rootDir });
      }

      await runStreaming(ui, ["gh", "release", "upload", ctx.releaseTag, ctx.dmgPath, "--clobber"], { cwd: ctx.rootDir });
    },
    });
  }

  // Initialize UI and run tasks.
  if (opts.fromTask) {
    const target = tasks.find((task) => task.id === opts.fromTask);
    if (!target) {
      die(`Unknown --from task id: ${opts.fromTask}\nAvailable ids: ${tasks.map((task) => task.id).join(", ")}`);
    }
    if (!target.enabled) {
      die(`--from ${opts.fromTask} refers to a disabled step${target.skipReason ? ` (${target.skipReason})` : ""}.`);
    }
  }
  ui.init(tasks);

  const cleanup = () => {
    if (keepTempDir) return;
    try {
      rmSync(ctx.tempDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  };
  process.on("exit", cleanup);
  process.on("SIGINT", () => {
    cleanup();
    process.exit(130);
  });

  try {
    if (opts.dryRun) {
      ui.info("Dry run: not executing. Showing what would run.");
    }
    let reachedFrom = !opts.fromTask;
    for (const task of tasks) {
      if (!task.enabled) {
        ui.setSkipped(task.id, task.skipReason);
        continue;
      }
      if (opts.fromTask && task.id === opts.fromTask) {
        reachedFrom = true;
      }
      if (opts.fromTask && task.id !== "preflight" && !reachedFrom) {
        ui.setSkipped(task.id, `resume from ${opts.fromTask}`);
        continue;
      }
      ui.setRunning(task.id);
      try {
        if (opts.dryRun) {
          if (task.dryRun) await task.dryRun(ctx, ui);
          else ui.info("(No dry-run details for this step.)");
        } else {
          await task.run(ctx, ui);
        }
      } catch (err) {
        if (!task.softFail) throw err;
        const msg = err instanceof Error ? err.message : String(err);
        ui.error(`Non-fatal: ${task.id} failed; continuing release.`);
        ui.error(msg);
        ui.setSuccess(task.id, "continued after failure");
        continue;
      }
      ui.setSuccess(task.id);
    }
  } catch (err) {
    keepTempDir = true;
    // Best-effort cleanup for sensitive temporary files, even when we keep the temp dir for debugging.
    try {
      rmSync(ctx.signingKeyPath, { force: true });
    } catch {
      // ignore
    }
    const msg = err instanceof Error ? err.message : String(err);
    const current = ui.getCurrentTaskId();
    if (current) {
      ui.setFailed(current, msg);
      if (!interactive) ui.error(msg);
    } else ui.error(msg);
    if (current) {
      ui.error(`Retry this step: ${buildResumeCommand(ctx, current)}`);
      const currentIndex = tasks.findIndex((task) => task.id === current);
      const nextTask = currentIndex === -1 ? undefined : tasks.slice(currentIndex + 1).find((task) => task.enabled);
      if (nextTask) {
        ui.error(`Continue past it: ${buildResumeCommand(ctx, nextTask.id)}`);
      }
    }
    ui.error(`Temp dir: ${ctx.tempDir}`);
    process.exit(1);
  }

  ui.info(opts.rollback ? "Rollback appcast publish complete." : "Release pipeline complete.");
}

await main();
