import { spawnSync } from "bun";
import { createHash, randomUUID } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, realpathSync, readFileSync, rmdirSync, rmSync, unlinkSync, writeFileSync } from "fs";
import { basename, dirname, resolve } from "path";
import { createInterface } from "node:readline";
import { readBuiltAppMetadata, readDmgAppMetadata, metadataMismatches, type BuiltAppMetadata } from "./app-release-metadata";
import { getR2Context } from "./release-direct";
import {
  macosReleaseSourceStatusLines,
  macosSourceSnapshotPathsFromManifest,
  macosSourceSnapshotSha256,
  macosSourceSnapshotSha256ForPaths,
  stageMacosSourceSnapshot,
} from "./macos-source-snapshot";

const sparkleVersion = "2.9.3";
const macosReleaseArch = "arm64";
type ReleaseChannel = "stable" | "beta" | "tip";

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
  channel: ReleaseChannel;
  derivedData: string;
  appPath: string;
  dmgPath: string;
  sparkleDir: string;
  releaseTag: string;
  skipGithubRelease: boolean;
  allowDirty: boolean;
  experimentalTip: boolean;
  skip: Set<string>;
  fromTask: string;
  dryRun: boolean;
  rollback: boolean;
  rollbackToBuild: string;
  rollbackStepsBack: number;
  dropBuild: string;
  createNewAppcast: boolean;
  sourceCommit: string;
  sourceBuild: string;
  sourceSnapshot: string;
  artifactBuild: string;
};

type ParsedArgs = Omit<ReleaseOptions, "channel" | "releaseTag"> & {
  channel?: ReleaseChannel;
  releaseTag?: string;
};

type RollbackMetadata = {
  selectedBuild: string;
  selectedUrl: string;
  removedBuilds: string[];
};

type PruneMetadata = {
  droppedBuild: string;
  droppedUrl: string;
  latestBuild: string;
  latestUrl: string;
  remainingBuilds: string[];
};

type ReleaseContext = ReleaseOptions & {
  rootDir: string;
  sourceRoot: string;
  sourceManifestPath: string;
  tempDir: string;
  signingKeyPath: string;
  signUpdatePath: string;
  appcastPath: string;
  appcastHeadersPath: string;
  appcastOutputPath: string;
  rollbackMetaPath: string;
  pruneMetaPath: string;
  historyDir: string;
  buildNumber: string;
  version: string;
  commit: string;
  commitLong: string;
  baseUrl: string;
  dmgUrl: string;
  appcastUrl: string;
  minimumSystemVersion: string;
  rollbackSelectedBuild: string;
  rollbackSelectedUrl: string;
  rollbackRemovedBuilds: string[];
  pruneDroppedBuild: string;
  pruneDroppedUrl: string;
  pruneLatestBuild: string;
  pruneLatestUrl: string;
  sourceCommitShort: string;
  dmgSize: number;
  dmgSha256: string;
  provenancePath: string;
  appcastExpectedEtag: string;
  appcastExpectAbsent: boolean;
  channelLockToken: string;
};

type HeldLock = {
  path: string;
  token: string;
};

type AppcastFetchDecision = "use-existing" | "create-new";

type ArtifactProvenance = {
  schemaVersion: 1 | 2;
  sourceCommit?: string;
  sourceBuild?: string;
  sourceClean?: boolean;
  sourceState?: string;
  sourceSnapshotSha256?: string;
  buildNumber?: string;
  revision?: string;
  appExecutableSha256: string;
  dmgSize: number;
  dmgSha256: string;
};

let activeSubprocess: ReturnType<typeof Bun.spawn> | undefined;

