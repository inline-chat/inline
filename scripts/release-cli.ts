import { S3Client } from "bun";
import { createHash } from "crypto";
import { copyFile, mkdir, readFile, stat, writeFile } from "fs/promises";
import { dirname, join, resolve } from "path";

const rootDir = resolve(import.meta.dir, "..");
const cliDir = join(rootDir, "cli");
const distDir = join(cliDir, "dist");
const tempAssetsDir = join(rootDir, "scripts", ".release-tmp");

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

const command = process.argv[2] ?? "release";

if (command === "upload-install") {
  const installPath = join(cliDir, "install.sh");
  await uploadFile(r2, `${prefix}/install.sh`, installPath, "text/x-shellscript");
  console.log(`Uploaded install.sh to ${publicBaseUrl}/${prefix}/install.sh`);
} else if (command === "build") {
  await runBuild();
} else if (command === "package-manifest") {
  await runPackageManifest(r2, publicBaseUrl, prefix);
} else if (command === "release") {
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
  await runBuild(context);
  await runPackageManifest(r2, publicBaseUrl, prefix, context);
  await uploadInstall(r2);
  await createBundle(context);

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
  const manifest = await buildManifest(resolvedContext, publicBaseUrl, prefix);
  const manifestPath = join(distDir, "manifest.json");
  await writeFile(manifestPath, JSON.stringify(manifest, null, 2));
  await uploadFile(r2, `${prefix}/manifest.json`, manifestPath, "application/json");
  console.log("Manifest packaged and uploaded.");
  if (!context) {
    printManualSteps();
  }
}

async function uploadInstall(r2: S3Client) {
  const installPath = join(cliDir, "install.sh");
  await uploadFile(r2, `${prefix}/install.sh`, installPath, "text/x-shellscript");
}

async function buildManifest(
  context: ReleaseContext,
  publicBaseUrl: string,
  prefix: string,
): Promise<UpdateManifest> {
  const manifest: UpdateManifest = {
    version: context.version,
    publishedAt: new Date().toISOString(),
    installUrl: `${publicBaseUrl}/${prefix}/install.sh`,
    targets: {},
  };

  for (const target of context.targets) {
    const binaryPath = join(cliDir, "target", target, "release", "inline");
    const artifactName = `inline-${context.version}-${target}.tar.gz`;
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

async function createBundle(context: ReleaseContext) {
  const bundleWorkDir = join(tempAssetsDir, `bundle-v${context.version}-${Date.now()}`);
  await mkdir(bundleWorkDir, { recursive: true });

  const manifestPath = join(distDir, "manifest.json");
  await copyFile(manifestPath, join(bundleWorkDir, "manifest.json"));
  await copyFile(join(cliDir, "install.sh"), join(bundleWorkDir, "install.sh"));

  for (const target of context.targets) {
    const artifactName = `inline-${context.version}-${target}.tar.gz`;
    const artifactPath = join(context.releaseDir, artifactName);
    await copyFile(artifactPath, join(bundleWorkDir, artifactName));
    await copyFile(`${artifactPath}.sha256`, join(bundleWorkDir, `${artifactName}.sha256`));
  }

  const bundleName = `inline-cli-v${context.version}-bundle.tar.gz`;
  const bundlePath = join(context.releaseDir, bundleName);
  await runCommand("tar", ["-czf", bundlePath, "-C", bundleWorkDir, "."]);
  console.log(`Bundle created: ${bundlePath}`);
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
  console.log("  bun tsx scripts/release-cli.ts package-manifest");
  console.log("  bun tsx scripts/release-cli.ts upload-install");
}

type UpdateManifest = {
  version: string;
  publishedAt: string;
  installUrl: string;
  targets: Record<string, { url: string; sha256: string; size: number }>;
};
