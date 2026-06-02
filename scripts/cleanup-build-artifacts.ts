import { existsSync } from "fs";
import { readdir, rm, stat } from "fs/promises";
import { homedir } from "os";
import { stdin as input, stdout as output } from "process";
import { createInterface } from "readline/promises";
import { relative, resolve, sep } from "path";

type Options = {
  deep: boolean;
  dryRun: boolean;
  includeArchives: boolean;
  keepMacosBuilds: number;
  yes: boolean;
};

type Target = {
  path: string;
  label: string;
  scope: "repo" | "global";
};

type SizedTarget = Target & {
  kib: number;
};

const repoRoot = resolve(import.meta.dir, "..");
const home = homedir();

const options = parseArgs(process.argv.slice(2));
const targets = await collectTargets(options);
const sizedTargets = await sizeTargets(targets);

if (sizedTargets.length === 0) {
  console.log("No cleanup targets found.");
  process.exit(0);
}

printPlan(sizedTargets, options);

if (options.dryRun) {
  process.exit(0);
}

await confirmIfNeeded(sizedTargets, options);
await removeTargets(sizedTargets);

console.log("");
console.log(`Removed approximately ${formatSize(totalKiB(sizedTargets))} of generated artifacts.`);

function usage(): string {
  return [
    "Usage: bun run cleanup-build-artifacts.ts [options]",
    "",
    "Deletes generated build/cache artifacts that are safe to recreate.",
    "",
    "Options:",
    "  --deep                    Also clean global Xcode/Bun/SwiftPM caches",
    "  --include-archives        With --deep, also delete Xcode Archives",
    "  --keep-macos-builds <n>   Keep the newest n macOS direct-build folders under build/InlineMacDirect",
    "                            Default: 0, which removes the repo build/ tree entirely",
    "  --dry-run                 Print what would be deleted without deleting it",
    "  -y, --yes                 Skip the confirmation prompt",
    "  -h, --help                Show this help",
    "",
    "Examples:",
    "  bun run cleanup-build-artifacts.ts --dry-run",
    "  bun run cleanup-build-artifacts.ts --yes",
    "  bun run cleanup-build-artifacts.ts --deep --yes",
    "  bun run cleanup-build-artifacts.ts --keep-macos-builds 1 --yes",
    "",
    "This script does not read .env files.",
  ].join("\n");
}

function parseArgs(argv: string[]): Options {
  const options: Options = {
    deep: false,
    dryRun: false,
    includeArchives: false,
    keepMacosBuilds: 0,
    yes: false,
  };

  for (let i = 0; i < argv.length; i += 1) {
    const arg = argv[i];

    if (arg === "--deep") {
      options.deep = true;
      continue;
    }

    if (arg === "--include-archives") {
      options.includeArchives = true;
      continue;
    }

    if (arg === "--dry-run") {
      options.dryRun = true;
      continue;
    }

    if (arg === "-y" || arg === "--yes") {
      options.yes = true;
      continue;
    }

    if (arg === "--keep-macos-builds") {
      const value = argv[i + 1];
      if (!value) {
        die("Missing value for --keep-macos-builds.");
      }

      const keep = Number.parseInt(value, 10);
      if (!Number.isInteger(keep) || keep < 0) {
        die(`Invalid --keep-macos-builds value: ${value}`);
      }

      options.keepMacosBuilds = keep;
      i += 1;
      continue;
    }

    if (arg === "-h" || arg === "--help") {
      console.log(usage());
      process.exit(0);
    }

    die(`Unknown argument: ${arg}\n\n${usage()}`);
  }

  if (options.includeArchives && !options.deep) {
    die("--include-archives requires --deep.");
  }

  return options;
}

async function collectTargets(options: Options): Promise<Target[]> {
  const out: Target[] = [];
  const addRepo = (relPath: string, label = relPath) => {
    out.push({
      path: resolve(repoRoot, relPath),
      label,
      scope: "repo",
    });
  };
  const addGlobal = (path: string, label: string) => {
    out.push({
      path,
      label,
      scope: "global",
    });
  };

  await addMacosBuildTargets(out, options);

  for (const relPath of [
    ".vite",
    "apple/InlineUI/.build",
    "apple/InlineUI/build",
    "apple/InlineMacUI/.build",
    "apple/InlineMacUI/.build-hotkeys",
    "apple/InlineMacUI/.build-macos",
    "apple/InlineMacUI/build",
    "apple/InlineIOSUI/.build",
    "apple/InlineIOSUI/.build-macos",
    "apple/InlineKit/.build",
    "apple/InlineKit/build",
    "scripts/.tools/swift-protobuf-1.28.2/.build",
    "cli/target",
    "cli/dist",
    "desktop/build",
    "landing/dist",
    "server/dist",
    "web/dist",
  ]) {
    addRepo(relPath);
  }

  for (const relPath of await collectPackageOutputDirs("packages")) {
    addRepo(relPath);
  }

  for (const relPath of await collectPackageOutputDirs("server/packages")) {
    addRepo(relPath);
  }

  for (const relPath of await collectPackageOutputDirs("landing/packages")) {
    addRepo(relPath);
  }

  for (const relPath of await collectNodeModulesViteDirs()) {
    addRepo(relPath);
  }

  for (const relPath of await collectOldBunModuleDirs()) {
    addRepo(relPath, "stale bun install backup");
  }

  if (options.deep) {
    addGlobal(resolve(home, "Library/Developer/Xcode/DerivedData"), "Xcode DerivedData");
    addGlobal(resolve(home, "Library/Developer/Xcode/iOS DeviceSupport"), "Xcode iOS DeviceSupport");
    addGlobal(resolve(home, "Library/Developer/CoreSimulator/Caches"), "CoreSimulator caches");
    addGlobal(resolve(home, "Library/Caches/org.swift.swiftpm"), "SwiftPM cache");
    addGlobal(resolve(home, "Library/Caches/com.apple.dt.Xcode"), "Xcode cache");
    addGlobal(resolve(home, ".bun/install/cache"), "Bun install cache");

    if (options.includeArchives) {
      addGlobal(resolve(home, "Library/Developer/Xcode/Archives"), "Xcode Archives");
    }
  }

  return dedupe(out).filter(isSafeTarget);
}

