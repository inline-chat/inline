import { spawnSync } from "bun";
import { existsSync, mkdtempSync, readFileSync, readdirSync } from "fs";
import { basename, dirname, join, resolve } from "path";
import { tmpdir } from "os";

type Options = {
  searchRoot: string;
  appPath?: string;
  build?: string;
  org: string;
  project: string;
  apiUrl: string;
  dryRun: boolean;
};

type ReleaseHistory = {
  action?: string;
  appPath?: string;
  buildNumber?: string;
  channel?: string;
  commit?: string;
  createdAt?: string;
};

type DsymBundle = {
  path: string;
  uuids: string[];
};

function usage(): string {
  return [
    "Usage: bun run scripts/macos/upload-dsyms.ts [options]",
    "",
    "Options:",
    "  --build <number>       Resolve the retained app/dSYMs from macOS release history",
    "  --channel <channel>    Narrow --build to stable, beta, or tip",
    "  --search-root <path>   Root directory to scan for .dSYM bundles",
    "  --org <slug>           Sentry org slug (default: env SENTRY_ORG or usenoor)",
    "  --project <slug>       Sentry project slug (default: env SENTRY_PROJECT or inline-ios-macos)",
    "  --api-url <url>        Sentry API base URL (default: env SENTRY_API_URL or https://us.sentry.io)",
    "  --dry-run              Validate provenance and print the dSYM UUIDs without uploading",
    "  -h, --help             Show help",
    "",
    "Authentication:",
    "  Export SENTRY_AUTH_TOKEN for the upload process. The token is passed to curl over stdin",
    "  and is never accepted on the command line or printed.",
    "",
    "Examples:",
    "  bun run scripts/macos/upload-dsyms.ts --build 5182 --channel tip --dry-run",
    "  bun run scripts/macos/upload-dsyms.ts --build 5182 --channel tip",
  ].join("\n");
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv: string[], rootDir: string): Options {
  let searchRoot = resolve(rootDir, "build/InlineMacDirect/Build/Products/Release");
  let explicitSearchRoot = false;
  let build: string | undefined;
  let channel: string | undefined;
  let org = process.env.SENTRY_ORG || "usenoor";
  let project = process.env.SENTRY_PROJECT || "inline-ios-macos";
  let apiUrl = process.env.SENTRY_API_URL || "https://us.sentry.io";
  let dryRun = false;

  const eat = (i: number) => argv[i + 1] ?? "";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--build") {
      build = eat(i).trim();
      if (!/^\d+$/.test(build)) die(`Invalid --build value: ${build || "(empty)"}`);
      i++;
      continue;
    }
    if (arg === "--channel") {
      channel = eat(i).trim();
      if (!["stable", "beta", "tip"].includes(channel)) {
        die(`Invalid --channel value: ${channel || "(empty)"}`);
      }
      i++;
      continue;
    }
    if (arg === "--search-root") {
      searchRoot = resolve(rootDir, eat(i));
      explicitSearchRoot = true;
      i++;
      continue;
    }
    if (arg === "--org") {
      org = eat(i);
      i++;
      continue;
    }
    if (arg === "--project") {
      project = eat(i);
      i++;
      continue;
    }
    if (arg === "--api-url") {
      apiUrl = eat(i);
      i++;
      continue;
    }
    if (arg === "--dry-run") {
      dryRun = true;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      console.log(usage());
      process.exit(0);
    }
    die(`Unknown argument: ${arg}\n\n${usage()}`);
  }

  if (channel && !build) die("--channel requires --build");
  if (build && explicitSearchRoot) die("Use either --build or --search-root, not both");

  let appPath: string | undefined;
  if (build) {
    const history = resolveReleaseHistory(rootDir, build, channel);
    if (!history.appPath) die(`Release history for build ${build} does not contain appPath`);
    appPath = resolve(history.appPath);
    searchRoot = dirname(appPath);
    console.log(
      `Resolved build ${build} (${history.channel ?? "unknown channel"}, commit ${history.commit ?? "unknown"}) from release history`,
    );
  }

  return {
    searchRoot,
    appPath,
    build,
    org,
    project,
    apiUrl: apiUrl.replace(/\/+$/g, ""),
    dryRun,
  };
}

