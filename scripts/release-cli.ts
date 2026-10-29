import { S3Client } from "bun";
import { createHash } from "crypto";
import { appendFile, copyFile, mkdir, readFile, realpath, rm, stat, writeFile } from "fs/promises";
import { basename, dirname, join, resolve } from "path";
import { parseCliReleaseTag } from "./ci/cli-release-version";
import { authenticatedChannelVersion, releaseSigner, signedChannel, type Channel } from "./cli-release-signing";

const rootDir = resolve(import.meta.dir, "..");
const cliDir = join(rootDir, "cli");
const targetDir = join(rootDir, "target");
const distDir = join(cliDir, "dist");
const tempAssetsDir = join(rootDir, "scripts", ".release-tmp");
const githubRepo = process.env.INLINE_CLI_GITHUB_REPO ?? "inline-chat/inline";
const githubReleaseTarget = process.env.INLINE_CLI_GITHUB_TARGET;
const homebrewTapPath =
  process.env.INLINE_HOMEBREW_TAP_PATH ?? resolve(rootDir, "..", "homebrew-inline");
const homebrewTapRemote = process.env.INLINE_HOMEBREW_TAP_REMOTE ?? "origin";
const signingIdentity = process.env.APPLE_SIGNING_IDENTITY ?? process.env.MACOS_CERTIFICATE_NAME;
const appleId = process.env.APPLE_ID;
const applePassword = process.env.APPLE_PASSWORD;
const appleTeamId = process.env.APPLE_TEAM_ID;
const appleNotarizationKey = process.env.APPLE_NOTARIZATION_KEY;
const appleNotarizationKeyId = process.env.APPLE_NOTARIZATION_KEY_ID;
const appleNotarizationIssuer = process.env.APPLE_NOTARIZATION_ISSUER;
const skipNotarize =
  isTruthy(process.env.INLINE_SKIP_NOTARIZE) || isTruthy(process.env.SKIP_NOTARIZE);
let publicationChanged = false;
const defaultTargets = [
  "aarch64-apple-darwin",
  "aarch64-unknown-linux-gnu",
  "x86_64-unknown-linux-gnu",
  "aarch64-unknown-linux-musl",
  "x86_64-unknown-linux-musl",
] as const;
const supportedTargets = [...defaultTargets] as const;
const homebrewTargets = {
  macosArm: "aarch64-apple-darwin",
  linuxArm: "aarch64-unknown-linux-gnu",
  linuxIntel: "x86_64-unknown-linux-gnu",
} as const;

async function main() {
  const command = process.argv[2] ?? "release";

  if (command === "signing-preflight") {
    await releaseSigner();
    console.log("CLI manifest signer matches the shipped public key.");
    return;
  }

  if (command === "release") {
    parseCliReleaseTag(requireEnv("INLINE_CLI_RELEASE_TAG"));
    const { r2, publicBaseUrl, prefix } = getR2Context();
    await runRelease(r2, publicBaseUrl, prefix);
  } else if (command === "build") {
    await runBuildArtifacts();
  } else if (command === "publish") {
    parseCliReleaseTag(requireEnv("INLINE_CLI_RELEASE_TAG"));
    const { r2, publicBaseUrl, prefix } = getR2Context();
    await runPublish(r2, publicBaseUrl, prefix);
  } else if (command === "status") {
    const context = await getReleaseContext(true);
    const { r2, prefix } = getR2Context();
    const receipt = await readReleaseReceipt(r2, prefix, context);
    const available: string[] = [];
    if (receipt) {
      for (const target of context.targets) {
        if (await r2.file(`${prefix}/v${context.version}/${artifactName(context.version, target)}`).exists()) available.push(target);
      }
    }
    await writeOutputs({ available_targets: JSON.stringify(available), artifacts_ready: String(available.length === context.targets.length) });
  } else if (command === "validate-homebrew") {
    await readValidatedHomebrewCask();
    console.log("Homebrew cask platform contract is valid.");
  } else {
    throw new Error(
      `Unknown command: ${command}. Supported commands: release, build, publish, status, validate-homebrew.`,
    );
  }
}

if (import.meta.main) {
  await main();
}

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function trimSlash(value: string): string {
  return value.replace(/^\/+|\/+$/g, "");
}

function isTruthy(value: string | undefined): boolean {
  return ["1", "true", "yes"].includes(value?.toLowerCase() ?? "");
}

function getR2Context() {
  const accessKeyId = requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
  const secretAccessKey = requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
  const bucket = requireEnv("PUBLIC_RELEASES_R2_BUCKET");
  const endpoint = requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
  const publicBaseUrl = trimSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
  const prefix = "cli";

  const r2 = new S3Client({
    accessKeyId,
    secretAccessKey,
    bucket,
    endpoint,
  });

  return { r2, publicBaseUrl, prefix };
}

async function readCargoVersion(path: string): Promise<string> {
  const contents = await readFile(path, "utf8");
  const match = contents.match(/^version\s*=\s*"([^"]+)"/m);
  if (!match) {
    throw new Error("Failed to read version from Cargo.toml");
  }
  return match[1];
}

export function isPrereleaseVersion(version: string): boolean {
  return version.includes("-");
}

export function manifestObjectKey(prefix: string, version: string): string {
  return isPrereleaseVersion(version)
    ? `${prefix}/v${version}/manifest.json`
    : `${prefix}/manifest.json`;
}

function manifestPublicUrl(publicBaseUrl: string, prefix: string, version: string): string {
  return `${publicBaseUrl}/${manifestObjectKey(prefix, version)}`;
}