async function addMacosBuildTargets(out: Target[], options: Options) {
  const addRepo = (relPath: string, label = relPath) => {
    out.push({
      path: resolve(repoRoot, relPath),
      label,
      scope: "repo",
    });
  };

  if (options.keepMacosBuilds === 0) {
    addRepo("build", "repo build outputs");
    return;
  }

  for (const relPath of [
    "build/InlineMacDirect/Build",
    "build/InlineMacDirect/CompilationCache.noindex",
    "build/InlineMacDirect/ModuleCache.noindex",
    "build/InlineMacDirect/SDKStatCaches.noindex",
    "build/InlineMacDirect/SymbolCache.noindex",
    "build/InlineMacDirectLocal",
    "build/macos-direct",
    "build/macos-local-app",
    "build/macos-release-tmp",
    "build/tmp-mcp-prune-check",
    "build/traces",
  ]) {
    addRepo(relPath);
  }

  for (const relPath of await collectMatchingChildren("build", /^macos-direct-local-/)) {
    addRepo(relPath);
  }

  for (const relPath of await collectPrunedChildren(
    "build/InlineMacDirect",
    /^(release|local-test)-/,
    options.keepMacosBuilds,
  )) {
    addRepo(relPath, `older macOS direct build, keeping newest ${options.keepMacosBuilds}`);
  }
}

async function collectPackageOutputDirs(baseRelPath: string): Promise<string[]> {
  const basePath = resolve(repoRoot, baseRelPath);
  if (!existsSync(basePath)) {
    return [];
  }

  const out: string[] = [];
  const entries = await readdir(basePath, { withFileTypes: true });
  for (const entry of entries) {
    if (!entry.isDirectory() || entry.name.startsWith(".")) {
      continue;
    }

    const workspaceRel = `${baseRelPath}/${entry.name}`;
    out.push(`${workspaceRel}/dist`);
    out.push(`${workspaceRel}/coverage`);
    out.push(`${workspaceRel}/node_modules/.vite`);
  }

  return out;
}

async function collectNodeModulesViteDirs(): Promise<string[]> {
  const relPaths = [
    "node_modules/.vite",
    "landing/node_modules/.vite",
    "landing/packages/client/node_modules/.vite",
    "packages/openclaw/node_modules/.vite",
    "packages/bot-api/node_modules/.vite",
    "packages/mcp/node_modules/.vite",
    "packages/sdk/node_modules/.vite",
  ];

  return relPaths;
}

async function collectOldBunModuleDirs(): Promise<string[]> {
  const nodeModulesPath = resolve(repoRoot, "node_modules");
  if (!existsSync(nodeModulesPath)) {
    return [];
  }

  const out: string[] = [];
  const entries = await readdir(nodeModulesPath, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory() && entry.name.startsWith(".old_modules-")) {
      out.push(`node_modules/${entry.name}`);
    }
  }

  return out;
}

async function collectMatchingChildren(parentRelPath: string, pattern: RegExp): Promise<string[]> {
  const parentPath = resolve(repoRoot, parentRelPath);
  if (!existsSync(parentPath)) {
    return [];
  }

  const out: string[] = [];
  const entries = await readdir(parentPath, { withFileTypes: true });
  for (const entry of entries) {
    if (entry.isDirectory() && pattern.test(entry.name)) {
      out.push(`${parentRelPath}/${entry.name}`);
    }
  }

  return out;
}

async function collectPrunedChildren(
  parentRelPath: string,
  pattern: RegExp,
  keep: number,
): Promise<string[]> {
  const parentPath = resolve(repoRoot, parentRelPath);
  if (!existsSync(parentPath)) {
    return [];
  }

  const entries = await readdir(parentPath, { withFileTypes: true });
  const children = await Promise.all(
    entries
      .filter((entry) => entry.isDirectory() && pattern.test(entry.name))
      .map(async (entry) => {
        const path = resolve(parentPath, entry.name);
        const info = await stat(path);
        return {
          relPath: `${parentRelPath}/${entry.name}`,
          mtimeMs: info.mtimeMs,
        };
      }),
  );

  return children
    .sort((a, b) => b.mtimeMs - a.mtimeMs)
    .slice(keep)
    .map((item) => item.relPath);
}