function resolveReleaseHistory(rootDir: string, build: string, channel?: string): ReleaseHistory {
  const historyRoot = resolve(rootDir, "build/macos-release-history");
  if (!existsSync(historyRoot)) die(`macOS release history directory not found: ${historyRoot}`);

  const matches = readdirSync(historyRoot)
    .filter((name) => name.endsWith(`-release-${build}.json`))
    .map((name) => {
      const path = join(historyRoot, name);
      let record: ReleaseHistory;
      try {
        record = JSON.parse(readFileSync(path, "utf8")) as ReleaseHistory;
      } catch (error) {
        die(`Failed to parse release history ${path}: ${String(error)}`);
      }
      return { path, record };
    })
    .filter(({ record }) => record.action === "release" && record.buildNumber === build)
    .filter(({ record }) => !channel || record.channel === channel)
    .sort((lhs, rhs) => (rhs.record.createdAt ?? "").localeCompare(lhs.record.createdAt ?? ""));

  if (matches.length === 0) {
    die(`No ${channel ? `${channel} ` : ""}macOS release-history record found for build ${build}`);
  }
  if (matches.length > 1 && !channel) {
    const channels = [...new Set(matches.map(({ record }) => record.channel ?? "unknown"))];
    if (channels.length > 1) die(`Build ${build} exists in multiple channels (${channels.join(", ")}); pass --channel`);
  }
  return matches[0]!.record;
}

function commandExists(cmd: string): boolean {
  const res = spawnSync({ cmd: ["bash", "-lc", `command -v ${cmd} >/dev/null 2>&1`] });
  return res.exitCode === 0;
}

function resolveAuthToken(): string {
  const token = process.env.SENTRY_AUTH_TOKEN?.trim();
  if (!token) die("Missing Sentry auth. Export SENTRY_AUTH_TOKEN for this upload process.");
  return token;
}

function collectDsymBundles(root: string): string[] {
  const results: string[] = [];

  const walk = (dir: string) => {
    for (const entry of readdirSync(dir, { withFileTypes: true })) {
      const fullPath = join(dir, entry.name);
      if (entry.isDirectory() && entry.name.endsWith(".dSYM")) {
        results.push(fullPath);
        continue;
      }
      if (entry.isDirectory()) {
        walk(fullPath);
      }
    }
  };

  walk(root);
  return results.sort();
}