function logPublishedRelease(publicBaseUrl: string, prefix: string, context: ReleaseContext) {
  console.log(`${publicationChanged ? "Published" : "Verified existing"} Inline CLI v${context.version}`);
  console.log(`Manifest: ${manifestPublicUrl(publicBaseUrl, prefix, context.version)}`);
  console.log(`Alpha channel: ${publicBaseUrl}/${alphaManifestKey(prefix)}`);
  if (isPrereleaseVersion(context.version)) {
    console.log("Prerelease: stable manifest, install script, and Homebrew cask were not advanced.");
    return;
  }
  console.log(`Install: ${publicBaseUrl}/${prefix}/install.sh`);
  console.log(`Install command: curl -fsSL ${publicBaseUrl}/${prefix}/install.sh | sh`);
}

async function sha256File(path: string): Promise<string> {
  const data = await readFile(path);
  return createHash("sha256").update(data).digest("hex");
}

async function runCommand(command: string, args: string[], options: { cwd?: string } = {}) {
  const proc = Bun.spawn([command, ...args], {
    cwd: options.cwd,
    stdout: "inherit",
    stderr: "inherit",
  });
  const exitCode = await proc.exited;
  if (exitCode !== 0) {
    throw new Error(`Command failed: ${command} ${redactArgs(args).join(" ")}`);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

function redactArgs(args: string[]): string[] {
  const out = [...args];
  for (let i = 0; i < out.length; i += 1) {
    const current = out[i];
    if (current === "--password" && i + 1 < out.length) {
      out[i + 1] = "<redacted>";
    }
  }
  return out;
}

async function runCommandCapture(
  command: string,
  args: string[],
  options: { cwd?: string } = {},
) {
  const proc = Bun.spawn([command, ...args], {
    cwd: options.cwd,
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = await new Response(proc.stdout).text();
  const stderr = await new Response(proc.stderr).text();
  const exitCode = await proc.exited;
  return { stdout, stderr, exitCode };
}

function shouldRetryNotarize(output: string): boolean {
  // Observed: "Error: HTTPClientError.connectTimeout"
  return /(connecttimeout|econnreset|enotfound|timed out|tls|network)/i.test(output);
}

async function uploadFile(
  r2: S3Client,
  key: string,
  path: string,
  contentType: string,
) {
  await writeReleaseObject(r2, key, new Uint8Array(await readFile(path)), contentType, false);
}

export async function writeReleaseObject(r2: S3Client, key: string, bytes: Uint8Array, contentType: string, immutable = true): Promise<boolean> {
  const file = r2.file(key);
  if (await file.exists()) {
    const existing = new Uint8Array(await file.arrayBuffer());
    if (Buffer.from(existing).equals(Buffer.from(bytes))) return false;
    if (immutable) throw new Error(`Refusing to overwrite different release content: ${key}`);
  }
  await file.write(bytes, { type: contentType });
  publicationChanged = true;
  return true;
}

export type ReleaseContext = {
  version: string;
  targets: readonly string[];
  releaseDir: string;
  tag?: string;
  sourceSha: string;
};

export type ReleaseReceipt = { version: string; tag: string; sourceSha: string; targets: readonly string[] };

function expectedReceipt(context: ReleaseContext): ReleaseReceipt {
  if (!context.tag) throw new Error("Publication requires an existing exact CLI release tag");
  return { version: context.version, tag: context.tag, sourceSha: context.sourceSha, targets: [...context.targets].sort() };
}

export function assertMatchingReleaseReceipt(actual: ReleaseReceipt, expected: ReleaseReceipt) {
  if (actual.version !== expected.version || actual.tag !== expected.tag || actual.sourceSha !== expected.sourceSha || !Array.isArray(actual.targets) || JSON.stringify([...actual.targets].sort()) !== JSON.stringify([...expected.targets].sort())) {
    throw new Error("Existing CLI release receipt belongs to a different source, version, or target set");
  }
}

async function readReleaseReceipt(r2: S3Client, prefix: string, context: ReleaseContext): Promise<ReleaseReceipt | null> {
  const file = r2.file(`${prefix}/v${context.version}/release.json`);
  if (!(await file.exists())) return null;
  const receipt = JSON.parse(await file.text()) as ReleaseReceipt;
  assertMatchingReleaseReceipt(receipt, expectedReceipt(context));
  return receipt;
}

async function ensureReleaseReceipt(r2: S3Client, prefix: string, context: ReleaseContext) {
  if (await readReleaseReceipt(r2, prefix, context)) return;
  // Older releases have no source receipt. They require an explicit audit;
  // absence of a receipt never licenses a new run to claim their bytes.
  if (await githubReleaseAssets(context.tag!) || await r2.file(`${prefix}/v${context.version}/manifest.json`).exists()) {
    throw new Error("Existing CLI release has no source receipt; refusing to replace it");
  }
  for (const target of context.targets) {
    const key = `${prefix}/v${context.version}/${artifactName(context.version, target)}`;
    if (await r2.file(key).exists() || await r2.file(`${key}.sha256`).exists()) throw new Error("Existing CLI archive has no source receipt; refusing to replace it");
  }
  const stable = r2.file(`${prefix}/manifest.json`);
  if (await stable.exists() && (JSON.parse(await stable.text()) as UpdateManifest).version === context.version) {
    throw new Error("Stable version already exists without a source receipt; refusing to claim it");
  }
  await writeReleaseObject(r2, `${prefix}/v${context.version}/release.json`, new TextEncoder().encode(`${JSON.stringify(expectedReceipt(context), null, 2)}\n`), "application/json");
}

function artifactName(version: string, target: string) {
  return `inline-cli-${version}-${target}.tar.gz`;
}

async function writeOutputs(values: Record<string, string>) {
  if (process.env.GITHUB_OUTPUT) await appendFile(process.env.GITHUB_OUTPUT, Object.entries(values).map(([key, value]) => `${key}=${value}\n`).join(""));
}

export type HomebrewHashes = {
  macosArm: string;
  linuxArm: string;
  linuxIntel: string;
};

type GitHubReleaseAsset = {
  name: string;
  digest?: string | null;
};

async function runRelease(r2: S3Client, publicBaseUrl: string, prefix: string) {
  const context = await getReleaseContext(true);
  await preflightHomebrewCask(context);
  await runBuild(context);
  await signAndNotarize(context);
  await publishArtifacts(r2, publicBaseUrl, prefix, context);

  logPublishedRelease(publicBaseUrl, prefix, context);
}

async function runBuildArtifacts() {
  const context = await getReleaseContext();
  await runBuild(context);
  await signAndNotarize(context);
  console.log(`Built Inline CLI v${context.version} for ${context.targets.join(", ")}`);
}

async function runPublish(r2: S3Client, publicBaseUrl: string, prefix: string) {
  const context = await getReleaseContext(true);
  await preflightHomebrewCask(context);
  await publishArtifacts(r2, publicBaseUrl, prefix, context);
  logPublishedRelease(publicBaseUrl, prefix, context);
}

async function publishArtifacts(
  r2: S3Client,
  publicBaseUrl: string,
  prefix: string,
  context: ReleaseContext,
) {
  await releaseSigner();
  await ensureReleaseReceipt(r2, prefix, context);
  await runPackageManifest(r2, publicBaseUrl, prefix, context);
  await prepareSignedManifests(r2, prefix, context);
  const bundlePath = join(context.releaseDir, `inline-cli-v${context.version}-bundle.tar.gz`);
  const bundleKey = `${prefix}/v${context.version}/${basename(bundlePath)}`;
  if (await r2.file(bundleKey).exists()) {
    await writeFile(bundlePath, new Uint8Array(await r2.file(bundleKey).arrayBuffer()));
  } else {
    await createBundle(context);
    await writeReleaseObject(r2, bundleKey, new Uint8Array(await readFile(bundlePath)), "application/gzip");
  }
  await publishGitHubRelease(context);
  await publishSignedChannels(r2, publicBaseUrl, prefix, context);
  // New bootstrap scripts require the signed feed. Advance them only after
  // the public feed is verified, including the first signed stable release.
  await publishStableEntryPoints(r2, prefix, context);
  await writeOutputs({ outcome: publicationChanged ? "published" : "already-current", reason: publicationChanged ? "release publication completed" : "all published content already matches" });
}

function signedReleaseChannels(version: string): Channel[] { return isPrereleaseVersion(version) ? ["alpha"] : ["stable", "alpha"]; }

async function prepareSignedManifests(r2: S3Client, prefix: string, context: ReleaseContext) {
  const manifest = JSON.parse(await readFile(join(context.releaseDir, "manifest.json"), "utf8"));
  for (const channel of signedReleaseChannels(context.version)) {
    const signed = await signedChannel(manifest, channel);
    await writeReleaseObject(r2, `${prefix}/v${context.version}/channel.${channel}.json`, new TextEncoder().encode(signed), "application/json");
    await writeFile(join(context.releaseDir, `channel.${channel}.json`), signed);
  }
}

export function shouldAdvanceSignedChannel(current: { version: string; sourceSha: string; generation: number } | null, next: { version: string; sourceSha: string; generation: number }): boolean {
  if (!current) return true;
  const order = Bun.semver.order(current.version, next.version);
  if (order > 0) return false;
  if (order === 0 && current.sourceSha !== next.sourceSha) throw new Error("Signed channel version already belongs to another source");
  if (next.generation < current.generation) throw new Error("Signed channel generation must not decrease");
  return true;
}

async function publishSignedChannels(r2: S3Client, publicBaseUrl: string, prefix: string, context: ReleaseContext) {
  const channels = signedReleaseChannels(context.version);
  for (const channel of channels) {
    const key = `${prefix}/channels/${channel}.json`;
    const signed = await readFile(join(context.releaseDir, `channel.${channel}.json`));
    const next = await authenticatedChannelVersion(signed.toString("utf8"), channel);
    const current = await r2.file(key).exists() ? await authenticatedChannelVersion(await r2.file(key).text(), channel) : null;
    if (!shouldAdvanceSignedChannel(current, next)) continue;
    await writeReleaseObject(r2, key, signed, "application/json", false);
    const response = await fetch(`${publicBaseUrl}/${key}?verify=${Date.now()}`, { signal: AbortSignal.timeout(15_000), cache: "no-store" });
    if (!response.ok) throw new Error("Signed channel public readback failed");
    const publicCopy = await response.text();
    const verified = await authenticatedChannelVersion(publicCopy, channel);
    if (verified.version !== context.version || verified.sourceSha !== context.sourceSha || publicCopy !== signed.toString("utf8")) throw new Error("Signed channel publication verification failed");
  }
}

export async function publishStableEntryPoints(r2: S3Client, prefix: string, context: ReleaseContext) {
  if (isPrereleaseVersion(context.version)) {
    console.log("Skipping stable manifest, installer, and Homebrew for prerelease.");
  } else if (await mayAdvanceStableRelease(r2, prefix, context)) {
    await uploadFile(r2, `${prefix}/manifest.json`, join(context.releaseDir, "manifest.json"), "application/json");
    await uploadInstall(r2, prefix);
    await updateHomebrewCask(context);
  }
  await publishAlphaEntryPoint(r2, prefix, context);
}

// A declaration, not a const: the entry point above runs before later consts initialize.
export function alphaManifestKey(prefix: string) {
  return `${prefix}/alpha/manifest.json`;
}

// The alpha channel follows the newest release of any kind, so Mac Tip and
// opted-in CLIs move from alphas onto the stable that supersedes them.
async function publishAlphaEntryPoint(r2: S3Client, prefix: string, context: ReleaseContext) {
  const alpha = r2.file(alphaManifestKey(prefix));
  const current = await alpha.exists() ? JSON.parse(await alpha.text()) as UpdateManifest : null;
  if (!shouldAdvanceAlphaManifest(current, context)) {
    console.log(`Alpha manifest already names newer v${current!.version}; retaining it.`);
    return;
  }
  await uploadFile(r2, alphaManifestKey(prefix), join(context.releaseDir, "manifest.json"), "application/json");
}

export function shouldAdvanceAlphaManifest(current: Pick<UpdateManifest, "version" | "sourceSha"> | null, context: Pick<ReleaseContext, "version" | "sourceSha">) {
  if (!current) return true;
  parseCliReleaseTag(`cli-v${current.version}`);
  const order = Bun.semver.order(current.version, context.version);
  if (order > 0) return false;
  if (order === 0 && current.sourceSha && current.sourceSha !== context.sourceSha) throw new Error("Alpha version is already bound to another source");
  return true;
}

async function mayAdvanceStableRelease(r2: S3Client, prefix: string, context: ReleaseContext) {
  const stable = r2.file(`${prefix}/manifest.json`);
  if (!(await stable.exists())) return true;
  const current = JSON.parse(await stable.text()) as UpdateManifest;
  parseCliReleaseTag(`cli-v${current.version}`);
  if (isPrereleaseVersion(current.version)) throw new Error("Stable manifest unexpectedly names a prerelease");
  const newer = current.version.split(".").map(BigInt);
  const selected = context.version.split(".").map(BigInt);
  for (let index = 0; index < 3; index++) {
    if (newer[index]! > selected[index]!) {
      console.log(`Stable manifest already names newer v${current.version}; retaining it and Homebrew.`);
      return false;
    }
    if (newer[index]! < selected[index]!) return true;
  }
  if (current.sourceSha && current.sourceSha !== context.sourceSha) throw new Error("Stable version is already bound to another source");
  return true;
}

function isLinuxTarget(target: string): boolean {
  return target.includes("-unknown-linux-");
}

async function ensureRustTargetsInstalled(targets: readonly string[]) {
  const result = await runCommandCapture("rustup", ["target", "list", "--installed"]);
  if (result.exitCode !== 0) {
    throw new Error(`Failed to read installed Rust targets: ${result.stderr || result.stdout}`);
  }

  const installed = new Set(
    result.stdout
      .split("\n")
      .map((item) => item.trim())
      .filter((item) => item.length > 0),
  );
  const missing = targets.filter((target) => !installed.has(target));
  if (missing.length > 0) {
    throw new Error(
      `Missing Rust targets: ${missing.join(", ")}. Install with: rustup target add ${missing.join(" ")}`,
    );
  }
}

async function hasCargoZigbuild(): Promise<boolean> {
  const result = await runCommandCapture("cargo", ["zigbuild", "--help"], { cwd: cliDir });
  return result.exitCode === 0;
}

async function rustHostTarget(): Promise<string | null> {
  const result = await runCommandCapture("rustc", ["-vV"]);
  if (result.exitCode !== 0) {
    return null;
  }
  return result.stdout.match(/^host:\s*(\S+)/m)?.[1] ?? null;
}

export async function buildArgsForTarget(
  target: string,
  canZigbuild: boolean,
  hostTarget: string | null,
): Promise<string[]> {
  // GNU releases must not inherit the CI runner's newer glibc requirement.
  // Umbrel and its Hermes container can run an older Debian userspace.
  const gnuLinux = target.endsWith("-unknown-linux-gnu");
  if (!isLinuxTarget(target) || (target === hostTarget && !gnuLinux)) {
    return ["build", "--release", "--locked", "--target", target];
  }
  if (!canZigbuild) {
    throw new Error(
      `Portable Linux builds for ${target} require cargo-zigbuild. Install with: cargo install cargo-zigbuild --locked`,
    );
  }
  return ["zigbuild", "--release", "--locked", "--target", gnuLinux ? `${target}.2.28` : target];
}

async function runBuild(context: ReleaseContext) {
  await ensureRustTargetsInstalled(context.targets);
  const canZigbuild = await hasCargoZigbuild();
  const hostTarget = await rustHostTarget();

  for (const target of context.targets) {
    const args = await buildArgsForTarget(target, canZigbuild, hostTarget);
    await runCommand("cargo", args, { cwd: cliDir });
  }
  console.log("Build complete.");
}

async function runPackageManifest(
  r2: S3Client,
  publicBaseUrl: string,
  prefix: string,
  context: ReleaseContext,
) {
  const manifest = await buildManifest(context, publicBaseUrl, prefix, r2);
  const manifestPath = join(context.releaseDir, "manifest.json");
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await writeReleaseObject(r2, `${prefix}/v${context.version}/manifest.json`, new Uint8Array(await readFile(manifestPath)), "application/json");
  console.log("Manifest packaged and uploaded.");
}

async function uploadInstall(r2: S3Client, prefix: string) {
  const installPath = join(cliDir, "install.sh");
  await uploadFile(r2, `${prefix}/install.sh`, installPath, "text/x-shellscript");
}

export async function buildManifest(
  context: ReleaseContext,
  publicBaseUrl: string,
  prefix: string,
  r2: S3Client,
): Promise<UpdateManifest> {
  const existing = r2.file(`${prefix}/v${context.version}/manifest.json`);
  const previous = await existing.exists() ? JSON.parse(await existing.text()) as UpdateManifest : null;
  if (previous && (previous.version !== context.version || previous.tag !== context.tag || previous.sourceSha !== context.sourceSha)) throw new Error("Existing versioned manifest belongs to another release");
  const manifest: UpdateManifest = {
    version: context.version,
    tag: context.tag!,
    sourceSha: context.sourceSha,
    publishedAt: previous?.publishedAt ?? new Date().toISOString(),
    installUrl: `${publicBaseUrl}/${prefix}/install.sh`,
    targets: {},
  };

  for (const target of context.targets) {
    const binaryPath = join(targetDir, target, "release", "inline");
    const name = artifactName(context.version, target);
    const artifactPath = join(context.releaseDir, name);
    const key = `${prefix}/v${context.version}/${name}`;
    if (await r2.file(key).exists()) {
      await writeFile(artifactPath, new Uint8Array(await r2.file(key).arrayBuffer()));
      console.log(`Reusing published ${name}`);
    } else {
      await stat(binaryPath).catch(() => { throw new Error(`Missing built CLI artifact: ${target}`); });
      await runCommand("tar", ["-czf", artifactPath, "-C", dirname(binaryPath), "inline"]);
    }

    const sha256 = await sha256File(artifactPath);
    const shaPath = `${artifactPath}.sha256`;
    await writeFile(shaPath, `${sha256}  ${name}\n`);

    const size = (await stat(artifactPath)).size;
    const publicUrl = `${publicBaseUrl}/${prefix}/v${context.version}/${name}`;

    manifest.targets[target] = {
      url: publicUrl,
      sha256,
      size,
    };

    await writeReleaseObject(r2, key, new Uint8Array(await readFile(artifactPath)), "application/gzip");
    await writeReleaseObject(r2, `${key}.sha256`, new Uint8Array(await readFile(shaPath)), "text/plain");
  }
  if (previous && JSON.stringify(previous) !== JSON.stringify(manifest)) throw new Error("Existing versioned manifest content differs from its published archives");
  return manifest;
}

async function signAndNotarize(context: ReleaseContext) {
  const macTargets = context.targets.filter((target) => target.endsWith("-apple-darwin"));
  if (macTargets.length === 0) {
    console.log("Skipping sign/notarize (no macOS targets selected).");
    return;
  }

  if (!signingIdentity) {
    throw new Error("Missing signing env var: APPLE_SIGNING_IDENTITY");
  }
  const hasApiKey =
    Boolean(appleNotarizationKey) &&
    Boolean(appleNotarizationKeyId) &&
    Boolean(appleNotarizationIssuer);
  const hasAppleId = Boolean(appleId) && Boolean(applePassword) && Boolean(appleTeamId);
  if (!skipNotarize && !hasApiKey && !hasAppleId) {
    throw new Error(
      "Missing notarization env vars: provide APPLE_NOTARIZATION_KEY, APPLE_NOTARIZATION_KEY_ID, APPLE_NOTARIZATION_ISSUER or APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID",
    );
  }

  const notarizeRetries = Number.parseInt(process.env.INLINE_NOTARY_RETRIES ?? "4", 10);
  const notarizeMaxAttempts = Number.isFinite(notarizeRetries)
    ? Math.max(1, notarizeRetries + 1)
    : 5;
  const notarizeBaseDelayMs = Number.parseInt(
    process.env.INLINE_NOTARY_RETRY_BASE_DELAY_MS ?? "30000",
    10,
  );
  const notarizeMaxDelayMs = Number.parseInt(
    process.env.INLINE_NOTARY_RETRY_MAX_DELAY_MS ?? "300000",
    10,
  );

  const keyPath =
    !skipNotarize && hasApiKey ? join(context.releaseDir, "notarization-key.p8") : null;
  if (keyPath && appleNotarizationKey) {
    await writeFile(keyPath, appleNotarizationKey, { mode: 0o600 });
  }

  try {
    for (const target of macTargets) {
      const binaryPath = join(targetDir, target, "release", "inline");
      const zipName = `inline-cli-${context.version}-${target}-notarize.zip`;
      const zipPath = join(context.releaseDir, zipName);

      await runCommand(
        "codesign",
        [
          "--force",
          "--identifier",
          "chat.inline.cli",
          "--options",
          "runtime",
          "--timestamp",
          "--sign",
          signingIdentity,
          binaryPath,
        ],
        { cwd: cliDir },
      );

      await runCommand("codesign", ["--verify", "--strict", "--verbose=2", binaryPath], {
        cwd: cliDir,
      });

      if (skipNotarize) {
        console.log(`Skipping notarization for ${target} (INLINE_SKIP_NOTARIZE=1).`);
        continue;
      }

      await runCommand("zip", ["-j", "-X", zipPath, binaryPath], { cwd: cliDir });

      const args = notarytoolSubmitArgs(zipPath, keyPath);

      for (let attempt = 1; attempt <= notarizeMaxAttempts; attempt += 1) {
        const { stdout, stderr, exitCode } = await runCommandCapture("xcrun", args, {
          cwd: cliDir,
        });
        if (stdout) process.stdout.write(stdout);
        if (stderr) process.stderr.write(stderr);

        if (exitCode === 0) {
          break;
        }

        const combined = `${stdout}\n${stderr}`;
        const retryable = shouldRetryNotarize(combined);
        const isLastAttempt = attempt === notarizeMaxAttempts;

        if (!retryable || isLastAttempt) {
          throw new Error(`Command failed: xcrun ${redactArgs(args).join(" ")}`);
        }

        const exp = attempt - 1;
        const baseDelay = Number.isFinite(notarizeBaseDelayMs) ? notarizeBaseDelayMs : 30000;
        const maxDelay = Number.isFinite(notarizeMaxDelayMs) ? notarizeMaxDelayMs : 300000;
        const delay = Math.min(maxDelay, baseDelay * 2 ** exp);
        console.warn(
          `Notarization upload failed (attempt ${attempt}/${notarizeMaxAttempts}); retrying in ${Math.round(
            delay / 1000,
          )}s...`,
        );
        await sleep(delay);
      }

    }
  } finally {
    if (keyPath) {
      await rm(keyPath, { force: true });
    }
  }
}

function notarytoolSubmitArgs(zipPath: string, keyPath: string | null): string[] {
  const args = ["notarytool", "submit", zipPath];
  if (keyPath) {
    args.push("--key", keyPath);
    args.push("--key-id", appleNotarizationKeyId ?? "");
    args.push("--issuer", appleNotarizationIssuer ?? "");
  } else {
    args.push("--apple-id", appleId ?? "");
    args.push("--password", applePassword ?? "");
    args.push("--team-id", appleTeamId ?? "");
  }
  args.push("--wait", "--timeout", "60m", "--no-s3-acceleration");
  return args;
}

async function createBundle(context: ReleaseContext) {
  const bundleWorkDir = join(tempAssetsDir, `bundle-v${context.version}-${Date.now()}`);
  await mkdir(bundleWorkDir, { recursive: true });

  const manifestPath = join(context.releaseDir, "manifest.json");
  await copyFile(manifestPath, join(bundleWorkDir, "manifest.json"));
  for (const channel of signedReleaseChannels(context.version)) {
    await copyFile(join(context.releaseDir, `channel.${channel}.json`), join(bundleWorkDir, `channel.${channel}.json`));
  }
  await copyFile(join(cliDir, "release-keys.json"), join(bundleWorkDir, "release-keys.json"));
  await copyFile(join(cliDir, "install.sh"), join(bundleWorkDir, "install.sh"));

  for (const target of context.targets) {
    const artifactName = `inline-cli-${context.version}-${target}.tar.gz`;
    const artifactPath = join(context.releaseDir, artifactName);
    await copyFile(artifactPath, join(bundleWorkDir, artifactName));
    await copyFile(`${artifactPath}.sha256`, join(bundleWorkDir, `${artifactName}.sha256`));
  }

  const bundleName = `inline-cli-v${context.version}-bundle.tar.gz`;
  const bundlePath = join(context.releaseDir, bundleName);
  await runCommand("tar", ["-czf", bundlePath, "-C", bundleWorkDir, "."]);
  console.log(`Bundle created: ${bundlePath}`);
}

type HomebrewCaskState = HomebrewHashes & {
  version: string;
};

function hasHomebrewReleaseTargets(context: ReleaseContext): boolean {
  return Object.values(homebrewTargets).every((target) => context.targets.includes(target));
}

function parseHomebrewCaskContents(contents: string): HomebrewCaskState {
  const version = contents.match(/^  version "([^"]+)"$/m)?.[1];
  if (!version) {
    throw new Error("Homebrew cask must declare a top-level version.");
  }

  const macosBlock = contents.match(/^  on_macos do\n([\s\S]*?)^  end$/m)?.[1];
  if (
    !macosBlock ||
    !/^    depends_on arch: :arm64$/m.test(macosBlock) ||
    !macosBlock.includes("aarch64-apple-darwin")
  ) {
    throw new Error("Homebrew cask must keep the macOS download restricted to Apple silicon.");
  }
  const macosArm = macosBlock.match(/^    sha256 "([a-f0-9]{64})"$/m)?.[1];
  if (!macosArm) {
    throw new Error("Homebrew cask must define the Apple-silicon checksum inside on_macos.");
  }

  const linuxBlock = contents.match(/^  on_linux do\n([\s\S]*?)^  end$/m)?.[1];
  if (
    !linuxBlock ||
    !/^    arch arm: "aarch64", intel: "x86_64"$/m.test(linuxBlock) ||
    !linuxBlock.includes("#{arch}-unknown-linux-gnu")
  ) {
    throw new Error("Homebrew cask must define ARM64 and x86_64 Linux downloads.");
  }
  const linuxHashes = linuxBlock.match(
    /^    sha256 arm64_linux:\s+"([a-f0-9]{64})",\n\s+x86_64_linux:\s+"([a-f0-9]{64})"$/m,
  );
  if (!linuxHashes) {
    // Homebrew does not reinterpret arm/intel checksum keys inside on_linux.
    throw new Error(
      "Homebrew cask Linux checksums must use arm64_linux and x86_64_linux keys.",
    );
  }

  return {
    version,
    macosArm,
    linuxArm: linuxHashes[1],
    linuxIntel: linuxHashes[2],
  };
}

export function validateHomebrewCaskContents(contents: string): void {
  parseHomebrewCaskContents(contents);
}

export function updateHomebrewCaskContents(
  contents: string,
  version: string,
  hashes: HomebrewHashes,
): string {
  parseHomebrewCaskContents(contents);
  for (const [platform, sha256] of Object.entries(hashes)) {
    if (!/^[a-f0-9]{64}$/.test(sha256)) {
      throw new Error(`Invalid Homebrew sha256 for ${platform}: expected 64 lowercase hex digits.`);
    }
  }

  const updated = contents
    .replace(/^  version "[^"]+"$/m, `  version "${version}"`)
    .replace(
      /(^  on_macos do\n[\s\S]*?^    sha256 )"[a-f0-9]{64}"$/m,
      `$1"${hashes.macosArm}"`,
    )
    .replace(
      /(^  on_linux do\n[\s\S]*?^    sha256 arm64_linux:\s+)"[a-f0-9]{64}",\n(\s+x86_64_linux:\s+)"[a-f0-9]{64}"$/m,
      `$1"${hashes.linuxArm}",\n$2"${hashes.linuxIntel}"`,
    );

  const result = parseHomebrewCaskContents(updated);
  if (
    result.version !== version ||
    result.macosArm !== hashes.macosArm ||
    result.linuxArm !== hashes.linuxArm ||
    result.linuxIntel !== hashes.linuxIntel
  ) {
    throw new Error("Failed to update every version/checksum field in the Homebrew cask.");
  }
  return updated;
}

async function readValidatedHomebrewCask() {
  const caskPath = join(homebrewTapPath, "Casks", "inline.rb");
  await stat(caskPath).catch(() => {
    throw new Error(
      `Homebrew tap not found at ${caskPath}. Set INLINE_HOMEBREW_TAP_PATH if needed.`,
    );
  });

  const status = await runCommandCapture("git", ["status", "--porcelain"], {
    cwd: homebrewTapPath,
  });
  if (status.exitCode !== 0) {
    throw new Error(`Failed to check Homebrew tap status: ${status.stderr || status.stdout}`);
  }
  if (status.stdout.trim()) {
    throw new Error("Homebrew tap has uncommitted changes. Commit/stash before release.");
  }

  const contents = await readFile(caskPath, "utf8");
  validateHomebrewCaskContents(contents);
  return { caskPath, contents };
}

async function preflightHomebrewCask(context: ReleaseContext) {
  if (
    isPrereleaseVersion(context.version) ||
    process.env.INLINE_SKIP_HOMEBREW === "1" ||
    !hasHomebrewReleaseTargets(context)
  ) {
    return;
  }
  await readValidatedHomebrewCask();
}

async function updateHomebrewCask(context: ReleaseContext, hashes?: HomebrewHashes) {
  if (process.env.INLINE_SKIP_HOMEBREW === "1") {
    console.log("Skipping Homebrew cask update (INLINE_SKIP_HOMEBREW=1).");
    return;
  }

  if (!hasHomebrewReleaseTargets(context)) {
    console.log(
      "Skipping Homebrew cask update (required targets not present: macOS arm + Linux gnu arm/intel).",
    );
    return;
  }

  const { caskPath, contents } = await readValidatedHomebrewCask();
  const caskRelativePath = join("Casks", "inline.rb");
  const artifact = (target: string) =>
    join(context.releaseDir, `inline-cli-${context.version}-${target}.tar.gz`);
  const nextHashes =
    hashes ??
    ({
      macosArm: await sha256File(artifact(homebrewTargets.macosArm)),
      linuxArm: await sha256File(artifact(homebrewTargets.linuxArm)),
      linuxIntel: await sha256File(artifact(homebrewTargets.linuxIntel)),
    } satisfies HomebrewHashes);
  const updated = updateHomebrewCaskContents(contents, context.version, nextHashes);

  if (updated === contents) {
    console.log("Homebrew cask already up to date.");
    return;
  }

  await writeFile(caskPath, updated);

  const branch = await runCommandCapture("git", ["rev-parse", "--abbrev-ref", "HEAD"], {
    cwd: homebrewTapPath,
  });
  if (branch.exitCode !== 0) {
    throw new Error(`Failed to read Homebrew tap branch: ${branch.stderr || branch.stdout}`);
  }

  await runCommand("git", ["add", caskRelativePath], { cwd: homebrewTapPath });
  await runCommand(
    "git",
    ["commit", "-m", `cask: bump inline to v${context.version}`],
    { cwd: homebrewTapPath },
  );
  await runCommand("git", ["push", homebrewTapRemote, branch.stdout.trim()], {
    cwd: homebrewTapPath,
  });
  publicationChanged = true;
  console.log("Homebrew cask updated and pushed.");
}

export function releaseTag(version: string): string {
  return parseCliReleaseTag(`cli-v${version}`).tag;
}

export function parseRemoteReleaseTag(output: string, tag: string): string {
  parseCliReleaseTag(tag);
  const refs = new Map(output.trim().split("\n").filter(Boolean).map((line) => { const [sha, ref] = line.split(/\s+/); return [ref!, sha!] as const; }));
  const sha = refs.get(`refs/tags/${tag}^{}`) ?? refs.get(`refs/tags/${tag}`);
  if (!sha || !/^[a-f0-9]{40}$/.test(sha)) throw new Error(`Existing exact release tag not found: ${tag}`);
  return sha;
}

async function assertExistingReleaseTag(context: ReleaseContext) {
  const tag = context.tag!;
  const remote = await runCommandCapture("git", ["ls-remote", "--tags", `https://github.com/${githubRepo}.git`, `refs/tags/${tag}`, `refs/tags/${tag}^{}`], { cwd: rootDir });
  if (remote.exitCode !== 0) throw new Error(`Failed to verify existing release tag: ${remote.stderr}`);
  if (parseRemoteReleaseTag(remote.stdout, tag) !== context.sourceSha || (githubReleaseTarget && githubReleaseTarget !== context.sourceSha)) {
    throw new Error("Release tag, selected commit, and checkout must match exactly");
  }
}

export function planGitHubReleaseUploads(existing: readonly GitHubReleaseAsset[], expected: ReadonlyMap<string, string>) {
  const present = new Map(existing.map((asset) => [asset.name, asset]));
  for (const asset of existing) {
    const sha = expected.get(asset.name);
    if (!sha) throw new Error(`Unexpected existing GitHub release asset: ${asset.name}`);
    if (asset.digest && asset.digest !== `sha256:${sha}`) throw new Error(`Different existing GitHub release asset: ${asset.name}`);
  }
  return [...expected.keys()].filter((name) => !present.has(name));
}

async function publishGitHubRelease(context: ReleaseContext) {
  await assertExistingReleaseTag(context);
  const tag = context.tag!;
  const paths = githubReleaseAssetPaths(context);
  const expected = new Map(await Promise.all(paths.map(async (asset) => [basename(asset), await sha256File(asset)] as const)));
  let existing = await githubReleaseAssets(tag);
  if (!existing) {
    const args = ["release", "create", tag, "--repo", githubRepo, "--verify-tag", "--generate-notes", "--title", `Inline CLI v${context.version}`];
    if (isPrereleaseVersion(context.version)) args.push("--prerelease", "--latest=false");
    await runCommand("gh", args, { cwd: rootDir });
    publicationChanged = true;
    existing = [];
  }
  const missing = planGitHubReleaseUploads(existing, expected);
  // GitHub may omit a digest on an old asset. Download and hash it rather than
  // treating a matching name as proof of matching content.
  for (const asset of existing.filter((asset) => !asset.digest)) {
    const directory = join(tempAssetsDir, `verify-${Date.now()}-${asset.name}`);
    await mkdir(directory, { recursive: true });
    await runCommand("gh", ["release", "download", tag, "--repo", githubRepo, "--pattern", asset.name, "--dir", directory]);
    if (await sha256File(join(directory, asset.name)) !== expected.get(asset.name)) throw new Error(`Different existing GitHub release asset: ${asset.name}`);
  }
  if (missing.length) {
    await runCommand("gh", ["release", "upload", tag, "--repo", githubRepo, ...paths.filter((asset) => missing.includes(basename(asset)))], { cwd: rootDir });
    publicationChanged = true;
  }
  const verified = await githubReleaseAssets(tag);
  if (!verified || planGitHubReleaseUploads(verified, expected).length) throw new Error("GitHub release is missing expected assets after publication");
}

function githubReleaseAssetPaths(context: ReleaseContext): string[] {
  const assets: string[] = [];
  for (const target of context.targets) {
    const artifactName = `inline-cli-${context.version}-${target}.tar.gz`;
    const artifactPath = join(context.releaseDir, artifactName);
    assets.push(artifactPath, `${artifactPath}.sha256`);
  }

  assets.push(join(context.releaseDir, `inline-cli-v${context.version}-bundle.tar.gz`));
  for (const channel of signedReleaseChannels(context.version)) assets.push(join(context.releaseDir, `channel.${channel}.json`));
  return assets;
}

async function githubReleaseAssets(tag: string): Promise<GitHubReleaseAsset[] | null> {
  const result = await runCommandCapture(
    "gh",
    ["release", "view", tag, "--repo", githubRepo, "--json", "assets,tagName,isPrerelease,isDraft"],
    { cwd: rootDir },
  );
  if (result.exitCode !== 0) {
    const output = `${result.stdout}\n${result.stderr}`;
    if (/release not found|not found|404/i.test(output)) {
      return null;
    }
    throw new Error(`Failed to check GitHub release ${tag}: ${result.stderr || result.stdout}`);
  }

  const data = JSON.parse(result.stdout) as { assets: GitHubReleaseAsset[]; tagName: string; isPrerelease: boolean; isDraft: boolean };
  if (data.tagName !== tag || data.isDraft || data.isPrerelease !== isPrereleaseVersion(parseCliReleaseTag(tag).version)) throw new Error("Existing GitHub release has a different tag, channel, or draft state");
  return data.assets;
}

async function getReleaseContext(publication = false): Promise<ReleaseContext> {
  const publicWorkspaceRoot = dirname(await realpath(cliDir));
  const version = await readCargoVersion(join(publicWorkspaceRoot, "Cargo.toml"));
  const tag = process.env.INLINE_CLI_RELEASE_TAG;
  if (publication && !tag) throw new Error("Publication requires INLINE_CLI_RELEASE_TAG naming an existing exact tag");
  if (tag && parseCliReleaseTag(tag).version !== version) throw new Error("Cargo workspace version must be stamped from the release tag before building or publishing");
  const targets = getReleaseTargets();
  if (publication && JSON.stringify([...targets].sort()) !== JSON.stringify([...defaultTargets].sort())) throw new Error("Publication requires all five CLI release targets");
  const checkout = await runCommandCapture("git", ["rev-parse", "HEAD"], { cwd: rootDir });
  const sourceSha = checkout.stdout.trim();
  if (checkout.exitCode !== 0 || !/^[a-f0-9]{40}$/.test(sourceSha)) throw new Error("Expected an exact release checkout");

  await mkdir(distDir, { recursive: true });
  const releaseDir = join(distDir, `v${version}`);
  await mkdir(releaseDir, { recursive: true });

  await mkdir(tempAssetsDir, { recursive: true });

  const context = { version, targets, releaseDir, tag, sourceSha };
  if (publication) await assertExistingReleaseTag(context);
  return context;
}

function getReleaseTargets(): string[] {
  const raw = process.env.INLINE_CLI_TARGETS?.trim();
  if (!raw) {
    return [...defaultTargets];
  }

  const targets = raw
    .split(",")
    .map((target) => target.trim())
    .filter((target) => target.length > 0);
  if (targets.length === 0) {
    throw new Error("INLINE_CLI_TARGETS is set but empty.");
  }

  const supported = new Set<string>(supportedTargets);
  const invalid = targets.filter((target) => !supported.has(target));
  if (invalid.length > 0) {
    throw new Error(
      `Unsupported target(s): ${invalid.join(", ")}. Supported targets: ${supportedTargets.join(
        ", ",
      )}`,
    );
  }

  return [...new Set(targets)];
}

type UpdateManifest = {
  version: string;
  tag: string;
  sourceSha: string;
  publishedAt: string;
  installUrl: string;
  targets: Record<string, { url: string; sha256: string; size: number }>;
};