function dedupe(targets: Target[]): Target[] {
  const seen = new Set<string>();
  const out: Target[] = [];

  for (const target of targets) {
    const path = resolve(target.path);
    if (seen.has(path)) {
      continue;
    }

    seen.add(path);
    out.push({ ...target, path });
  }

  return out;
}

function isSafeTarget(target: Target): boolean {
  const path = resolve(target.path);
  const rel = relative(repoRoot, path);

  if (path.includes(`${sep}.env`) || rel === ".env" || rel.startsWith(`.env${sep}`)) {
    return false;
  }

  if (target.scope === "repo") {
    if (rel === "" || rel === "." || rel.startsWith(`..${sep}`) || rel === "..") {
      return false;
    }

    if (rel === ".git" || rel.startsWith(`.git${sep}`)) {
      return false;
    }

    if (rel === "node_modules") {
      return false;
    }

    return true;
  }

  const globalAllowlist = [
    resolve(home, "Library/Developer/Xcode/DerivedData"),
    resolve(home, "Library/Developer/Xcode/iOS DeviceSupport"),
    resolve(home, "Library/Developer/Xcode/Archives"),
    resolve(home, "Library/Developer/CoreSimulator/Caches"),
    resolve(home, "Library/Caches/org.swift.swiftpm"),
    resolve(home, "Library/Caches/com.apple.dt.Xcode"),
    resolve(home, ".bun/install/cache"),
  ];

  return globalAllowlist.includes(path);
}

async function sizeTargets(targets: Target[]): Promise<SizedTarget[]> {
  const out: SizedTarget[] = [];

  for (const target of targets) {
    if (!existsSync(target.path)) {
      continue;
    }

    out.push({
      ...target,
      kib: await duKiB(target.path),
    });
  }

  return out.sort((a, b) => b.kib - a.kib);
}

async function duKiB(path: string): Promise<number> {
  const proc = Bun.spawn(["du", "-sk", path], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  const exitCode = await proc.exited;

  if (exitCode !== 0) {
    return 0;
  }

  const [raw] = stdout.trim().split(/\s+/);
  const kib = Number.parseInt(raw ?? "0", 10);
  return Number.isFinite(kib) ? kib : 0;
}

function printPlan(targets: SizedTarget[], options: Options) {
  const action = options.dryRun ? "Would remove" : "Will remove";
  console.log(`${action} ${targets.length} generated artifact ${targets.length === 1 ? "path" : "paths"}:`);
  console.log("");

  for (const target of targets) {
    const displayPath = displayTargetPath(target.path);
    const label = target.label === displayPath ? "" : ` (${target.label})`;
    console.log(`${formatSize(target.kib).padStart(8)}  ${displayPath}${label}`);
  }

  console.log("");
  console.log(`Total: ${formatSize(totalKiB(targets))}`);

  if (!options.deep) {
    console.log("Global Xcode/Bun caches are excluded. Pass --deep to include them.");
  }

  if (options.deep && !options.includeArchives) {
    console.log("Xcode Archives are excluded. Pass --include-archives to delete them too.");
  }
}

async function confirmIfNeeded(targets: SizedTarget[], options: Options) {
  if (options.yes) {
    return;
  }

  if (!process.stdin.isTTY) {
    die("Refusing to delete without --yes in a non-interactive terminal.");
  }

  const rl = createInterface({ input, output });
  const answer = await rl.question("\nType yes to delete these generated artifacts: ");
  rl.close();

  if (answer.trim().toLowerCase() !== "yes") {
    console.log("Cancelled.");
    process.exit(0);
  }
}

async function removeTargets(targets: SizedTarget[]) {
  for (const target of [...targets].sort((a, b) => b.path.length - a.path.length)) {
    console.log(`Removing ${displayTargetPath(target.path)}`);
    await rm(target.path, {
      recursive: true,
      force: true,
      maxRetries: 3,
      retryDelay: 200,
    });
  }
}

function totalKiB(targets: SizedTarget[]): number {
  return targets.reduce((sum, target) => sum + target.kib, 0);
}

function formatSize(kib: number): string {
  const units = ["KiB", "MiB", "GiB", "TiB"];
  let size = kib;
  let unit = 0;

  while (size >= 1024 && unit < units.length - 1) {
    size /= 1024;
    unit += 1;
  }

  const rounded = size >= 10 || unit === 0 ? size.toFixed(0) : size.toFixed(1);
  return `${rounded}${units[unit]}`;
}

function displayTargetPath(path: string): string {
  const rel = relative(repoRoot, path);
  if (!rel.startsWith(`..${sep}`) && rel !== "..") {
    return rel;
  }

  if (path === home || path.startsWith(`${home}${sep}`)) {
    return `~/${relative(home, path)}`;
  }

  return path;
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}
