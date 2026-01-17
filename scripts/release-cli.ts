import { S3Client } from "bun";
import { createHash } from "crypto";
import { copyFile, mkdir, readFile, stat, writeFile } from "fs/promises";
import { dirname, join, resolve } from "path";

const rootDir = resolve(import.meta.dir, "..");
const cliDir = join(rootDir, "cli");
const distDir = join(cliDir, "dist");
const tempAssetsDir = join(rootDir, "scripts", ".release-tmp");
const githubRepo = process.env.INLINE_CLI_GITHUB_REPO ?? "inline-chat/inline";
const githubTagPrefix = process.env.INLINE_CLI_GITHUB_TAG_PREFIX ?? "cli-v";
const githubRemote = process.env.INLINE_CLI_GIT_REMOTE ?? "origin";
const signingIdentity = process.env.APPLE_SIGNING_IDENTITY;
const appleId = process.env.APPLE_ID;
const applePassword = process.env.APPLE_PASSWORD;
const appleTeamId = process.env.APPLE_TEAM_ID;

const command = process.argv[2] ?? "release";

if (command === "upload-install") {
  const { r2, publicBaseUrl, prefix } = getR2Context();
  const installPath = join(cliDir, "install.sh");
  await uploadFile(r2, `${prefix}/install.sh`, installPath, "text/x-shellscript");
  console.log(`Uploaded install.sh to ${publicBaseUrl}/${prefix}/install.sh`);
} else if (command === "build") {
  await runBuild();
} else if (command === "sign-notarize") {
  const context = await getReleaseContext();
  await runBuild(context);
  await signAndNotarize(context);
} else if (command === "release-dry-run") {
  const context = await getReleaseContext();
  await runBuild(context);
  await signAndNotarize(context);
  console.log("Dry run complete (build + sign + notarize + verify).");
} else if (command === "package-manifest") {
  const { r2, publicBaseUrl, prefix } = getR2Context();
  await runPackageManifest(r2, publicBaseUrl, prefix);
} else if (command === "release") {
  const { r2, publicBaseUrl, prefix } = getR2Context();
  await runRelease(r2, publicBaseUrl, prefix);
} else {
  throw new Error(`Unknown command: ${command}`);
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

function getR2Context() {
  const accessKeyId = requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
  const secretAccessKey = requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
  const bucket = requireEnv("PUBLIC_RELEASES_R2_BUCKET");
  const endpoint = requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
  const publicBaseUrl = trimSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
  const prefix = trimSlash(process.env.PUBLIC_RELEASES_R2_PREFIX || "inline-cli");

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
    throw new Error(`Command failed: ${command} ${args.join(" ")}`);
  }
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

async function uploadFile(
  r2: S3Client,
  key: string,
  path: string,
  contentType: string,
) {
  const file = r2.file(key);
  await file.write(Bun.file(path), { type: contentType });
}

type ReleaseContext = {
  version: string;
  targets: readonly string[];
  releaseDir: string;
};

async function runRelease(r2: S3Client, publicBaseUrl: string, prefix: string) {
  const context = await getReleaseContext();
  await assertNoDuplicateVersion(context);
  await runBuild(context);
  await signAndNotarize(context);
  await runPackageManifest(r2, publicBaseUrl, prefix, context);
  await uploadInstall(r2, prefix);
  await createBundle(context);
  await publishGitHubRelease(context);

  console.log(`Uploaded Inline CLI v${context.version}`);
  console.log(`Manifest: ${publicBaseUrl}/${prefix}/manifest.json`);
  console.log(`Install: ${publicBaseUrl}/${prefix}/install.sh`);
  console.log(`Install command: curl -fsSL ${publicBaseUrl}/${prefix}/install.sh | sh`);
  printManualSteps();
}

async function runBuild(context?: ReleaseContext) {
  const resolvedContext = context ?? (await getReleaseContext());
  for (const target of resolvedContext.targets) {
    await runCommand("cargo", ["build", "--release", "--target", target], { cwd: cliDir });
  }
  console.log("Build complete.");
  if (!context) {
    printManualSteps();
  }
}

async function runPackageManifest(
  r2: S3Client,
  publicBaseUrl: string,
  prefix: string,
  context?: ReleaseContext,
) {
  const resolvedContext = context ?? (await getReleaseContext());
  const manifest = await buildManifest(resolvedContext, publicBaseUrl, prefix, r2);
  const manifestPath = join(distDir, "manifest.json");
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await uploadFile(r2, `${prefix}/manifest.json`, manifestPath, "application/json");
  console.log("Manifest packaged and uploaded.");
  if (!context) {
    printManualSteps();
  }
}

async function uploadInstall(r2: S3Client, prefix: string) {
  const installPath = join(cliDir, "install.sh");
  await uploadFile(r2, `${prefix}/install.sh`, installPath, "text/x-shellscript");
}

async function buildManifest(
  context: ReleaseContext,
  publicBaseUrl: string,
  prefix: string,
  r2: S3Client,
): Promise<UpdateManifest> {
  const manifest: UpdateManifest = {
    version: context.version,
    publishedAt: new Date().toISOString(),
    installUrl: `${publicBaseUrl}/${prefix}/install.sh`,
    targets: {},
  };

  for (const target of context.targets) {
    const binaryPath = join(cliDir, "target", target, "release", "inline");
    const artifactName = `inline-cli-${context.version}-${target}.tar.gz`;
    const artifactPath = join(context.releaseDir, artifactName);

    await runCommand("tar", ["-czf", artifactPath, "-C", dirname(binaryPath), "inline"]);

    const sha256 = await sha256File(artifactPath);
    const shaPath = `${artifactPath}.sha256`;
    await writeFile(shaPath, `${sha256}  ${artifactName}\n`);

    const size = (await stat(artifactPath)).size;
    const publicUrl = `${publicBaseUrl}/${prefix}/v${context.version}/${artifactName}`;

    manifest.targets[target] = {
      url: publicUrl,
      sha256,
      size,
    };

    await uploadFile(
      r2,
      `${prefix}/v${context.version}/${artifactName}`,
      artifactPath,
      "application/gzip",
    );
    await uploadFile(
      r2,
      `${prefix}/v${context.version}/${artifactName}.sha256`,
      shaPath,
      "text/plain",
    );
  }

  return manifest;
}

async function signAndNotarize(context: ReleaseContext) {
  if (!signingIdentity || !appleId || !applePassword || !appleTeamId) {
    throw new Error(
      "Missing signing/notarization env vars: APPLE_SIGNING_IDENTITY, APPLE_ID, APPLE_PASSWORD, APPLE_TEAM_ID",
    );
  }

  for (const target of context.targets) {
    const binaryPath = join(cliDir, "target", target, "release", "inline");
    const zipName = `inline-cli-${context.version}-${target}-notarize.zip`;
    const zipPath = join(context.releaseDir, zipName);

    await runCommand(
      "codesign",
      [
        "--force",
        "--options",
        "runtime",
        "--timestamp",
        "--sign",
        signingIdentity,
        binaryPath,
      ],
      { cwd: cliDir },
    );

    await runCommand("zip", ["-j", "-X", zipPath, binaryPath], { cwd: cliDir });

    await runCommand(
      "xcrun",
      [
        "notarytool",
        "submit",
        zipPath,
        "--apple-id",
        appleId,
        "--password",
        applePassword,
        "--team-id",
        appleTeamId,
        "--wait",
      ],
      { cwd: cliDir },
    );

    await runCommand("codesign", ["--verify", "--strict", "--verbose=2", binaryPath], {
      cwd: cliDir,
    });
  }
}

async function createBundle(context: ReleaseContext) {
  const bundleWorkDir = join(tempAssetsDir, `bundle-v${context.version}-${Date.now()}`);
  await mkdir(bundleWorkDir, { recursive: true });

  const manifestPath = join(distDir, "manifest.json");
  await copyFile(manifestPath, join(bundleWorkDir, "manifest.json"));
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

function releaseTag(version: string): string {
  return `${githubTagPrefix}${version}`;
}

async function assertNoDuplicateVersion(context: ReleaseContext) {
  const tag = releaseTag(context.version);

  const localTag = await runCommandCapture("git", ["tag", "--list", tag], { cwd: rootDir });
  if (localTag.exitCode !== 0) {
    throw new Error(`Failed to check local tags: ${localTag.stderr || localTag.stdout}`);
  }
  if (localTag.stdout.trim()) {
    throw new Error(`Tag ${tag} already exists locally. Bump CLI version before releasing.`);
  }

  const remoteUrl = `https://github.com/${githubRepo}.git`;
  const remoteTag = await runCommandCapture(
    "git",
    ["ls-remote", "--tags", remoteUrl, tag],
    { cwd: rootDir },
  );
  if (remoteTag.exitCode !== 0) {
    throw new Error(`Failed to check remote tags: ${remoteTag.stderr || remoteTag.stdout}`);
  }
  if (remoteTag.stdout.trim()) {
    throw new Error(`Tag ${tag} already exists on ${githubRepo}. Bump CLI version.`);
  }
}

async function publishGitHubRelease(context: ReleaseContext) {
  const tag = releaseTag(context.version);
  const assets: string[] = [];

  for (const target of context.targets) {
    const artifactName = `inline-cli-${context.version}-${target}.tar.gz`;
    const artifactPath = join(context.releaseDir, artifactName);
    assets.push(artifactPath, `${artifactPath}.sha256`);
  }

  const bundleName = `inline-cli-v${context.version}-bundle.tar.gz`;
  const bundlePath = join(context.releaseDir, bundleName);
  assets.push(bundlePath);

  await runCommand("git", ["tag", "-a", tag, "-m", `Inline CLI v${context.version}`], {
    cwd: rootDir,
  });
  await runCommand("git", ["push", githubRemote, tag], { cwd: rootDir });
  await runCommand(
    "gh",
    [
      "release",
      "create",
      tag,
      "--repo",
      githubRepo,
      "--title",
      `Inline CLI v${context.version}`,
      "--notes",
      `Automated release for Inline CLI v${context.version}.`,
      ...assets,
    ],
    { cwd: rootDir },
  );
}

async function getReleaseContext(): Promise<ReleaseContext> {
  const version = await readCargoVersion(join(cliDir, "Cargo.toml"));
  const targets = ["aarch64-apple-darwin", "x86_64-apple-darwin"] as const;

  await mkdir(distDir, { recursive: true });
  const releaseDir = join(distDir, `v${version}`);
  await mkdir(releaseDir, { recursive: true });

  await mkdir(tempAssetsDir, { recursive: true });

  return { version, targets, releaseDir };
}

function printManualSteps() {
  console.log("Manual steps (run individually if you need to repeat only one):");
  console.log("  bun tsx scripts/release-cli.ts build");
  console.log("  bun tsx scripts/release-cli.ts sign-notarize");
  console.log("  bun tsx scripts/release-cli.ts package-manifest");
  console.log("  bun tsx scripts/release-cli.ts upload-install");
  console.log("  bun tsx scripts/release-cli.ts release-dry-run");
}

type UpdateManifest = {
  version: string;
  publishedAt: string;
  installUrl: string;
  targets: Record<string, { url: string; sha256: string; size: number }>;
};
