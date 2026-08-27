import { spawnSync } from "bun";
import { createHash } from "node:crypto";
import {
  chmodSync,
  copyFileSync,
  lstatSync,
  mkdirSync,
  readFileSync,
  readlinkSync,
  realpathSync,
  symlinkSync,
  writeFileSync,
} from "node:fs";
import { dirname, isAbsolute, relative, resolve, sep } from "node:path";

const sourcePathspecs = ["apple", "scripts/apple", "scripts/macos", "bun.lock"];

function isEnvironmentFile(relativePath: string): boolean {
  return relativePath.split("/").some((component) => component === ".env" || component.startsWith(".env."));
}

function gitSourcePaths(rootDir: string): string[] {
  const result = spawnSync({
    cmd: [
      "git",
      "-C",
      rootDir,
      "ls-files",
      "-z",
      "--cached",
      "--others",
      "--exclude-standard",
      "--",
      ...sourcePathspecs,
    ],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) {
    throw new Error(`Unable to enumerate macOS release source: ${new TextDecoder().decode(result.stderr).trim()}`);
  }
  return new TextDecoder()
    .decode(result.stdout)
    .split("\0")
    .filter((relativePath) => relativePath && !isEnvironmentFile(relativePath))
    .sort();
}

function assertSafeRelativePath(relativePath: string): void {
  if (isAbsolute(relativePath) || relativePath.split("/").includes("..")) {
    throw new Error(`Unsafe macOS source snapshot path: ${relativePath}`);
  }
}

function assertSafeSymlink(rootDir: string, relativePath: string, absolutePath: string): void {
  const resolvedTarget = realpathSync(absolutePath);
  const relativeTarget = relative(resolve(rootDir), resolvedTarget);
  if (
    !relativeTarget
    || isAbsolute(relativeTarget)
    || relativeTarget === ".."
    || relativeTarget.startsWith(`..${sep}`)
    || isEnvironmentFile(relativeTarget)
  ) {
    throw new Error(`Unsafe macOS source snapshot symlink: ${relativePath}`);
  }
}

function addFrame(hash: ReturnType<typeof createHash>, label: string, value: string | Uint8Array): void {
  const bytes = typeof value === "string" ? Buffer.from(value) : value;
  hash.update(`${label.length}:${label}:${bytes.byteLength}:`);
  hash.update(bytes);
}

export function macosSourceSnapshotSha256ForPaths(rootDir: string, relativePaths: string[]): string {
  const hash = createHash("sha256");
  addFrame(hash, "schema", "inline-macos-source-snapshot-v1");

  for (const relativePath of relativePaths) {
    assertSafeRelativePath(relativePath);
    const absolutePath = resolve(rootDir, relativePath);
    addFrame(hash, "path", relativePath);
    try {
      const stat = lstatSync(absolutePath);
      addFrame(hash, "mode", String(stat.mode));
      if (stat.isSymbolicLink()) {
        assertSafeSymlink(rootDir, relativePath, absolutePath);
        addFrame(hash, "symlink", readlinkSync(absolutePath));
      } else if (stat.isFile()) {
        addFrame(hash, "file", readFileSync(absolutePath));
      } else if (stat.isDirectory()) {
        addFrame(hash, "directory", "");
      } else {
        throw new Error(`Unsupported source entry type: ${relativePath}`);
      }
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") {
        addFrame(hash, "missing", "");
        continue;
      }
      throw error;
    }
  }

  return hash.digest("hex");
}

export function macosSourceSnapshotSha256(rootDir: string): string {
  return macosSourceSnapshotSha256ForPaths(rootDir, gitSourcePaths(rootDir));
}

export function macosSourceSnapshotPathsFromManifest(manifestPath: string): string[] {
  return readFileSync(manifestPath, "utf8")
    .split("\0")
    .filter(Boolean)
    .map((relativePath) => {
      assertSafeRelativePath(relativePath);
      return relativePath;
    });
}

export function stageMacosSourceSnapshot(
  rootDir: string,
  destinationRoot: string,
  manifestPath: string,
): { sha256: string; fileCount: number } {
  mkdirSync(destinationRoot, { recursive: true });
  const copiedPaths = gitSourcePaths(rootDir);

  for (const relativePath of copiedPaths) {
    assertSafeRelativePath(relativePath);
    const sourcePath = resolve(rootDir, relativePath);
    const destinationPath = resolve(destinationRoot, relativePath);
    let stat;
    try {
      stat = lstatSync(sourcePath);
    } catch (error) {
      if ((error as NodeJS.ErrnoException).code === "ENOENT") continue;
      throw error;
    }
    mkdirSync(dirname(destinationPath), { recursive: true });
    if (stat.isSymbolicLink()) {
      symlinkSync(readlinkSync(sourcePath), destinationPath);
    } else if (stat.isFile()) {
      copyFileSync(sourcePath, destinationPath);
      chmodSync(destinationPath, stat.mode & 0o777);
    } else {
      throw new Error(`Unsupported source entry type: ${relativePath}`);
    }
  }

  // Re-enumerate after copying. Comparing both roots using the final path list
  // catches additions, removals, content changes, and mode changes during copy.
  const finalPaths = gitSourcePaths(rootDir);
  if (
    copiedPaths.length !== finalPaths.length
    || copiedPaths.some((relativePath, index) => relativePath !== finalPaths[index])
  ) {
    throw new Error("macOS source paths changed while creating the experimental tip snapshot; run the release again.");
  }
  const sourceSha256 = macosSourceSnapshotSha256ForPaths(rootDir, finalPaths);
  const stagedSha256 = macosSourceSnapshotSha256ForPaths(destinationRoot, finalPaths);
  const sourceSha256AfterVerification = macosSourceSnapshotSha256(rootDir);
  if (sourceSha256 !== stagedSha256 || sourceSha256 !== sourceSha256AfterVerification) {
    throw new Error("macOS source changed while creating the experimental tip snapshot; run the release again.");
  }

  mkdirSync(dirname(manifestPath), { recursive: true });
  writeFileSync(manifestPath, `${finalPaths.join("\0")}\0`, { mode: 0o600 });
  return { sha256: stagedSha256, fileCount: finalPaths.length };
}

function cli(argv: string[]): number {
  const rootIndex = argv.indexOf("--root");
  const manifestIndex = argv.indexOf("--manifest");
  const rootDir = rootIndex === -1 ? resolve(import.meta.dir, "../..") : resolve(argv[rootIndex + 1] ?? "");
  const manifestPath = manifestIndex === -1 ? "" : resolve(argv[manifestIndex + 1] ?? "");
  if (!rootDir || (rootIndex !== -1 && !argv[rootIndex + 1]) || (manifestIndex !== -1 && !argv[manifestIndex + 1])) {
    console.error("Usage: bun run macos-source-snapshot.ts [--root <repo>] [--manifest <nul-path-list>]");
    return 2;
  }
  try {
    const sha256 = manifestPath
      ? macosSourceSnapshotSha256ForPaths(rootDir, macosSourceSnapshotPathsFromManifest(manifestPath))
      : macosSourceSnapshotSha256(rootDir);
    console.log(sha256);
    return 0;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

if (import.meta.main) process.exitCode = cli(process.argv.slice(2));