function usage(): string {
  return [
    "Usage: bun run macos/release-app.ts [options]",
    "",
    "Options:",
    "  --channel stable|beta|tip        Update channel (default: beta; prompts if omitted in an interactive terminal)",
    "  --derived-data <path>            Xcode DerivedData (default: target of <root>/build/InlineMacDirect/reusable)",
    "  --app-path <path>                App path (default: <derived-data>/Build/Products/Release/Inline.app)",
    "  --dmg-path <path>                DMG path (default: unique <root>/build/macos-direct/release-*/Inline.dmg)",
    `  --sparkle-dir <path>             Sparkle tools dir (default: <root>/.action/sparkle/${sparkleVersion})`,
    "  --release-tag <tag>              Attach DMG to GitHub release/tag (default: selected channel name)",
    "  --skip-github-release            Skip GitHub release/tag steps",
    "  --allow-dirty                    Allow only a local non-publishing build from dirty source",
    "  --experimental-tip               Publish a dirty source snapshot only to the tip DMG/appcast; never GitHub",
    "  --from <id>                      Resume from a task id without rerunning earlier steps (preflight still runs)",
    "  --skip <ids>                     Skip steps (comma-separated or repeatable)",
    "                                  Known ids: build, upload-sentry-dsyms, post-check, upload-dmg, verify-dmg, gen-appcast, validate-appcast, upload-appcast, github",
    "                                  Aliases: upload (upload-dmg+upload-appcast), appcast (gen+validate+upload)",
    "  --rollback                       Roll back the live appcast to an older build already present in the channel feed",
    "  --rollback-to-build <build>      Target build to restore (default: previous appcast item)",
    "  --rollback-steps-back <n>        Pick the Nth previous appcast item (default: 1)",
    "  --drop-build <build>             Remove one non-latest build from the live appcast and republish it",
    "  --create-new-appcast              Allow an absent feed only for an explicit first publication",
    "  --source-commit <sha>              Frozen source commit (printed automatically in resume commands)",
    "  --source-build <build>             Frozen source build number (printed automatically in resume commands)",
    "  --source-snapshot <sha256>         Frozen experimental source snapshot (printed automatically when resuming)",
    "  --artifact-build <build>           Frozen tip artifact build number (printed automatically when resuming)",
    "  --upload-sentry-dsyms            Upload dSYMs to Sentry (default; retained for explicitness)",
    "  --dry-run                         Print what would run, without executing the pipeline",
    "  --skip-build                      Alias for --skip build",
    "  -h, --help                       Show help",
    "",
    "Notes:",
    "  - This script intentionally does not auto-load scripts/.env. Export env vars in your shell.",
    "  - Skipped steps stay visible in the append-only summary.",
    "  - --rollback only republishes appcast.xml; it does not rebuild or downgrade already-installed builds.",
    "  - Existing appcast fetch/parse failures stop the release unless --create-new-appcast sees an actual 404.",
  ].join("\n");
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv: string[], rootDir: string): ParsedArgs {
  let channel: ReleaseChannel | undefined;
  let derivedData = defaultDerivedDataPath(rootDir);
  let appPath = "";
  let dmgPath = resolve(rootDir, "build/macos-direct", `release-${nowIsoCompact()}-${Math.random().toString(16).slice(2, 8)}`, "Inline.dmg");
  let sparkleDir = resolve(rootDir, ".action/sparkle", sparkleVersion);
  let releaseTag: string | undefined;
  let skipGithubRelease = false;
  let allowDirty = false;
  let experimentalTip = false;
  const skip = new Set<string>();
  let fromTask = "";
  let dryRun = false;
  let rollback = false;
  let rollbackToBuild = "";
  let rollbackStepsBack = 1;
  let dropBuild = "";
  let uploadSentryDsyms = false;
  let createNewAppcast = false;
  let sourceCommit = "";
  let sourceBuild = "";
  let sourceSnapshot = "";
  let artifactBuild = "";

  const resolveFromRoot = (p: string): string => {
    if (!p) return p;
    return p.startsWith("/") ? resolve(p) : resolve(rootDir, p);
  };

  const eat = (i: number) => argv[i + 1] ?? "";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--channel") {
      const v = eat(i);
      if (v !== "stable" && v !== "beta" && v !== "tip") die(`Invalid --channel: ${v}`);
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
    if (arg === "--allow-dirty") {
      allowDirty = true;
      continue;
    }
    if (arg === "--experimental-tip") {
      experimentalTip = true;
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
    if (arg === "--drop-build") {
      dropBuild = eat(i).trim();
      if (!dropBuild) die(`Missing value for ${arg}`);
      i++;
      continue;
    }
    if (arg === "--create-new-appcast") {
      createNewAppcast = true;
      continue;
    }
    if (arg === "--source-commit") {
      sourceCommit = eat(i).trim();
      if (!sourceCommit) die(`Missing value for ${arg}`);
      i++;
      continue;
    }
    if (arg === "--source-build") {
      sourceBuild = eat(i).trim();
      if (!/^\d+$/.test(sourceBuild)) die(`Invalid --source-build: ${sourceBuild}`);
      i++;
      continue;
    }
    if (arg === "--source-snapshot") {
      sourceSnapshot = eat(i).trim();
      if (!/^[0-9a-f]{64}$/.test(sourceSnapshot)) die(`Invalid --source-snapshot: ${sourceSnapshot}`);
      i++;
      continue;
    }
    if (arg === "--artifact-build") {
      artifactBuild = eat(i).trim();
      if (!/^\d+$/.test(artifactBuild)) die(`Invalid --artifact-build: ${artifactBuild}`);
      i++;
      continue;
    }
    if (arg === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (arg === "--upload-sentry-dsyms") {
      uploadSentryDsyms = true;
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
  if (derivedData === resolve("/")) {
    die("Refusing to use the filesystem root as --derived-data. Re-run without the malformed path argument.");
  }
  if (appPath === resolve("/Build/Products/Release/Inline.app")) {
    die("Refusing malformed --app-path /Build/Products/Release/Inline.app. Re-run without the malformed path argument.");
  }
  if (rollback && uploadSentryDsyms) {
    die("--upload-sentry-dsyms is not supported with --rollback.");
  }
  if (dropBuild && uploadSentryDsyms) {
    die("--upload-sentry-dsyms is not supported with --drop-build.");
  }
  if (!rollback && !dropBuild) {
    if (uploadSentryDsyms && skip.has("upload-sentry-dsyms")) {
      die("Use either --upload-sentry-dsyms or --skip upload-sentry-dsyms, not both.");
    }
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
  if (rollback && releaseTag) {
    die("--release-tag is not supported with --rollback.");
  }
  if (rollback && skipGithubRelease) {
    die("--skip-github-release is not supported with --rollback.");
  }
  if (dropBuild && rollback) {
    die("Use either --drop-build or --rollback, not both.");
  }
  if (dropBuild && skip.size > 0) {
    die("--skip is not supported with --drop-build.");
  }
  if (dropBuild && releaseTag) {
    die("--release-tag is not supported with --drop-build.");
  }
  if (dropBuild && skipGithubRelease) {
    die("--skip-github-release is not supported with --drop-build.");
  }
  if (dropBuild && allowDirty) {
    die("--allow-dirty is only useful for builds and is not supported with --drop-build.");
  }
  if (experimentalTip && (rollback || dropBuild)) {
    die("--experimental-tip is only supported for a normal release.");
  }
  if (experimentalTip && channel && channel !== "tip") {
    die("--experimental-tip can publish only to --channel tip.");
  }
  if (experimentalTip && releaseTag) {
    die("--experimental-tip never publishes to GitHub and cannot be combined with --release-tag.");
  }
  if (experimentalTip && allowDirty) {
    die("--experimental-tip already permits dirty source; do not combine it with --allow-dirty.");
  }
  if (experimentalTip && (sourceCommit || sourceBuild)) {
    die("--experimental-tip uses --source-snapshot and --artifact-build instead of commit-anchored source options.");
  }
  if (!experimentalTip && sourceSnapshot) {
    die("--source-snapshot is only supported with --experimental-tip.");
  }
  if (artifactBuild && channel && channel !== "tip") {
    die("--artifact-build is only supported for tip releases.");
  }
  if (experimentalTip && Boolean(sourceSnapshot) !== Boolean(artifactBuild)) {
    die("--source-snapshot and --artifact-build must be supplied together when resuming an experimental tip release.");
  }
  if ((rollback || dropBuild) && createNewAppcast) {
    die("--create-new-appcast is only supported for a normal release.");
  }
  if ((rollback || dropBuild) && (sourceCommit || sourceBuild)) {
    die("--source-commit and --source-build are only supported for a normal release.");
  }
  return {
    channel,
    derivedData,
    appPath,
    dmgPath,
    sparkleDir,
    releaseTag,
    skipGithubRelease,
    allowDirty,
    experimentalTip,
    skip,
    fromTask,
    dryRun,
    rollback,
    rollbackToBuild,
    rollbackStepsBack,
    dropBuild,
    createNewAppcast,
    sourceCommit,
    sourceBuild,
    sourceSnapshot,
    artifactBuild,
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

function activeXcodebuildForDerivedData(derivedData: string): string {
  if (!commandExists("pgrep")) return "";
  const result = spawnSync({ cmd: ["pgrep", "-afil", "xcodebuild"], stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) return "";
  return new TextDecoder()
    .decode(result.stdout)
    .split("\n")
    .find((line) => line.includes(`-derivedDataPath ${derivedData}`))
    ?.trim() ?? "";
}

function trimTrailingSlash(s: string): string {
  return s.replace(/\/+$/g, "");
}

function nowIsoCompact(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return `${d.getFullYear()}${pad(d.getMonth() + 1)}${pad(d.getDate())}-${pad(d.getHours())}${pad(d.getMinutes())}${pad(d.getSeconds())}`;
}

function defaultDerivedDataPath(rootDir: string): string {
  const reusablePath = resolve(rootDir, "build/InlineMacDirect/reusable");
  return existsSync(reusablePath) ? realpathSync(reusablePath) : reusablePath;
}

function sha256File(path: string): string {
  const result = spawnSync({ cmd: ["shasum", "-a", "256", path], stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    throw new Error(`Unable to hash ${path}: ${new TextDecoder().decode(result.stderr).trim()}`);
  }
  const digest = new TextDecoder().decode(result.stdout).trim().split(/\s+/, 1)[0] ?? "";
  if (!/^[0-9a-f]{64}$/.test(digest)) throw new Error(`Invalid SHA-256 output for ${path}`);
  return digest;
}

function pathLockName(prefix: string, path: string): string {
  const canonicalPath = existsSync(path) ? realpathSync(path) : resolve(path);
  return `${prefix}-${createHash("sha256").update(canonicalPath).digest("hex").slice(0, 16)}.lockdir`;
}

function acquireLock(lockRoot: string, name: string, details: Record<string, unknown>): HeldLock {
  mkdirSync(lockRoot, { recursive: true });
  const path = resolve(lockRoot, name);
  const token = randomUUID();
  try {
    mkdirSync(path, { mode: 0o700 });
  } catch (error) {
    if ((error as NodeJS.ErrnoException).code !== "EEXIST") throw error;
    const ownerPath = resolve(path, "owner.json");
    let owner = "";
    if (existsSync(ownerPath)) {
      try {
        const details = JSON.parse(readFileSync(ownerPath, "utf8")) as Record<string, unknown>;
        delete details.token;
        owner = JSON.stringify(details);
      } catch {
        owner = "unreadable owner record";
      }
    }
    const suffix = owner ? `\nCurrent owner: ${owner}` : "";
    throw new Error(`Release lock is already held: ${path}${suffix}\nIf no listed process is alive, inspect and remove this exact stale lock before retrying.`);
  }
  try {
    writeFileSync(resolve(path, "owner.json"), `${JSON.stringify({ token, pid: process.pid, startedAt: new Date().toISOString(), ...details })}\n`, { mode: 0o600 });
  } catch (error) {
    try {
      rmdirSync(path);
    } catch {
      // Preserve the original owner-record failure.
    }
    throw error;
  }
  return { path, token };
}

function releaseLock(lock: HeldLock): void {
  try {
    const ownerPath = resolve(lock.path, "owner.json");
    const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { token?: string };
    if (owner.token === lock.token) {
      unlinkSync(ownerPath);
      rmdirSync(lock.path);
    }
  } catch {
    // A missing or foreign lock is never removed.
  }
}

export function decideAppcastFetch(
  exitCode: number,
  httpStatus: number,
  createNewAppcast: boolean,
): AppcastFetchDecision {
  if (exitCode !== 0) {
    throw new Error(`Unable to fetch the existing appcast (curl exit ${exitCode}, HTTP ${httpStatus || "unknown"}). Refusing to replace feed history.`);
  }
  if (exitCode === 0 && httpStatus === 200) {
    if (createNewAppcast) {
      throw new Error("--create-new-appcast was passed, but the channel appcast already exists.");
    }
    return "use-existing";
  }
  if (httpStatus === 404 && createNewAppcast) return "create-new";
  if (httpStatus === 404) {
    throw new Error("Channel appcast does not exist. Pass --create-new-appcast only for an intentional first publication.");
  }
  throw new Error(`Unable to fetch the existing appcast (curl exit ${exitCode}, HTTP ${httpStatus || "unknown"}). Refusing to replace feed history.`);
}

export function appcastXmlForBuildAllocation(
  decision: AppcastFetchDecision,
  readExistingAppcast: () => string,
): string | undefined {
  return decision === "create-new" ? undefined : readExistingAppcast();
}

export function nextTipArtifactBuild(baseBuild: string, appcastXml: string | undefined, experimental: boolean): string {
  if (!/^\d+$/.test(baseBuild)) throw new Error(`Invalid base build for tip release: ${baseBuild}`);
  const base = Number.parseInt(baseBuild, 10);
  if (appcastXml === undefined) {
    const first = experimental ? base + 1 : base;
    if (first > 2_147_483_647) throw new Error("Tip build allocation exceeded the Apple client Int32 limit.");
    return String(first);
  }
  const versions = [...appcastXml.matchAll(/<(?:[A-Za-z_][\w.-]*:)?version\b[^>]*>\s*([^<]+?)\s*<\//g)]
    .map((match) => match[1]?.trim() ?? "")
    .filter(Boolean);
  if (!versions.length) throw new Error("Unable to allocate a build because the tip appcast has no versions.");

  const parsed = versions.map((version) => {
    if (!/^\d+$/.test(version)) throw new Error(`Cannot safely allocate after unsupported tip build version: ${version}`);
    return Number.parseInt(version, 10);
  });
  const latest = Math.max(...parsed);
  const next = experimental ? Math.max(base + 1, latest + 1) : Math.max(base, latest + 1);
  if (next > 2_147_483_647) throw new Error("Tip build allocation exceeded the Apple client Int32 limit.");
  return String(next);
}

export async function firstVacantTipBuild(
  candidate: string,
  exists: (build: string) => Promise<boolean>,
): Promise<string> {
  let build = Number.parseInt(candidate, 10);
  if (!Number.isSafeInteger(build) || build < 1 || build > 2_147_483_647) {
    throw new Error(`Invalid candidate tip build: ${candidate}`);
  }
  for (let checked = 0; checked < 100 && build <= 2_147_483_647; checked++, build++) {
    if (!await exists(String(build))) return String(build);
  }
  throw new Error("Unable to allocate an unoccupied tip DMG build in the next 100 numbers.");
}

export function safeResumeTask(taskId: string, operation: "release" | "rollback" | "drop-build"): string {
  if (operation !== "release") return taskId === "preflight" ? "preflight" : "fetch-appcast";
  if (["upload-dmg", "verify-dmg", "gen-appcast", "validate-appcast", "upload-appcast", "github"].includes(taskId)) {
    return "post-check";
  }
  return taskId;
}

function lastHttpHeader(path: string, name: string): string {
  if (!existsSync(path)) return "";
  const prefix = `${name.toLowerCase()}:`;
  let value = "";
  for (const line of readFileSync(path, "utf8").split(/\r?\n/)) {
    if (line.toLowerCase().startsWith(prefix)) value = line.slice(prefix.length).trim();
  }
  return value;
}

function fetchExistingAppcast(ctx: ReleaseContext, ui: Ui): AppcastFetchDecision {
  const result = spawnSync({
    cmd: ["curl", "-sS", "-L", "-D", ctx.appcastHeadersPath, "-o", ctx.appcastPath, "-w", "%{http_code}", ctx.appcastUrl],
    stdout: "pipe",
    stderr: "pipe",
  });
  const status = Number.parseInt(new TextDecoder().decode(result.stdout).trim(), 10) || 0;
  const decision = decideAppcastFetch(result.exitCode, status, ctx.createNewAppcast);
  if (decision === "create-new") {
    ctx.appcastExpectedEtag = "";
    ctx.appcastExpectAbsent = true;
    try {
      rmSync(ctx.appcastPath, { force: true });
    } catch {
      // A 404 normally leaves no output file.
    }
    ui.info(`Confirmed ${ctx.appcastUrl} is absent (HTTP 404); creating the first feed because --create-new-appcast was passed.`);
  } else {
    ctx.appcastExpectedEtag = lastHttpHeader(ctx.appcastHeadersPath, "etag");
    ctx.appcastExpectAbsent = false;
    if (!ctx.appcastExpectedEtag) {
      throw new Error(`Existing appcast response did not include an ETag. Refusing an unconditional update of ${ctx.appcastUrl}.`);
    }
    ui.detail("Existing appcast", ctx.appcastUrl);
  }
  return decision;
}


function git(rootDir: string, args: string[]): string {
  const res = spawnSync({ cmd: ["git", "-C", rootDir, ...args], stdout: "pipe", stderr: "pipe" });
  if (res.exitCode !== 0) return "";
  return new TextDecoder().decode(res.stdout).trim();
}

function gitLines(rootDir: string, args: string[]): string[] {
  const out = git(rootDir, args);
  return out ? out.split("\n").map((line) => line.trim()).filter(Boolean) : [];
}

function defaultAppcastUrl(ctx: ReleaseContext): string {
  if (ctx.appcastUrl) return ctx.appcastUrl;
  if (ctx.baseUrl) return `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
  const publicBaseUrl = process.env.PUBLIC_RELEASES_R2_PUBLIC_BASE_URL?.trim();
  const baseUrl = publicBaseUrl ? trimTrailingSlash(publicBaseUrl) : "https://public-assets.inline.chat";
  return `${baseUrl}/mac/${ctx.channel}/appcast.xml`;
}

function verifyBuiltAppMetadata(ctx: ReleaseContext, ui: Ui): BuiltAppMetadata {
  const metadata = readBuiltAppMetadata(ctx.appPath);
  const expectedBuild = ctx.artifactBuild || ctx.sourceBuild;
  const expectedRevision = ctx.experimentalTip
    ? `experimental-${ctx.sourceSnapshot.slice(0, 12)}`
    : ctx.sourceCommitShort;
  const expectedFeedUrl = defaultAppcastUrl(ctx);
  const mismatches: string[] = [];

  if (!expectedBuild) mismatches.push("Unable to compute expected CFBundleVersion.");
  else if (metadata.buildNumber !== expectedBuild) {
    mismatches.push(`CFBundleVersion is ${metadata.buildNumber}, expected ${expectedBuild}.`);
  }

  if (!expectedRevision) mismatches.push("Unable to compute expected InlineCommit revision.");
  else if (metadata.commit !== expectedRevision) {
    mismatches.push(`InlineCommit is ${metadata.commit}, expected ${expectedRevision}.`);
  }

  if (metadata.feedUrl !== expectedFeedUrl) {
    mismatches.push(`SUFeedURL is ${metadata.feedUrl}, expected ${expectedFeedUrl}.`);
  }

  if (mismatches.length) {
    throw new Error(`Built app metadata mismatch in ${metadata.infoPlist}:\n- ${mismatches.join("\n- ")}`);
  }

  ctx.buildNumber = metadata.buildNumber;
  ctx.version = metadata.version;
  ctx.commit = metadata.commit;
  ctx.commitLong = ctx.experimentalTip ? "" : ctx.sourceCommit;
  ctx.appcastUrl = expectedFeedUrl;
  ctx.minimumSystemVersion = metadata.minimumSystemVersion;
  ui.info(`Verified app metadata: build ${ctx.buildNumber}, minimum macOS ${ctx.minimumSystemVersion}, ${ctx.experimentalTip ? "snapshot revision" : "commit"} ${ctx.commit}, feed ${ctx.appcastUrl}`);
  return metadata;
}

function verifyArtifactIdentity(ctx: ReleaseContext, ui: Ui): BuiltAppMetadata {
  const appMetadata = verifyBuiltAppMetadata(ctx, ui);
  const dmgMetadata = readDmgAppMetadata(ctx.dmgPath);
  const mismatches = metadataMismatches(appMetadata, dmgMetadata);
  if (mismatches.length) {
    throw new Error(`DMG app does not match ${ctx.appPath}:\n- ${mismatches.join("\n- ")}`);
  }
  const stat = Bun.file(ctx.dmgPath);
  ctx.dmgSize = stat.size;
  ctx.dmgSha256 = sha256File(ctx.dmgPath);
  if (publicMutationEnabled(ctx)) {
    if (!existsSync(ctx.provenancePath)) {
      throw new Error(`Artifact provenance not found at ${ctx.provenancePath}. Resume from build; public steps cannot publish an unbound artifact.`);
    }
    const provenance = JSON.parse(readFileSync(ctx.provenancePath, "utf8")) as ArtifactProvenance;
    const executableSha256 = sha256File(resolve(ctx.appPath, "Contents/MacOS/Inline"));
    const sourceMismatches = ctx.experimentalTip
      ? [
          provenance.schemaVersion === 2 ? "" : `schemaVersion ${provenance.schemaVersion}`,
          provenance.sourceState === "experimental-tip" ? "" : `sourceState ${provenance.sourceState}`,
          provenance.sourceSnapshotSha256 === ctx.sourceSnapshot ? "" : `sourceSnapshotSha256 ${provenance.sourceSnapshotSha256}`,
          provenance.buildNumber === ctx.artifactBuild ? "" : `buildNumber ${provenance.buildNumber}`,
          provenance.revision === `experimental-${ctx.sourceSnapshot.slice(0, 12)}` ? "" : `revision ${provenance.revision}`,
        ]
      : [
          provenance.schemaVersion === 1 ? "" : `schemaVersion ${provenance.schemaVersion}`,
          provenance.sourceClean ? "" : "source was dirty",
          provenance.sourceCommit === ctx.sourceCommit ? "" : `sourceCommit ${provenance.sourceCommit}`,
          provenance.sourceBuild === ctx.sourceBuild ? "" : `sourceBuild ${provenance.sourceBuild}`,
          (provenance.buildNumber ?? provenance.sourceBuild) === (ctx.artifactBuild || ctx.sourceBuild)
            ? ""
            : `buildNumber ${provenance.buildNumber ?? provenance.sourceBuild}`,
        ];
    const provenanceMismatches = [
      ...sourceMismatches,
      provenance.appExecutableSha256 === executableSha256 ? "" : `app executable sha256 ${provenance.appExecutableSha256}`,
      provenance.dmgSize === ctx.dmgSize ? "" : `DMG size ${provenance.dmgSize}`,
      provenance.dmgSha256 === ctx.dmgSha256 ? "" : `DMG sha256 ${provenance.dmgSha256}`,
    ].filter(Boolean);
    if (provenanceMismatches.length) {
      throw new Error(`Artifact provenance mismatch in ${ctx.provenancePath}:\n- ${provenanceMismatches.join("\n- ")}`);
    }
  }
  ui.detail("Artifact identity", `build ${appMetadata.buildNumber}, ${ctx.dmgSize} bytes, sha256 ${ctx.dmgSha256}`);
  return appMetadata;
}

function assertFrozenSource(ctx: ReleaseContext): void {
  if (ctx.experimentalTip) {
    if (!ctx.sourceSnapshot) throw new Error("Experimental tip source snapshot was not initialized.");
    if (!ctx.sourceRoot || !ctx.sourceManifestPath) {
      throw new Error("Experimental tip staged source was not initialized.");
    }
    const currentSnapshot = macosSourceSnapshotSha256ForPaths(
      ctx.sourceRoot,
      macosSourceSnapshotPathsFromManifest(ctx.sourceManifestPath),
    );
    if (currentSnapshot !== ctx.sourceSnapshot) {
      throw new Error(`Staged macOS source changed during experimental tip release. Frozen snapshot ${ctx.sourceSnapshot}; current ${currentSnapshot}.`);
    }
    return;
  }
  const currentCommit = git(ctx.rootDir, ["rev-parse", "HEAD"]);
  const currentBuild = git(ctx.rootDir, ["rev-list", "--count", "HEAD"]);
  if (currentCommit !== ctx.sourceCommit || currentBuild !== ctx.sourceBuild) {
    throw new Error(`Source changed during release. Frozen ${ctx.sourceCommit} (build ${ctx.sourceBuild}); current ${currentCommit || "unknown"} (build ${currentBuild || "unknown"}).`);
  }
}

function assertNightlyMainStillSelected(ctx: ReleaseContext): void {
  const expected = process.env.INLINE_NIGHTLY_MAIN_SHA;
  if (!expected) return;
  if (ctx.channel !== "tip" || ctx.experimentalTip || ctx.sourceCommit !== expected) {
    throw new Error("Nightly release source does not match the selected green main commit.");
  }
  const current = git(ctx.rootDir, ["ls-remote", "origin", "refs/heads/main"]).split(/\s+/)[0];
  if (current !== expected) {
    throw new Error(`main advanced during the nightly release: selected ${expected}, current ${current || "unavailable"}.`);
  }
  const qualification = spawnSync({
    cmd: ["python3", resolve(ctx.rootDir, "scripts/ci/nightly-tip-gate.py"), "qualify"],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (qualification.exitCode !== 0) {
    throw new Error("The selected main commit no longer has green CI; refusing to publish the nightly release.");
  }
}

function writeReleaseHistory(ctx: ReleaseContext, action: "release" | "rollback" | "drop-build", ui: Ui) {
  const build = ctx.buildNumber || ctx.rollbackSelectedBuild || ctx.pruneLatestBuild || ctx.dropBuild || "unknown";
  const path = resolve(ctx.historyDir, `${nowIsoCompact()}-${ctx.channel}-${action}-${build}.json`);
  const payload = {
    schemaVersion: 1,
    action,
    createdAt: new Date().toISOString(),
    channel: ctx.channel,
    buildNumber: ctx.buildNumber || undefined,
    version: ctx.version || undefined,
    commit: ctx.experimentalTip ? undefined : ctx.commit || undefined,
    commitLong: ctx.experimentalTip ? undefined : ctx.commitLong || undefined,
    sourceSnapshotSha256: ctx.experimentalTip ? ctx.sourceSnapshot : undefined,
    dmgUrl: ctx.dmgUrl || undefined,
    appcastUrl: ctx.appcastUrl || undefined,
    minimumSystemVersion: ctx.minimumSystemVersion || undefined,
    releaseTag: ctx.releaseTag || undefined,
    appPath: ctx.appPath,
    dmgPath: ctx.dmgPath,
    provenancePath: ctx.provenancePath,
    derivedData: ctx.derivedData,
    sourceState: ctx.experimentalTip
      ? "experimental-tip"
      : ctx.allowDirty && !publicMutationEnabled(ctx)
        ? "local-dirty-allowed"
        : "clean",
    dmgSize: ctx.dmgSize || undefined,
    dmgSha256: ctx.dmgSha256 || undefined,
    rollback: ctx.rollback
      ? {
          selectedBuild: ctx.rollbackSelectedBuild,
          selectedUrl: ctx.rollbackSelectedUrl,
          removedBuilds: ctx.rollbackRemovedBuilds,
        }
      : undefined,
    appcastPrune: ctx.dropBuild
      ? {
          droppedBuild: ctx.pruneDroppedBuild,
          droppedUrl: ctx.pruneDroppedUrl,
          latestBuild: ctx.pruneLatestBuild,
          latestUrl: ctx.pruneLatestUrl,
        }
      : undefined,
  };

  mkdirSync(ctx.historyDir, { recursive: true });
  writeFileSync(path, `${JSON.stringify(payload, null, 2)}\n`);
  ui.info(`Wrote release history: ${path}`);
}

function sleep(ms: number): Promise<void> {
  return new Promise((r) => setTimeout(r, ms));
}

async function promptPickChannel(): Promise<ReleaseChannel> {
  const rl = createInterface({ input: process.stdin, output: process.stdout });
  const ask = (q: string) => new Promise<string>((res) => rl.question(q, res));
  try {
    // Require an explicit interaction when the operator didn't pass --channel.
    // Enter defaults to beta (safer default for local runs).
    // We still show the prompt so the operator is aware of the selection.
    while (true) {
      const answer = (await ask("Select channel: [1] stable  [2] beta (default)  [3] tip  > ")).trim().toLowerCase();
      if (!answer || answer === "2" || answer === "beta" || answer === "b") return "beta";
      if (answer === "1" || answer === "stable" || answer === "s") return "stable";
      if (answer === "3" || answer === "tip" || answer === "t") return "tip";
      console.log("Please enter 1/stable, 2/beta, or 3/tip.");
    }
  } finally {
    rl.close();
  }
}

function ansiStrip(s: string): string {
  const escape = String.fromCharCode(27);
  return s.replace(new RegExp(`${escape}\\[[0-9;]*m`, "g"), "");
}

const color = {
  reset: "\x1b[0m",
  bold: "\x1b[1m",
  red: "\x1b[31m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  blue: "\x1b[34m",
  gray: "\x1b[90m",
};

class Ui {
  private currentTaskId = "";
  private tasks: Array<{ id: string; title: string; status: TaskStatus; note?: string }> = [];
  private taskStartedAt = new Map<string, number>();
  private logPath = "";
  private logWriteFailed = false;

  setLogPath(logPath: string) {
    this.logPath = logPath;
    this.logWriteFailed = false;
    writeFileSync(
      this.logPath,
      [`Inline macOS Release`, `Started: ${new Date().toISOString()}`, ``, ``].join("\n"),
    );
  }

  getLogPath(): string {
    return this.logPath;
  }

  setHintLine(hint: string) {
    console.log(`${color.bold}Inline macOS Release${color.reset}`);
    console.log(`${color.gray}${hint}${color.reset}`);
    this.appendLogLine(hint);
  }

  showLogFiles(files: Array<{ label: string; path: string }>) {
    console.log(`${color.gray}Detailed logs:${color.reset}`);
    for (const file of files) {
      console.log(`${color.gray}  ${file.label}: ${file.path}${color.reset}`);
      this.appendLogLine(`Log (${file.label}): ${file.path}`);
    }
    console.log("");
  }

  init(tasks: Task[]) {
    this.tasks = tasks.map((t) => ({
      id: t.id,
      title: t.title,
      status: t.enabled ? "pending" : "skipped",
      note: !t.enabled ? t.skipReason : undefined,
    }));
    this.appendLogLine(`Pipeline: ${this.tasks.map((task) => `${task.id}=${task.status}`).join(", ")}`);
  }

  setRunning(taskId: string) {
    this.currentTaskId = taskId;
    this.taskStartedAt.set(taskId, Date.now());
    this.appendLogLine(`==> ${this.taskLabel(taskId)}`);
    this.setStatus(taskId, "running");
    console.log(`${color.blue}→${color.reset} ${this.taskLabel(taskId)}`);
  }

  setSkipped(taskId: string, reason?: string) {
    this.appendLogLine(`-- skipped ${this.taskLabel(taskId)}${reason ? ` (${reason})` : ""}`);
    this.setStatus(taskId, "skipped", reason);
    console.log(`${color.gray}– ${this.taskLabel(taskId)}${reason ? ` (${reason})` : ""}${color.reset}`);
    if (this.currentTaskId === taskId) this.currentTaskId = "";
  }

  setSuccess(taskId: string, note?: string) {
    this.appendLogLine(`-- ok ${this.taskLabel(taskId)}${note ? ` (${note})` : ""}`);
    this.setStatus(taskId, "success", note);
    const suffix = [this.elapsedSuffix(taskId), note].filter(Boolean).join(", ");
    console.log(`${color.green}✓${color.reset} ${this.taskLabel(taskId)}${suffix ? ` ${color.gray}(${suffix})${color.reset}` : ""}`);
    if (this.currentTaskId === taskId) this.currentTaskId = "";
  }

  setFailed(taskId: string, message: string) {
    this.appendLogLine(`-- failed ${this.taskLabel(taskId)}: ${message}`);
    this.setStatus(taskId, "failed");
    const elapsed = this.elapsedSuffix(taskId);
    console.error(`${color.red}✗ ${this.taskLabel(taskId)}${elapsed ? ` (${elapsed})` : ""}${color.reset}`);
    console.error(`${color.red}  ${message}${color.reset}`);
    if (this.currentTaskId === taskId) this.currentTaskId = "";
  }

  log(line: string) {
    const cleaned = ansiStrip(line).replace(/\r/g, "").trimEnd();
    if (!cleaned) return;
    this.appendLogLine(cleaned);
  }

  info(line: string) {
    const cleaned = ansiStrip(line).replace(/\r/g, "").trimEnd();
    if (!cleaned) return;
    this.appendLogLine(cleaned);
    console.log(`  ${cleaned}`);
  }

  error(line: string) {
    const cleaned = ansiStrip(line).replace(/\r/g, "").trimEnd();
    if (!cleaned) return;
    this.appendLogLine(cleaned);
    console.error(`${color.red}  ${cleaned}${color.reset}`);
  }

  detail(label: string, value: string) {
    const line = `${label}: ${value}`;
    this.appendLogLine(`-- ${line}`);
    console.log(`  ${color.gray}${label}:${color.reset} ${value}`);
  }

  private appendLogLine(line: string) {
    if (!this.logPath || this.logWriteFailed) return;
    try {
      appendFileSync(this.logPath, `${line}\n`);
    } catch (err) {
      this.logWriteFailed = true;
      const msg = err instanceof Error ? err.message : String(err);
      console.error(`Could not write release log ${this.logPath}: ${msg}`);
    }
  }

  private taskLabel(taskId: string): string {
    const task = this.tasks.find((t) => t.id === taskId);
    return task ? `${task.id}: ${task.title}` : taskId;
  }

  private setStatus(taskId: string, status: TaskStatus, note?: string) {
    const t = this.tasks.find((x) => x.id === taskId);
    if (t) {
      t.status = status;
      if (note) t.note = note;
    }
  }

  private elapsedSuffix(taskId: string): string {
    const startedAt = this.taskStartedAt.get(taskId);
    return startedAt ? formatElapsed(Date.now() - startedAt) : "";
  }

  getCurrentTaskId(): string {
    return this.currentTaskId;
  }
}

function formatElapsed(durationMs: number): string {
  const totalSeconds = Math.max(0, Math.round(durationMs / 1000));
  const minutes = Math.floor(totalSeconds / 60);
  const seconds = totalSeconds % 60;
  return minutes > 0 ? `${minutes}m ${seconds}s` : `${seconds}s`;
}

function readConfiguredMarketingVersion(rootDir: string, ui: Ui): string {
  if (!commandExists("xcodebuild")) return "";
  const result = spawnSync({
    cmd: [
      "xcodebuild",
      "-project",
      resolve(rootDir, "apple/Inline.xcodeproj"),
      "-scheme",
      "Inline (macOS)",
      "-configuration",
      "Release",
      "-showBuildSettings",
    ],
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = new TextDecoder().decode(result.stdout);
  const stderr = new TextDecoder().decode(result.stderr);
  for (const line of `${stdout}\n${stderr}`.split("\n")) {
    if (line.trim()) ui.log(`[version] ${line}`);
  }
  if (result.exitCode !== 0) return "";
  return stdout.match(/^\s*MARKETING_VERSION = (.+)$/m)?.[1]?.trim() ?? "";
}

async function runStreaming(
  ui: Ui,
  cmd: string[],
  opts: { cwd: string; env?: Record<string, string>; onLine?: (line: string) => void },
): Promise<void> {
  const recentLines: string[] = [];
  let lastErrorLine = "";
  const proc = Bun.spawn(cmd, {
    cwd: opts.cwd,
    env: { ...process.env, ...opts.env },
    stdin: "inherit",
    stdout: "pipe",
    stderr: "pipe",
  });
  activeSubprocess = proc;

  const recordLine = (line: string) => {
    const cleaned = ansiStrip(line).trim();
    recentLines.push(cleaned);
    if (/\berror:/i.test(cleaned)) lastErrorLine = cleaned;
    if (recentLines.length > 200) recentLines.splice(0, recentLines.length - 200);
  };

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
        recordLine(prefix + line);
        ui.log(prefix + line);
        opts.onLine?.(prefix + line);
      }
    }
    if (buf.trim().length) {
      recordLine(prefix + buf);
      ui.log(prefix + buf);
      opts.onLine?.(prefix + buf);
    }
  };

  let exitCode: number;
  try {
    await Promise.all([forward(proc.stdout, ""), forward(proc.stderr, "")]);
    exitCode = await proc.exited;
  } finally {
    if (activeSubprocess === proc) activeSubprocess = undefined;
  }
  if (exitCode !== 0) {
    const usefulLine = lastErrorLine || [...recentLines]
      .reverse()
      .find((line) => !line.endsWith(":") && line !== "** BUILD FAILED **" && /(error|failed|requires|not found|does not|invalid|timed out|denied|read.only|can.?t save)/i.test(line));
    throw new Error(
      `Command failed (${exitCode}): ${cmd.map((c) => (c.includes(" ") ? JSON.stringify(c) : c)).join(" ")}${usefulLine ? `\nLast output: ${usefulLine}` : ""}`,
    );
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

function publicMutationEnabled(opts: ReleaseOptions): boolean {
  return taskEnabled(opts, "upload-dmg") || taskEnabled(opts, "upload-appcast")
    || Boolean(opts.releaseTag && !opts.skipGithubRelease && taskEnabled(opts, "github"));
}

export function releaseIntegrityGateErrors(
  opts: Pick<ReleaseOptions, "skip" | "releaseTag" | "skipGithubRelease">,
): string[] {
  const uploadDmg = !opts.skip.has("upload-dmg");
  const uploadAppcast = !opts.skip.has("upload-appcast");
  const github = Boolean(opts.releaseTag && !opts.skipGithubRelease && !opts.skip.has("github"));
  const errors: string[] = [];
  if ((uploadDmg || uploadAppcast || github) && opts.skip.has("post-check")) {
    errors.push("post-check cannot be skipped while publishing a DMG or appcast");
  }
  if ((uploadDmg || uploadAppcast) && opts.skip.has("verify-dmg")) {
    errors.push("verify-dmg cannot be skipped while publishing to R2");
  }
  if (uploadAppcast && opts.skip.has("gen-appcast")) {
    errors.push("gen-appcast cannot be skipped while uploading appcast.xml");
  }
  if (uploadAppcast && opts.skip.has("validate-appcast")) {
    errors.push("validate-appcast cannot be skipped while uploading appcast.xml");
  }
  return errors;
}

function buildWillRun(opts: ReleaseOptions): boolean {
  return taskEnabled(opts, "build") && (!opts.fromTask || opts.fromTask === "preflight" || opts.fromTask === "build");
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
  const quote = (arg: string) => (/^[A-Za-z0-9_./:=+-]+$/.test(arg) ? arg : JSON.stringify(arg));
  const lines = [args.slice(0, 3).map(quote).join(" ")];
  for (let index = 3; index < args.length; index++) {
    const arg = args[index];
    const next = args[index + 1];
    if (arg.startsWith("--") && next && !next.startsWith("--")) {
      lines.push(`${quote(arg)} ${quote(next)}`);
      index++;
    } else {
      lines.push(quote(arg));
    }
  }
  return lines.join(" \\\n  ");
}

function defaultReleaseTag(channel: ReleaseChannel): string {
  switch (channel) {
    case "stable":
      return "stable";
    case "beta":
      return "beta";
    case "tip":
      return "tip";
  }
}

function validateReleaseTag(channel: ReleaseChannel, releaseTag: string): void {
  const reservedTags: ReleaseChannel[] = ["stable", "beta", "tip"];
  if (reservedTags.some((reservedTag) => reservedTag === releaseTag) && releaseTag !== channel) {
    die(`Release tag ${releaseTag} belongs to the ${releaseTag} channel, not ${channel}.`);
  }
}

function buildResumeCommand(ctx: ReleaseContext, fromTask: string): string {
  const operation = ctx.rollback ? "rollback" : ctx.dropBuild ? "drop-build" : "release";
  const safeFromTask = safeResumeTask(fromTask, operation);
  const args = ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-app.ts"), "--channel", ctx.channel, "--from", safeFromTask];
  const defaultSparkleDir = resolve(ctx.rootDir, ".action/sparkle", sparkleVersion);
  const defaultTag = ctx.rollback || ctx.dropBuild ? "" : defaultReleaseTag(ctx.channel);
  const concreteSkipIds = [...ctx.skip]
    .filter((id) => !["upload", "appcast", "github"].includes(id))
    .sort();

  if (ctx.rollback) {
    args.push("--rollback");
    if (ctx.rollbackSelectedBuild) args.push("--rollback-to-build", ctx.rollbackSelectedBuild);
    else if (ctx.rollbackToBuild) args.push("--rollback-to-build", ctx.rollbackToBuild);
    else if (ctx.rollbackStepsBack !== 1) args.push("--rollback-steps-back", String(ctx.rollbackStepsBack));
  } else if (ctx.dropBuild) {
    args.push("--drop-build", ctx.dropBuild);
  } else if (ctx.releaseTag && ctx.releaseTag !== defaultTag) {
    args.push("--release-tag", ctx.releaseTag);
  }

  if (ctx.skipGithubRelease) args.push("--skip-github-release");
  if (concreteSkipIds.length) args.push("--skip", concreteSkipIds.join(","));
  if (ctx.allowDirty) args.push("--allow-dirty");
  if (ctx.experimentalTip) args.push("--experimental-tip");
  if (!ctx.rollback && !ctx.dropBuild && !ctx.skip.has("upload-sentry-dsyms")) args.push("--upload-sentry-dsyms");
  if (!ctx.rollback && !ctx.dropBuild) {
    if (ctx.experimentalTip) {
      args.push("--source-snapshot", ctx.sourceSnapshot, "--artifact-build", ctx.artifactBuild);
    } else {
      args.push("--source-commit", ctx.sourceCommit, "--source-build", ctx.sourceBuild);
      if (ctx.channel === "tip") args.push("--artifact-build", ctx.artifactBuild || ctx.sourceBuild);
    }
    args.push("--derived-data", ctx.derivedData, "--app-path", ctx.appPath, "--dmg-path", ctx.dmgPath);
    if (ctx.createNewAppcast) args.push("--create-new-appcast");
  }
  if (ctx.sparkleDir !== defaultSparkleDir) args.push("--sparkle-dir", ctx.sparkleDir);

  return formatCmd(args);
}

async function main() {
  const rootDir = resolve(import.meta.dir, "../..");
  const interactive = Boolean(process.stdin.isTTY && process.stdout.isTTY && process.stderr.isTTY && !process.env.CI);
  const ui = new Ui();

  let keepTempDir = false;
  const parsedRaw = parseArgs(process.argv.slice(2), rootDir);
  if (!parsedRaw.rollback && !parsedRaw.dropBuild) {
    validateSkipIds(parsedRaw.skip);
  }
  const parsed0 = parsedRaw.rollback || parsedRaw.dropBuild ? parsedRaw : computeSkipOptions(parsedRaw);
  let channel = parsed0.channel;
  if (parsed0.experimentalTip && !channel) channel = "tip";
  if (!channel) {
    if (!interactive) {
      channel = "beta";
      console.log("No --channel provided; defaulting to beta.");
    } else {
      channel = await promptPickChannel();
      console.log(`Using channel: ${channel}`);
    }
  }
  const releaseTag = parsed0.rollback || parsed0.dropBuild || parsed0.experimentalTip
    ? ""
    : parsed0.releaseTag || defaultReleaseTag(channel);
  if (releaseTag) validateReleaseTag(channel, releaseTag);
  const operation = parsed0.rollback ? "rollback" : parsed0.dropBuild ? "drop-build" : "release";
  const fromTask = parsed0.fromTask ? safeResumeTask(parsed0.fromTask, operation) : "";
  if (fromTask && fromTask !== parsed0.fromTask) {
    console.log(`Resume requires durable prerequisite ${fromTask}; requested ${parsed0.fromTask}.`);
  }
  const opts: ReleaseOptions = {
    channel,
    derivedData: parsed0.derivedData,
    appPath: parsed0.appPath,
    dmgPath: parsed0.dmgPath,
    sparkleDir: parsed0.sparkleDir,
    releaseTag,
    skipGithubRelease: parsed0.experimentalTip || parsed0.skipGithubRelease || parsed0.skip.has("github"),
    allowDirty: parsed0.allowDirty,
    experimentalTip: parsed0.experimentalTip,
    skip: parsed0.skip,
    fromTask,
    dryRun: parsed0.dryRun,
    rollback: parsed0.rollback,
    rollbackToBuild: parsed0.rollbackToBuild,
    rollbackStepsBack: parsed0.rollbackStepsBack,
    dropBuild: parsed0.dropBuild,
    createNewAppcast: parsed0.createNewAppcast,
    sourceCommit: parsed0.experimentalTip ? "" : parsed0.sourceCommit || git(rootDir, ["rev-parse", "HEAD"]),
    sourceBuild: parsed0.sourceBuild || git(rootDir, ["rev-list", "--count", "HEAD"]),
    sourceSnapshot: parsed0.sourceSnapshot,
    artifactBuild: parsed0.artifactBuild,
  };
  if (!opts.artifactBuild && opts.channel !== "tip") opts.artifactBuild = opts.sourceBuild;
  if (parsed0.artifactBuild && opts.channel !== "tip") {
    die("--artifact-build is only supported for tip releases.");
  }
  if (!opts.rollback && !opts.dropBuild && !opts.experimentalTip && (!/^[0-9a-f]{40}$/.test(opts.sourceCommit) || !/^\d+$/.test(opts.sourceBuild))) {
    die("Unable to freeze release source commit/build.");
  }
  if (!opts.rollback && !opts.dropBuild && opts.experimentalTip && !/^\d+$/.test(opts.sourceBuild)) {
    die("Unable to compute the base build for an experimental tip release.");
  }
  if (!opts.rollback && !opts.dropBuild) {
    const integrityErrors = releaseIntegrityGateErrors(opts);
    if (integrityErrors.length) {
      die(`Unsafe release skip combination:\n- ${integrityErrors.join("\n- ")}`);
    }
  }

  // Temp dir is created up-front so we can point to it on failures.
  const tempRoot = resolve(rootDir, "build/macos-release-tmp");
  mkdirSync(tempRoot, { recursive: true });
  const nonce = Math.random().toString(16).slice(2, 8);
  const tempDir = resolve(tempRoot, `release-app.${nowIsoCompact()}.${nonce}`);
  mkdirSync(tempDir, { recursive: true });

  const ctx: ReleaseContext = {
    rootDir,
    sourceRoot: "",
    sourceManifestPath: resolve(tempDir, "source-paths.nul"),
    tempDir,
    signingKeyPath: resolve(tempDir, "signing.key"),
    signUpdatePath: resolve(tempDir, "sign_update.txt"),
    appcastPath: resolve(tempDir, "appcast.xml"),
    appcastHeadersPath: resolve(tempDir, "appcast.headers"),
    appcastOutputPath: resolve(tempDir, "appcast_new.xml"),
    rollbackMetaPath: resolve(tempDir, "rollback_meta.json"),
    pruneMetaPath: resolve(tempDir, "prune_meta.json"),
    historyDir: resolve(rootDir, "build/macos-release-history"),
    buildNumber: "",
    version: "",
    commit: "",
    commitLong: "",
    baseUrl: "",
    dmgUrl: "",
    appcastUrl: "",
    minimumSystemVersion: "",
    rollbackSelectedBuild: "",
    rollbackSelectedUrl: "",
    rollbackRemovedBuilds: [],
    pruneDroppedBuild: "",
    pruneDroppedUrl: "",
    pruneLatestBuild: "",
    pruneLatestUrl: "",
    sourceCommitShort: opts.experimentalTip ? "" : git(rootDir, ["rev-parse", "--short", opts.sourceCommit]),
    dmgSize: 0,
    dmgSha256: "",
    provenancePath: resolve(dirname(opts.dmgPath), "release-provenance.json"),
    appcastExpectedEtag: "",
    appcastExpectAbsent: false,
    channelLockToken: "",
    ...opts,
  };

  const logRoot = resolve(rootDir, "build/macos-release-logs");
  mkdirSync(logRoot, { recursive: true });
  const releaseLogPath = resolve(logRoot, `${basename(ctx.tempDir)}.log`);
  ui.setLogPath(releaseLogPath);

  ui.setHintLine(
    opts.rollback
      ? `Rollback  Channel: ${opts.channel}${opts.rollbackToBuild ? `  Build: ${opts.rollbackToBuild}` : `  Steps back: ${opts.rollbackStepsBack}`}${opts.fromTask ? `  From: ${opts.fromTask}` : ""}${opts.dryRun ? "  Dry run" : ""}`
      : opts.dropBuild
        ? `Drop build  Channel: ${opts.channel}  Build: ${opts.dropBuild}${opts.dryRun ? "  Dry run" : ""}`
        : `Release  Channel: ${opts.channel}${opts.releaseTag ? `  Tag: ${opts.releaseTag}` : ""}${opts.experimentalTip ? "  Experimental snapshot" : ""}${opts.fromTask ? `  From: ${opts.fromTask}` : ""}${opts.allowDirty ? "  Allow dirty" : ""}${opts.dryRun ? "  Dry run" : ""}`,
  );
  const logFiles = [{ label: "release", path: releaseLogPath }];
  if (!opts.rollback && !opts.dropBuild) {
    logFiles.push(
      { label: "build", path: resolve(dirname(ctx.dmgPath), "build-direct.log") },
      { label: "Xcode", path: resolve(dirname(ctx.dmgPath), "xcodebuild.log") },
    );
  }
  ui.showLogFiles(logFiles);

  const tasks: Task[] = [];

  const runPreflight: Task["run"] = async (ctx, ui) => {
    if (!ctx.rollback && !ctx.dropBuild) {
      if (ctx.channel === "tip" && buildWillRun(ctx) && !ctx.artifactBuild) {
        ctx.appcastUrl = defaultAppcastUrl(ctx);
        const fetchDecision = fetchExistingAppcast(ctx, ui);
        const appcastXml = appcastXmlForBuildAllocation(
          fetchDecision,
          () => readFileSync(ctx.appcastPath, "utf8"),
        );
        const candidate = nextTipArtifactBuild(ctx.sourceBuild, appcastXml, ctx.experimentalTip);
        if (ctx.dryRun || !taskEnabled(ctx, "upload-dmg")) {
          ctx.artifactBuild = candidate;
        } else {
          const { r2, prefix } = getR2Context();
          ctx.artifactBuild = await firstVacantTipBuild(candidate, (build) =>
            r2.exists(`${prefix}/tip/${build}/Inline.dmg`));
        }
      }
      if (ctx.experimentalTip && buildWillRun(ctx)) {
        if (!ctx.artifactBuild) {
          throw new Error("Experimental tip artifact build was not allocated.");
        }
        if (ctx.dryRun) {
          const currentSnapshot = macosSourceSnapshotSha256(ctx.rootDir);
          if (ctx.sourceSnapshot && ctx.sourceSnapshot !== currentSnapshot) {
            throw new Error(`macOS source no longer matches the requested experimental snapshot ${ctx.sourceSnapshot}; current ${currentSnapshot}.`);
          }
          ctx.sourceSnapshot = currentSnapshot;
        } else {
          ctx.sourceRoot = resolve(ctx.tempDir, "source");
          const staged = stageMacosSourceSnapshot(ctx.rootDir, ctx.sourceRoot, ctx.sourceManifestPath);
          if (ctx.sourceSnapshot && ctx.sourceSnapshot !== staged.sha256) {
            throw new Error(`Staged macOS source does not match the requested experimental snapshot ${ctx.sourceSnapshot}; current ${staged.sha256}.`);
          }
          ctx.sourceSnapshot = staged.sha256;
          ui.detail("Staged source", `${staged.fileCount} files in ${ctx.sourceRoot}`);
        }
      }
      const configuredVersion = readConfiguredMarketingVersion(ctx.sourceRoot || ctx.rootDir, ui);
      const plannedBuild = ctx.artifactBuild || ctx.sourceBuild;
      const plannedRevision = ctx.experimentalTip ? "" : ctx.sourceCommitShort;
      if (configuredVersion) ctx.version = configuredVersion;
      ui.detail("Version", `${configuredVersion || "unknown"}${plannedBuild ? ` (build ${plannedBuild})` : ""}`);
      ui.detail("Tag", ctx.releaseTag || "none");
      ui.detail("Channel", ctx.channel);
      if (plannedRevision) ui.detail(ctx.experimentalTip ? "Source snapshot" : "Commit", plannedRevision);
      ui.detail("DerivedData", `${existsSync(ctx.derivedData) ? "reusing" : "creating"} ${ctx.derivedData}`);
    }
    const missing: string[] = [];
    for (const c of ["bun", "python3", "curl", "git", "shasum"]) {
      if (!commandExists(c)) missing.push(c);
    }
    if (ctx.rollback || ctx.dropBuild) {
      // Appcast-only operations need feed editing + upload tooling.
    } else if (buildWillRun(opts)) {
      for (const c of ["xcodebuild", "xcrun", "codesign", "security", "create-dmg", "rsync", "unzip", "perl", "lipo"]) {
        if (!commandExists(c)) missing.push(c);
      }
    }
    if (!ctx.rollback && !ctx.dropBuild && taskEnabled(opts, "upload-sentry-dsyms")) {
      if (!commandExists("ditto")) {
        ui.info("Warning: upload-sentry-dsyms is best-effort and will fail because `ditto` is missing.");
      }
      if (!process.env.SENTRY_AUTH_TOKEN && !commandExists("sentry")) {
        ui.info("Warning: upload-sentry-dsyms is best-effort and needs SENTRY_AUTH_TOKEN or the authenticated modern `sentry` CLI.");
      }
    }
    if (!ctx.rollback && !ctx.dropBuild && taskEnabled(opts, "post-check")) {
      for (const c of ["hdiutil", "spctl", "lipo"]) {
        if (!commandExists(c)) missing.push(c);
      }
    }
    if (!ctx.rollback && !ctx.dropBuild && !opts.skipGithubRelease && opts.releaseTag) {
      if (!commandExists("gh")) missing.push("gh");
    }
    if (!ctx.rollback && !ctx.dropBuild) {
      if (buildWillRun(ctx)) {
        if (!ctx.experimentalTip) assertFrozenSource(ctx);
        const dirty = macosReleaseSourceStatusLines(ctx.rootDir);
        const willPublish = publicMutationEnabled(ctx);
        if (dirty.length && willPublish && !ctx.experimentalTip) {
          const sample = dirty.slice(0, 12).join("\n");
          const extra = dirty.length > 12 ? `\n... and ${dirty.length - 12} more` : "";
          const message = `Public macOS releases require clean frozen release inputs on every channel. Apple or macOS release-tool changes cannot upload a DMG/appcast or move a GitHub tag.\n${sample}${extra}`;
          if (ctx.dryRun) ui.info(`Warning: ${message}`);
          else throw new Error(message);
        } else if (dirty.length && !ctx.allowDirty && !ctx.experimentalTip) {
          const message = "Dirty macOS release inputs are allowed only for an explicitly local, non-publishing run with --allow-dirty and all public mutation steps skipped.";
          if (ctx.dryRun) ui.info(`Warning: ${message}`);
          else throw new Error(message);
        } else if (dirty.length && ctx.experimentalTip) {
          ui.info("Warning: publishing a dirty macOS source snapshot to the experimental tip feed; GitHub is disabled.");
        } else if (dirty.length) {
          ui.info("Warning: local non-publishing build from dirty source because --allow-dirty was passed.");
        }
      }
    }
    if (missing.length) {
      if (ctx.dryRun) {
        ui.info(`Warning: missing command(s): ${missing.join(", ")}`);
        return;
      }
      throw new Error(`Missing required command(s): ${missing.join(", ")}`);
    }
    if (!ctx.rollback && !ctx.dropBuild) {
      if (buildWillRun(opts)) {
        const expectedAppPath = resolve(ctx.derivedData, "Build/Products/Release/Inline.app");
        if (ctx.appPath !== expectedAppPath) {
          throw new Error(`The build step requires --app-path ${expectedAppPath}; custom app paths are only valid when resuming after build.`);
        }
      }
      const activeOwner = activeXcodebuildForDerivedData(ctx.derivedData);
      if (activeOwner) {
        const message = `DerivedData is already in use by another Xcode build: ${ctx.derivedData}\n${activeOwner}`;
        if (ctx.dryRun) ui.info(`Warning: ${message}`);
        else throw new Error(message);
      }
    }
    ui.detail("Tools", "available");
    if (!ctx.rollback && !ctx.dropBuild && buildWillRun(opts)) {
      const sourceRoot = ctx.sourceRoot || ctx.rootDir;
      const command = ["bun", "run", resolve(sourceRoot, "scripts/macos/check-grid-livekit-pin.ts")];
      if (ctx.dryRun) {
        try {
          await runStreaming(ui, command, { cwd: sourceRoot });
        } catch (error) {
          ui.info(`Warning: ${String(error)}`);
        }
      } else {
        await runStreaming(ui, command, { cwd: sourceRoot });
        ui.detail("LiveKit pin", "verified");
      }
    }
    if (!ctx.rollback && !ctx.dropBuild && buildWillRun(opts)) {
      if (ctx.dryRun) {
        ui.info("Would validate notarization credentials with xcrun notarytool history.");
      } else {
        await runStreaming(ui, ["bash", resolve(ctx.rootDir, "scripts/macos/check-notary-credentials.sh")], {
          cwd: ctx.rootDir,
        });
        ui.detail("Notarization credentials", "verified");
      }
    }
    if (!ctx.rollback && !ctx.dropBuild && ctx.experimentalTip && buildWillRun(ctx)) {
      if (!ctx.dryRun) assertFrozenSource(ctx);
      ui.detail("Source snapshot", `experimental-${ctx.sourceSnapshot.slice(0, 12)}`);
    }
  };

  tasks.push({
    id: "preflight",
    title: "Release details and preflight checks",
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
        fetchExistingAppcast(ctx, ui);
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
          ui.log(`curl -I ${ctx.dmgUrl} (attempt ${attempt}/3)`);
          const res = spawnSync({ cmd: ["curl", "-fsI", ctx.dmgUrl], stdout: "pipe", stderr: "pipe" });
          if (res.exitCode === 0) {
            ui.detail("Verified DMG", ctx.dmgUrl);
            return;
          }
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
        ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT, PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
      },
      run: async (ctx, ui) => {
        if (!ctx.buildNumber) {
          throw new Error("Rollback build number missing. prepare-rollback must run first.");
        }
        requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
        requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
        requireEnv("PUBLIC_RELEASES_R2_BUCKET");
        requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
        requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
        await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
          cwd: ctx.rootDir,
          env: {
            UPLOAD_MODE: "appcast",
            CHANNEL: ctx.channel,
            APPCAST_PATH: ctx.appcastOutputPath,
            BUILD_NUMBER: ctx.buildNumber,
            APPCAST_EXPECTED_ETAG: ctx.appcastExpectedEtag,
            APPCAST_EXPECT_ABSENT: ctx.appcastExpectAbsent ? "1" : "0",
            RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken,
          },
        });
        ui.detail("Uploaded appcast", ctx.appcastUrl);
      },
    });
  } else if (opts.dropBuild) {
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
        fetchExistingAppcast(ctx, ui);
      },
    });

    tasks.push({
      id: "prepare-prune",
      title: "Remove build from appcast",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  python3 scripts/macos/prune_appcast.py --appcast <temp>/appcast.xml --output <temp>/appcast_new.xml --metadata-output <temp>/prune_meta.json --drop-build ${ctx.dropBuild}`);
      },
      run: async (ctx, ui) => {
        await runStreaming(
          ui,
          [
            "python3",
            resolve(ctx.rootDir, "scripts/macos/prune_appcast.py"),
            "--appcast",
            ctx.appcastPath,
            "--output",
            ctx.appcastOutputPath,
            "--metadata-output",
            ctx.pruneMetaPath,
            "--drop-build",
            ctx.dropBuild,
          ],
          { cwd: ctx.rootDir },
        );

        const metadata = JSON.parse(await Bun.file(ctx.pruneMetaPath).text()) as PruneMetadata;
        ctx.pruneDroppedBuild = metadata.droppedBuild;
        ctx.pruneDroppedUrl = metadata.droppedUrl;
        ctx.pruneLatestBuild = metadata.latestBuild;
        ctx.pruneLatestUrl = metadata.latestUrl;
        ctx.buildNumber = metadata.latestBuild;
        ctx.dmgUrl = metadata.latestUrl;

        ui.info(`Dropped appcast build: ${ctx.pruneDroppedBuild}`);
        ui.info(`Current latest build remains: ${ctx.pruneLatestBuild}`);
        if (metadata.remainingBuilds.length > 0) {
          ui.info(`Remaining builds: ${metadata.remainingBuilds.join(", ")}`);
        }
      },
    });

    tasks.push({
      id: "validate-appcast",
      title: "Validate pruned appcast",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info("  python3 scripts/macos/validate_appcast.py --appcast <temp>/appcast_new.xml --require-build <latest-build> --require-url <latest-dmg-url>");
      },
      run: async (ctx, ui) => {
        if (!ctx.pruneLatestBuild || !ctx.pruneLatestUrl) {
          throw new Error("Pruned appcast metadata missing. prepare-prune must run first.");
        }
        await runStreaming(
          ui,
          [
            "python3",
            resolve(ctx.rootDir, "scripts/macos/validate_appcast.py"),
            "--appcast",
            ctx.appcastOutputPath,
            "--require-build",
            ctx.pruneLatestBuild,
            "--require-url",
            ctx.pruneLatestUrl,
          ],
          { cwd: ctx.rootDir },
        );
      },
    });

    tasks.push({
      id: "upload-appcast",
      title: "Upload pruned appcast to R2",
      enabled: true,
      dryRun: (ctx, ui) => {
        ui.info("Would run:");
        ui.info(`  UPLOAD_MODE=appcast CHANNEL=${ctx.channel} APPCAST_PATH=<temp>/appcast_new.xml BUILD_NUMBER=<latest-build> bun run scripts/macos/release-direct.ts`);
        ui.info("Requires env:");
        ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT, PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
      },
      run: async (ctx, ui) => {
        if (!ctx.buildNumber) {
          throw new Error("Latest build number missing. prepare-prune must run first.");
        }
        requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
        requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
        requireEnv("PUBLIC_RELEASES_R2_BUCKET");
        requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
        requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
        await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
          cwd: ctx.rootDir,
          env: {
            UPLOAD_MODE: "appcast",
            CHANNEL: ctx.channel,
            APPCAST_PATH: ctx.appcastOutputPath,
            BUILD_NUMBER: ctx.buildNumber,
            APPCAST_EXPECTED_ETAG: ctx.appcastExpectedEtag,
            APPCAST_EXPECT_ABSENT: ctx.appcastExpectAbsent ? "1" : "0",
            RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken,
          },
        });
        ui.detail("Uploaded appcast", ctx.appcastUrl);
      },
    });
  } else {
    tasks.push({
      id: "build",
      title: "Build, sign, and notarize app",
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
        ui.info(`  MACOS_RELEASE_ARCH=${macosReleaseArch}`);
        ui.info("  ENABLE_CODE_COVERAGE=NO");
        ui.info("  DEAD_CODE_STRIPPING=YES");
        ui.info("build-direct.sh strips the release executable before signing.");
        ui.info("build-direct.sh enforces signing/notarization env vars.");
      },
      run: async (ctx, ui) => {
        // Let build-direct.sh enforce its own env requirements. We only pass paths/options through.
        assertFrozenSource(ctx);
        let artifactsShown = false;
        let notarizationStartedAt = 0;
        const showArtifacts = () => {
          if (artifactsShown) return;
          artifactsShown = true;
          ui.detail("Built app", ctx.appPath);
          ui.detail("DMG", ctx.dmgPath);
        };
        await runStreaming(ui, ["bash", resolve(ctx.sourceRoot || ctx.rootDir, "scripts/macos/build-direct.sh")], {
          cwd: ctx.sourceRoot || ctx.rootDir,
          env: {
            CHANNEL: ctx.channel,
            DERIVED_DATA: ctx.derivedData,
            OUTPUT_DIR: dirname(ctx.dmgPath),
            DMG_PATH: ctx.dmgPath,
            SPARKLE_DIR: ctx.sparkleDir,
            MACOS_RELEASE_ARCH: macosReleaseArch,
            EXPECTED_SOURCE_COMMIT: ctx.experimentalTip ? "" : ctx.sourceCommit,
            EXPECTED_SOURCE_BUILD: ctx.experimentalTip ? "" : ctx.sourceBuild,
            EXPECTED_SOURCE_SNAPSHOT: ctx.experimentalTip ? ctx.sourceSnapshot : "",
            SOURCE_SNAPSHOT_MANIFEST: ctx.experimentalTip ? ctx.sourceManifestPath : "",
            BUILD_NUMBER_OVERRIDE: ctx.artifactBuild && ctx.artifactBuild !== ctx.sourceBuild ? ctx.artifactBuild : "",
            INLINE_REVISION_OVERRIDE: ctx.experimentalTip ? `experimental-${ctx.sourceSnapshot.slice(0, 12)}` : "",
            EXPERIMENTAL_TIP: ctx.experimentalTip ? "1" : "0",
            RELEASE_CONFIG_ROOT: ctx.rootDir,
            REQUIRE_CLEAN_SOURCE: publicMutationEnabled(ctx) && !ctx.experimentalTip ? "1" : "0",
            ARTIFACT_PROVENANCE_PATH: ctx.provenancePath,
          },
          onLine: (line) => {
            if (line.includes("** BUILD SUCCEEDED **")) {
              ui.detail("Xcode build", "completed");
            } else if (line.startsWith("Build/sign step complete.")) {
              showArtifacts();
            } else if (line.startsWith("Starting notarization for DMG:")) {
              notarizationStartedAt = Date.now();
              ui.detail("Notarization", `started ${new Date(notarizationStartedAt).toLocaleTimeString()}`);
            } else if (line.startsWith("Built app:")) {
              showArtifacts();
              if (notarizationStartedAt) {
                ui.detail("Notarization", `completed in ${formatElapsed(Date.now() - notarizationStartedAt)}`);
              }
            }
          },
        });
        assertFrozenSource(ctx);
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
        ui.info("  Uses SENTRY_AUTH_TOKEN, or falls back to the authenticated modern `sentry` CLI.");
        ui.info("  The token is kept in process memory and never placed in command arguments.");
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
            APP_PATH: "",
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
      assertNightlyMainStillSelected(ctx);
      // Validate local artifacts.
      if (!existsSync(ctx.appPath)) throw new Error(`App not found at ${ctx.appPath}`);
      if (!existsSync(ctx.dmgPath)) throw new Error(`DMG not found at ${ctx.dmgPath}`);

      // R2 URL context.
      // release-direct.ts will also check these, but validating here gives a clearer error.
      requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
      requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
      requireEnv("PUBLIC_RELEASES_R2_BUCKET");
      requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
      ctx.baseUrl = trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
      ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
      verifyArtifactIdentity(ctx, ui);
      ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;

      await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
        cwd: ctx.rootDir,
        env: {
          UPLOAD_MODE: "dmg",
          CHANNEL: ctx.channel,
          DMG_PATH: ctx.dmgPath,
          BUILD_NUMBER: ctx.buildNumber,
          RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken,
          DMG_EXPECTED_SIZE: String(ctx.dmgSize),
          DMG_EXPECTED_SHA256: ctx.dmgSha256,
        },
      });
      ui.detail("Uploaded DMG", ctx.dmgUrl);
    },
    });

    tasks.push({
      id: "verify-dmg",
    title: "Verify remote DMG bytes",
    enabled: taskEnabled(opts, "verify-dmg"),
    skipReason: taskEnabled(opts, "verify-dmg") ? undefined : "operator requested",
    dryRun: (ctx, ui) => {
      ui.info("Would run:");
      ui.info(`  curl -fSL <PUBLIC_RELEASES_R2_PUBLIC_BASE_URL>/mac/${ctx.channel}/<build>/Inline.dmg -o <temp>/remote-Inline.dmg`);
      ui.info("  Compare the remote file size and SHA-256 with the verified local DMG.");
      ui.info("Requires env:");
      ui.info("  PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
    },
    run: async (ctx, ui) => {
      if (!ctx.dmgUrl) {
        // If upload-dmg was skipped, we still want a consistent URL for verification/appcast.
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
        verifyBuiltAppMetadata(ctx, ui);
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
      }

      verifyArtifactIdentity(ctx, ui);
      const remoteDmgPath = resolve(ctx.tempDir, "remote-Inline.dmg");
      await runStreaming(ui, ["curl", "-fSL", "--retry", "4", "--retry-all-errors", ctx.dmgUrl, "-o", remoteDmgPath], {
        cwd: ctx.rootDir,
      });
      const remoteSize = Bun.file(remoteDmgPath).size;
      const remoteSha256 = sha256File(remoteDmgPath);
      if (remoteSize !== ctx.dmgSize || remoteSha256 !== ctx.dmgSha256) {
        throw new Error(`Remote DMG does not match local artifact: remote ${remoteSize} bytes sha256 ${remoteSha256}; local ${ctx.dmgSize} bytes sha256 ${ctx.dmgSha256}.`);
      }
      rmSync(remoteDmgPath, { force: true });
      ui.detail("Verified remote DMG", `${ctx.dmgUrl} (${remoteSize} bytes, sha256 ${remoteSha256})`);
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
        throw new Error(`Sparkle tool not found: ${signUpdateBin}\nExpected Sparkle tools under --sparkle-dir (default: <root>/.action/sparkle/${sparkleVersion}).`);
      }

      // Ensure URLs/metadata.
      if (!ctx.dmgUrl || !ctx.appcastUrl) {
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
        verifyArtifactIdentity(ctx, ui);
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
      } else {
        verifyArtifactIdentity(ctx, ui);
      }

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

      fetchExistingAppcast(ctx, ui);

      await runStreaming(ui, ["python3", resolve(ctx.rootDir, "scripts/macos/update_appcast.py")], {
        cwd: ctx.rootDir,
        env: {
          INLINE_BUILD: ctx.buildNumber,
          INLINE_VERSION: ctx.version,
          INLINE_CHANNEL: ctx.channel,
          INLINE_DMG_URL: ctx.dmgUrl,
          INLINE_MIN_MACOS: ctx.minimumSystemVersion,
          INLINE_HARDWARE_REQUIREMENTS: macosReleaseArch,
          INLINE_COMMIT: ctx.experimentalTip ? "" : ctx.commit,
          INLINE_COMMIT_LONG: ctx.experimentalTip ? "" : ctx.commitLong,
          INLINE_EXPERIMENTAL_TIP: ctx.experimentalTip ? "1" : "0",
          SIGN_UPDATE_PATH: ctx.signUpdatePath,
          APPCAST_PATH: ctx.appcastPath,
          APPCAST_OUTPUT: ctx.appcastOutputPath,
          ALLOW_NEW_APPCAST: ctx.createNewAppcast ? "1" : "0",
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
      ui.info("  python3 scripts/macos/validate_appcast.py --appcast <temp>/appcast_new.xml --require-build <build> --require-short-version <version> --require-url <dmg-url> --require-length <bytes> --require-hardware arm64 --require-minimum-system-version <app floor>");
    },
    run: async (ctx, ui) => {
      if (!ctx.buildNumber || !ctx.dmgUrl) {
        ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
        ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
        verifyBuiltAppMetadata(ctx, ui);
        ctx.dmgUrl = `${ctx.baseUrl}/mac/${ctx.channel}/${ctx.buildNumber}/Inline.dmg`;
      }

      await runStreaming(ui, ["python3", resolve(ctx.rootDir, "scripts/macos/validate_appcast.py"), "--appcast", ctx.appcastOutputPath, "--require-build", ctx.buildNumber, "--require-short-version", ctx.version, "--require-url", ctx.dmgUrl, "--require-length", String(ctx.dmgSize), "--require-hardware", macosReleaseArch, "--require-minimum-system-version", ctx.minimumSystemVersion], {
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
      ui.info("  PUBLIC_RELEASES_R2_ACCESS_KEY_ID, PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY, PUBLIC_RELEASES_R2_BUCKET, PUBLIC_RELEASES_R2_ENDPOINT, PUBLIC_RELEASES_R2_PUBLIC_BASE_URL");
    },
    run: async (ctx, ui) => {
      assertNightlyMainStillSelected(ctx);
      requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
      requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
      requireEnv("PUBLIC_RELEASES_R2_BUCKET");
      requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
      ctx.baseUrl = ctx.baseUrl || trimTrailingSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
      ctx.appcastUrl = `${ctx.baseUrl}/mac/${ctx.channel}/appcast.xml`;
      verifyArtifactIdentity(ctx, ui);
      await runStreaming(ui, ["bun", "run", resolve(ctx.rootDir, "scripts/macos/release-direct.ts")], {
        cwd: ctx.rootDir,
        env: {
          UPLOAD_MODE: "appcast",
          CHANNEL: ctx.channel,
          APPCAST_PATH: ctx.appcastOutputPath,
          BUILD_NUMBER: ctx.buildNumber,
          APPCAST_EXPECTED_ETAG: ctx.appcastExpectedEtag,
          APPCAST_EXPECT_ABSENT: ctx.appcastExpectAbsent ? "1" : "0",
          RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken,
        },
      });
      ui.detail("Uploaded appcast", ctx.appcastUrl);
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
      ui.info(`  git tag -fa ${ctx.releaseTag} -m "Latest Sparkle release" ${ctx.sourceCommit}`);
      ui.info(`  git push --force origin ${ctx.releaseTag}`);
      ui.info(`  gh release view ${ctx.releaseTag} || gh release create ${ctx.releaseTag} ...`);
      ui.info(`  gh release upload ${ctx.releaseTag} ${ctx.dmgPath} --clobber`);
    },
    run: async (ctx, ui) => {
      if (!ctx.releaseTag) throw new Error("Internal error: github task enabled without releaseTag");
      if (!existsSync(ctx.dmgPath)) throw new Error(`DMG not found at ${ctx.dmgPath}`);
      verifyArtifactIdentity(ctx, ui);
      assertNightlyMainStillSelected(ctx);

      // Force-update tag and attach DMG.
      await runStreaming(ui, ["git", "-C", ctx.rootDir, "-c", "user.name=github-actions[bot]", "-c", "user.email=41898282+github-actions[bot]@users.noreply.github.com", "tag", "-fa", ctx.releaseTag, "-m", "Latest Sparkle release", ctx.sourceCommit], {
        cwd: ctx.rootDir,
      });
      await runStreaming(ui, ["git", "-C", ctx.rootDir, "push", "--force", "origin", ctx.releaseTag], { cwd: ctx.rootDir });

      const isPrerelease = ctx.channel !== "stable";
      const prereleaseFlag = isPrerelease ? ["--prerelease"] : [];
      const viewRes = spawnSync({ cmd: ["gh", "release", "view", ctx.releaseTag], stdout: "pipe", stderr: "pipe" });
      if (viewRes.exitCode !== 0) {
        await runStreaming(ui, ["gh", "release", "create", ctx.releaseTag, "--title", ctx.releaseTag, ...prereleaseFlag, "--notes", "Automated macOS direct release."], { cwd: ctx.rootDir });
      } else if (isPrerelease) {
        await runStreaming(ui, ["gh", "release", "edit", ctx.releaseTag, "--prerelease"], { cwd: ctx.rootDir });
      }

      await runStreaming(ui, ["gh", "release", "upload", ctx.releaseTag, ctx.dmgPath, "--clobber"], { cwd: ctx.rootDir });
      ui.detail("GitHub release tag", ctx.releaseTag);
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

  const heldLocks: HeldLock[] = [];
  let preserveLocks = false;
  const cleanup = () => {
    if (!preserveLocks) {
      while (heldLocks.length) releaseLock(heldLocks.pop()!);
    }
    if (keepTempDir) return;
    try {
      rmSync(ctx.tempDir, { recursive: true, force: true });
    } catch {
      // ignore
    }
  };
  process.on("exit", cleanup);
  let handlingInterrupt = false;
  process.on("SIGINT", () => {
    if (handlingInterrupt) {
      preserveLocks = true;
      process.exit(130);
    }
    handlingInterrupt = true;
    try {
      rmSync(ctx.signingKeyPath, { force: true });
    } catch {
      // ignore
    }
    keepTempDir = true;
    const interruptedProcess = activeSubprocess;
    interruptedProcess?.kill("SIGINT");
    if (interruptedProcess) {
      const killTimer = setTimeout(() => {
        if (activeSubprocess === interruptedProcess) interruptedProcess.kill("SIGKILL");
      }, 10_000);
      killTimer.unref();
    }
  });

  try {
    if (!opts.dryRun) {
      const lockRoot = resolve(ctx.rootDir, "build/macos-release-locks");
      const channelLock = acquireLock(lockRoot, `channel-${ctx.channel}.lockdir`, {
        kind: "channel",
        channel: ctx.channel,
        tempDir: ctx.tempDir,
      });
      heldLocks.push(channelLock);
      ctx.channelLockToken = channelLock.token;
      ui.detail("Channel lock", heldLocks.at(-1)!.path);
      if (!ctx.rollback && !ctx.dropBuild) {
        heldLocks.push(acquireLock(lockRoot, pathLockName("derived-data", ctx.derivedData), {
          kind: "derived-data",
          derivedData: ctx.derivedData,
          tempDir: ctx.tempDir,
        }));
        ui.detail("DerivedData lock", heldLocks.at(-1)!.path);
      }
    }
    if (opts.dryRun) {
      ui.info("Dry run: not executing. Showing what would run.");
    }
    let reachedFrom = !opts.fromTask;
    for (const task of tasks) {
      if (handlingInterrupt) throw new Error("Interrupted by Ctrl+C.");
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
        if (handlingInterrupt) throw new Error("Interrupted by Ctrl+C.");
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
    } else ui.error(msg);
    if (current) {
      ui.error(`Retry this step:\n  ${buildResumeCommand(ctx, current)}`);
    }
    if (ui.getLogPath()) ui.error(`Release log: ${ui.getLogPath()}`);
    ui.error(`Temp dir: ${ctx.tempDir}`);
    if (handlingInterrupt) {
      const activeOwner = !ctx.rollback && !ctx.dropBuild ? activeXcodebuildForDerivedData(ctx.derivedData) : "";
      if (activeOwner) {
        preserveLocks = true;
        ui.error(`An Xcode build still owns DerivedData, so release locks were intentionally preserved for manual inspection:\n${activeOwner}`);
      }
      process.exitCode = 130;
      return;
    }
    process.exit(1);
  }

  if (!opts.dryRun) {
    writeReleaseHistory(ctx, opts.rollback ? "rollback" : opts.dropBuild ? "drop-build" : "release", ui);
  }
  ui.info(opts.rollback ? "Rollback appcast publish complete." : opts.dropBuild ? "Appcast prune publish complete." : "Release pipeline complete.");
}

if (import.meta.main) await main();
