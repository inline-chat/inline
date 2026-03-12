import { spawnSync } from "bun";
import { mkdtempSync, readdirSync, rmSync } from "fs";
import { basename, join, resolve } from "path";
import { tmpdir } from "os";

type Options = {
  searchRoot: string;
  org: string;
  project: string;
  apiUrl: string;
  authToken?: string;
};

function usage(): string {
  return [
    "Usage: bun run scripts/macos/upload-dsyms.ts [options]",
    "",
    "Options:",
    "  --search-root <path>   Root directory to scan for .dSYM bundles",
    "  --org <slug>           Sentry org slug (default: env SENTRY_ORG or usenoor)",
    "  --project <slug>       Sentry project slug (default: env SENTRY_PROJECT or inline-ios-macos)",
    "  --api-url <url>        Sentry API base URL (default: env SENTRY_API_URL or https://us.sentry.io)",
    "  --auth-token <token>   Sentry auth token (default: env SENTRY_AUTH_TOKEN or `sentry auth token`)",
    "  -h, --help             Show help",
  ].join("\n");
}

function die(message: string): never {
  console.error(message);
  process.exit(1);
}

function parseArgs(argv: string[], rootDir: string): Options {
  let searchRoot = resolve(rootDir, "build/InlineMacDirect/Build/Products/Release");
  let org = process.env.SENTRY_ORG || "usenoor";
  let project = process.env.SENTRY_PROJECT || "inline-ios-macos";
  let apiUrl = process.env.SENTRY_API_URL || "https://us.sentry.io";
  let authToken = process.env.SENTRY_AUTH_TOKEN;

  const eat = (i: number) => argv[i + 1] ?? "";
  for (let i = 0; i < argv.length; i++) {
    const arg = argv[i];
    if (arg === "--search-root") {
      searchRoot = resolve(rootDir, eat(i));
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
    if (arg === "--auth-token") {
      authToken = eat(i);
      i++;
      continue;
    }
    if (arg === "-h" || arg === "--help") {
      console.log(usage());
      process.exit(0);
    }
    die(`Unknown argument: ${arg}\n\n${usage()}`);
  }

  return {
    searchRoot,
    org,
    project,
    apiUrl: apiUrl.replace(/\/+$/g, ""),
    authToken,
  };
}

function commandExists(cmd: string): boolean {
  const res = spawnSync({ cmd: ["bash", "-lc", `command -v ${cmd} >/dev/null 2>&1`] });
  return res.exitCode === 0;
}

function resolveAuthToken(explicit?: string): string {
  if (explicit?.trim()) return explicit.trim();
  if (!commandExists("sentry")) {
    die(
      "Missing Sentry auth. Set SENTRY_AUTH_TOKEN or log in with the modern `sentry` CLI so `sentry auth token` works.",
    );
  }

  const res = spawnSync({
    cmd: ["sentry", "auth", "token"],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (res.exitCode !== 0) {
    const error = new TextDecoder().decode(res.stderr).trim();
    die(`Unable to resolve Sentry auth token from \`sentry auth token\`${error ? `:\n${error}` : "."}`);
  }

  const token = new TextDecoder().decode(res.stdout).trim();
  if (!token) {
    die("`sentry auth token` returned an empty token. Set SENTRY_AUTH_TOKEN or re-authenticate with `sentry auth login`.");
  }
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

function uploadArchive(zipPath: string, opts: Options, authToken: string) {
  const endpoint = `${opts.apiUrl}/api/0/projects/${opts.org}/${opts.project}/files/dsyms/`;
  const res = spawnSync({
    cmd: [
      "curl",
      "-fsS",
      "-X",
      "POST",
      endpoint,
      "-H",
      `Authorization: Bearer ${authToken}`,
      "-F",
      `file=@${zipPath}`,
    ],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (res.exitCode !== 0) {
    const error = new TextDecoder().decode(res.stderr).trim();
    die(`Failed to upload ${basename(zipPath)} to ${endpoint}${error ? `:\n${error}` : ""}`);
  }
}

async function main() {
  const rootDir = resolve(import.meta.dir, "../..");
  const opts = parseArgs(process.argv.slice(2), rootDir);

  if (!commandExists("curl")) die("Missing required command: curl");
  if (!commandExists("ditto")) die("Missing required command: ditto");

  const authToken = resolveAuthToken(opts.authToken);
  const dsyms = collectDsymBundles(opts.searchRoot);
  if (dsyms.length === 0) {
    die(`No .dSYM bundles found under ${opts.searchRoot}`);
  }

  const tempDir = mkdtempSync(join(tmpdir(), "inline-dsyms-"));
  try {
    console.log(`Uploading ${dsyms.length} dSYM bundle(s) to ${opts.org}/${opts.project}`);
    for (const [index, dsymPath] of dsyms.entries()) {
      const zipPath = join(tempDir, `${String(index + 1).padStart(2, "0")}-${basename(dsymPath)}.zip`);
      zipDsym(dsymPath, zipPath);
      console.log(`Uploading ${basename(dsymPath)}...`);
      uploadArchive(zipPath, opts, authToken);
    }
  } finally {
    rmSync(tempDir, { recursive: true, force: true });
  }
}

await main();