function uuidsFor(path: string): string[] {
  const result = spawnSync({ cmd: ["dwarfdump", "--uuid", path], stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    const error = new TextDecoder().decode(result.stderr).trim();
    die(`Failed to read UUIDs from ${path}${error ? `:\n${error}` : ""}`);
  }
  return [...new TextDecoder().decode(result.stdout).matchAll(/UUID:\s+([0-9A-F-]+)/gi)].map((match) =>
    match[1]!.toLowerCase(),
  );
}

function normalizedUuid(value: string): string {
  return value.toLowerCase().replace(/[^0-9a-f]/g, "");
}

function validateReleaseArtifact(opts: Options, dsyms: DsymBundle[]) {
  if (!opts.appPath || !opts.build) return;
  const executable = join(opts.appPath, "Contents/MacOS/Inline");
  const plist = join(opts.appPath, "Contents/Info.plist");
  if (!existsSync(executable) || !existsSync(plist)) die(`Retained release app is incomplete: ${opts.appPath}`);

  const buildResult = spawnSync({
    cmd: ["/usr/libexec/PlistBuddy", "-c", "Print :CFBundleVersion", plist],
    stdout: "pipe",
    stderr: "pipe",
  });
  const actualBuild = new TextDecoder().decode(buildResult.stdout).trim();
  if (buildResult.exitCode !== 0 || actualBuild !== opts.build) {
    die(`Retained app build mismatch: expected ${opts.build}, found ${actualBuild || "unknown"}`);
  }

  const executableUuids = uuidsFor(executable);
  const dsymUuids = new Set(dsyms.flatMap((bundle) => bundle.uuids).map(normalizedUuid));
  const missing = executableUuids.filter((uuid) => !dsymUuids.has(normalizedUuid(uuid)));
  if (missing.length > 0) die(`No matching dSYM found for retained app UUID(s): ${missing.join(", ")}`);
  console.log(`Verified retained app build ${opts.build} UUID(s): ${executableUuids.join(", ")}`);
}

function zipDsym(dsymPath: string, outputPath: string) {
  const res = spawnSync({
    cmd: ["ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", dsymPath, outputPath],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (res.exitCode !== 0) {
    const error = new TextDecoder().decode(res.stderr).trim();
    die(`Failed to zip ${basename(dsymPath)}${error ? `:\n${error}` : ""}`);
  }
}

function sentryRequest(args: string[], authToken: string) {
  const authHeader = new TextEncoder().encode(`Authorization: Bearer ${authToken}\n`);
  return spawnSync({
    cmd: ["curl", "--header", "@-", ...args],
    stdin: authHeader,
    stdout: "pipe",
    stderr: "pipe",
  });
}

function uploadArchive(zipPath: string, opts: Options, authToken: string) {
  const endpoint = `${opts.apiUrl}/api/0/projects/${opts.org}/${opts.project}/files/dsyms/`;
  const res = sentryRequest(["-fsS", "-X", "POST", endpoint, "-F", `file=@${zipPath}`], authToken);
  if (res.exitCode !== 0) {
    const error = new TextDecoder().decode(res.stderr).trim();
    die(`Failed to upload ${basename(zipPath)} to ${endpoint}${error ? `:\n${error}` : ""}`);
  }
}

async function verifyUuid(uuid: string, opts: Options, authToken: string) {
  const endpoint = `${opts.apiUrl}/api/0/projects/${opts.org}/${opts.project}/files/dsyms/`;
  for (let attempt = 1; attempt <= 6; attempt++) {
    const res = sentryRequest(["-fsS", "--get", endpoint, "--data-urlencode", `query=${uuid}`], authToken);
    if (res.exitCode !== 0) {
      const error = new TextDecoder().decode(res.stderr).trim();
      die(`Failed to verify dSYM UUID ${uuid}${error ? `:\n${error}` : ""}`);
    }
    let response: Array<{ debugId?: string; uuid?: string }>;
    try {
      response = JSON.parse(new TextDecoder().decode(res.stdout)) as Array<{ debugId?: string; uuid?: string }>;
    } catch (error) {
      die(`Sentry returned invalid JSON while verifying UUID ${uuid}: ${String(error)}`);
    }
    if (response.some((item) => normalizedUuid(item.debugId ?? item.uuid ?? "") === normalizedUuid(uuid))) return;
    if (attempt < 6) await Bun.sleep(2_000);
  }
  die(`Sentry did not expose uploaded dSYM UUID ${uuid} after 12 seconds`);
}

async function main() {
  const rootDir = resolve(import.meta.dir, "../..");
  const opts = parseArgs(process.argv.slice(2), rootDir);

  if (!commandExists("curl")) die("Missing required command: curl");
  if (!commandExists("ditto")) die("Missing required command: ditto");
  if (!commandExists("dwarfdump")) die("Missing required command: dwarfdump");

  if (!existsSync(opts.searchRoot)) die(`dSYM search root not found: ${opts.searchRoot}`);
  const dsyms = collectDsymBundles(opts.searchRoot).map((path) => ({ path, uuids: uuidsFor(path) }));
  if (dsyms.length === 0) {
    die(`No .dSYM bundles found under ${opts.searchRoot}`);
  }
  for (const bundle of dsyms) {
    if (bundle.uuids.length === 0) die(`No UUIDs found in ${bundle.path}`);
    console.log(`${basename(bundle.path)}: ${bundle.uuids.join(", ")}`);
  }
  validateReleaseArtifact(opts, dsyms);
  if (opts.dryRun) {
    console.log(`Dry run complete; ${dsyms.length} dSYM bundle(s) are ready for ${opts.org}/${opts.project}.`);
    return;
  }

  const authToken = resolveAuthToken();

  const tempDir = mkdtempSync(join(tmpdir(), "inline-dsyms-"));
  console.log(`Uploading ${dsyms.length} dSYM bundle(s) to ${opts.org}/${opts.project}`);
  for (const [index, bundle] of dsyms.entries()) {
    const zipPath = join(tempDir, `${String(index + 1).padStart(2, "0")}-${basename(bundle.path)}.zip`);
    zipDsym(bundle.path, zipPath);
    console.log(`Uploading ${basename(bundle.path)}...`);
    uploadArchive(zipPath, opts, authToken);
    for (const uuid of bundle.uuids) {
      await verifyUuid(uuid, opts, authToken);
      console.log(`Verified ${uuid}`);
    }
  }
  console.log(`Upload archives retained at ${tempDir}`);
}

await main();
