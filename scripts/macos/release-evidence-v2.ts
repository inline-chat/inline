import { createHash } from "node:crypto";
import {
  closeSync,
  existsSync,
  lstatSync,
  openSync,
  readFileSync,
  readlinkSync,
  readSync,
  writeFileSync,
} from "node:fs";
import { resolve } from "node:path";

export type ReleaseChannel = "stable" | "beta" | "tip";

export type SourceFileEvidence = {
  path: string;
  sha256: string;
};

export type SourceEnumerationEvidence = {
  scope: "tracked-and-untracked-nonignored";
  includedPathCount: number;
  excludedPathCount: number;
  exclusionRules: string[];
};

export type ValidationEvidence = {
  name: string;
  status: "passed" | "failed" | "skipped";
  detail?: string;
};

export type ReleaseEvidenceInput = {
  channel: ReleaseChannel;
  version: string;
  buildNumber: string;
  commit: string;
  feedURL: string;
  minimumSystemVersion: string;
  clean: boolean;
  sourceFiles: SourceFileEvidence[];
  sourceEnumeration: SourceEnumerationEvidence;
  executableSha256: string;
  dmgSha256: string;
  executableUUIDs: string[];
  dSYMUUIDs: string[];
  toolchain: { xcode: string; swift: string; macOS: string };
  validation: ValidationEvidence[];
  createdAt: string;
  resumedFromTask?: string;
  candidate?: boolean;
};

export type ReleaseEvidenceV2 = Omit<ReleaseEvidenceInput, "sourceFiles" | "candidate"> & {
  schemaVersion: 2;
  sourceTreeSha256: string;
  sourceFiles: SourceFileEvidence[];
};

export type SourceEvidenceDependencies = {
  listPaths?: (rootDir: string) => string[];
  digestPath?: (rootDir: string, relativePath: string) => string;
};

export type EvidenceCommandRunner = (command: string[], cwd: string) => string;

export type ReleaseEvidenceIntegrationMode = "disabled" | "describe-only" | "capture-and-write";

export const sourceEvidenceExclusionRules = [
  "exclude every .env* path segment before reading",
  "exclude .build, node_modules, and target path segments",
  "exclude common private-key, certificate, provisioning-profile, and credential paths",
];

export function releaseEvidenceIntegrationMode(
  enabled: boolean,
  dryRun: boolean,
): ReleaseEvidenceIntegrationMode {
  if (!enabled) return "disabled";
  return dryRun ? "describe-only" : "capture-and-write";
}

const sha256Pattern = /^[a-f0-9]{64}$/;
const forbiddenSegments = new Set([".build", "node_modules", "target"]);
const sensitiveSegments = new Set(["secrets", ".secrets", "credentials", ".credentials"]);
const sensitiveSuffixes = [".key", ".pem", ".p8", ".p12", ".mobileprovision"];

function normalizedRelativePath(path: string): string {
  const normalized = path.replaceAll("\\", "/").replace(/^\.\//, "");
  const segments = normalized.split("/");
  if (!normalized || normalized.startsWith("/") || segments.includes("..") || segments.includes("")) {
    throw new Error(`Source evidence path must be a normalized relative path: ${path}`);
  }
  if (segments.some((segment) => segment.startsWith(".env"))) {
    throw new Error(`Source evidence must never include environment files: ${path}`);
  }
  if (segments.some((segment) => forbiddenSegments.has(segment))) {
    throw new Error(`Source evidence excludes generated dependency/build paths: ${path}`);
  }
  if (
    segments.some((segment) => sensitiveSegments.has(segment.toLowerCase()))
    || sensitiveSuffixes.some((suffix) => normalized.toLowerCase().endsWith(suffix))
  ) {
    throw new Error(`Source evidence excludes credential and signing material paths: ${path}`);
  }
  return normalized;
}

export function isSourceEvidencePathAllowed(path: string): boolean {
  try {
    normalizedRelativePath(path);
    return true;
  } catch {
    return false;
  }
}

function checkedSha256(value: string, label: string): string {
  const normalized = value.toLowerCase();
  if (!sha256Pattern.test(normalized)) throw new Error(`${label} must be a SHA-256 hex digest.`);
  return normalized;
}

function checkedCommand(command: string[], cwd: string): string {
  const result = Bun.spawnSync({ cmd: command, cwd, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    const detail = result.stderr.toString().trim();
    throw new Error(`Evidence command failed: ${command.join(" ")}${detail ? `\n${detail}` : ""}`);
  }
  return result.stdout.toString().trim();
}

function defaultListPaths(rootDir: string): string[] {
  const command = ["git", "ls-files", "--cached", "--others", "--exclude-standard", "-z"];
  const result = Bun.spawnSync({ cmd: command, cwd: rootDir, stdout: "pipe", stderr: "pipe" });
  if (result.exitCode !== 0) {
    const detail = result.stderr.toString().trim();
    throw new Error(`Evidence command failed: ${command.join(" ")}${detail ? `\n${detail}` : ""}`);
  }
  // Do not trim NUL-delimited output: whitespace is valid inside a Git path.
  const output = result.stdout.toString();
  return output ? output.split("\0").filter(Boolean) : [];
}

function defaultDigestPath(rootDir: string, relativePath: string): string {
  const absolutePath = resolve(rootDir, relativePath);
  const stat = lstatSync(absolutePath);
  let bytes: Uint8Array;
  if (stat.isSymbolicLink()) {
    bytes = new TextEncoder().encode(readlinkSync(absolutePath));
  } else if (stat.isFile()) {
    bytes = readFileSync(absolutePath);
  } else if (stat.isDirectory()) {
    const gitlink = checkedCommand(["git", "rev-parse", `HEAD:${relativePath}`], rootDir);
    bytes = new TextEncoder().encode(`gitlink\0${gitlink}`);
  } else {
    throw new Error(`Unsupported source evidence file type: ${relativePath}`);
  }
  return createHash("sha256").update(bytes).digest("hex");
}

export function collectSourceFileEvidence(
  rootDir: string,
  dependencies: SourceEvidenceDependencies = {},
): { files: SourceFileEvidence[]; enumeration: SourceEnumerationEvidence } {
  const paths = (dependencies.listPaths ?? defaultListPaths)(rootDir);
  const allowedPaths = paths.filter(isSourceEvidencePathAllowed);
  const digestPath = dependencies.digestPath ?? defaultDigestPath;
  const files = allowedPaths
    .map((path) => ({ path: normalizedRelativePath(path), sha256: checkedSha256(digestPath(rootDir, path), path) }))
    .sort((left, right) => left.path.localeCompare(right.path));

  return {
    files,
    enumeration: {
      scope: "tracked-and-untracked-nonignored",
      includedPathCount: files.length,
      excludedPathCount: paths.length - allowedPaths.length,
      exclusionRules: [...sourceEvidenceExclusionRules],
    },
  };
}

export function sha256File(path: string): string {
  if (!existsSync(path)) throw new Error(`Evidence artifact not found at ${path}`);
  const descriptor = openSync(path, "r");
  const buffer = Buffer.allocUnsafe(1024 * 1024);
  const hash = createHash("sha256");
  try {
    while (true) {
      const byteCount = readSync(descriptor, buffer, 0, buffer.length, null);
      if (byteCount === 0) break;
      hash.update(buffer.subarray(0, byteCount));
    }
  } finally {
    closeSync(descriptor);
  }
  return hash.digest("hex");
}

export function parseDwarfUUIDs(output: string): string[] {
  const values = [...output.matchAll(/UUID:\s*([0-9a-fA-F-]+)\s*\(([^)]+)\)/g)].map(
    (match) => `${match[1].toUpperCase()} (${match[2].trim()})`,
  );
  return [...new Set(values)].sort();
}

export function requireMatchingDwarfUUIDs(executableUUIDs: string[], dSYMUUIDs: string[]): void {
  const executable = [...new Set(executableUUIDs)].sort();
  const symbols = [...new Set(dSYMUUIDs)].sort();
  if (!executable.length) throw new Error("The release executable has no extractable Mach-O UUIDs.");
  if (!symbols.length) throw new Error("The release dSYM has no extractable Mach-O UUIDs.");
  if (executable.length !== symbols.length || executable.some((value, index) => value !== symbols[index])) {
    throw new Error(
      `Release executable/dSYM UUID mismatch. Executable: ${executable.join(", ")}; dSYM: ${symbols.join(", ")}`,
    );
  }
}

export function extractDwarfUUIDs(
  path: string,
  cwd: string,
  run: EvidenceCommandRunner = checkedCommand,
): string[] {
  const values = parseDwarfUUIDs(run(["xcrun", "dwarfdump", "--uuid", path], cwd));
  if (!values.length) throw new Error(`No Mach-O UUIDs found for ${path}`);
  return values;
}

export function collectToolchainEvidence(
  rootDir: string,
  run: EvidenceCommandRunner = checkedCommand,
): ReleaseEvidenceInput["toolchain"] {
  return {
    xcode: run(["xcodebuild", "-version"], rootDir).replaceAll("\n", "; "),
    swift: run(["swift", "--version"], rootDir).replaceAll("\n", "; "),
    macOS: run(["sw_vers", "-productVersion"], rootDir),
  };
}

export function sourceTreeSha256(files: SourceFileEvidence[]): string {
  const canonical = files
    .map((file) => ({
      path: normalizedRelativePath(file.path),
      sha256: checkedSha256(file.sha256, file.path),
    }))
    .sort((left, right) => left.path.localeCompare(right.path));
  const paths = canonical.map((file) => file.path);
  if (new Set(paths).size !== paths.length) throw new Error("Source evidence contains duplicate paths.");
  return createHash("sha256")
    .update(canonical.map((file) => `${file.path}\0${file.sha256}\n`).join(""))
    .digest("hex");
}

export function buildReleaseEvidence(input: ReleaseEvidenceInput): ReleaseEvidenceV2 {
  if (input.candidate !== false && !input.clean) {
    throw new Error("A release candidate must be built from a clean recorded source tree.");
  }
  requireMatchingDwarfUUIDs(input.executableUUIDs, input.dSYMUUIDs);

  const sourceFiles = input.sourceFiles
    .map((file) => ({
      path: normalizedRelativePath(file.path),
      sha256: checkedSha256(file.sha256, file.path),
    }))
    .sort((left, right) => left.path.localeCompare(right.path));

  return {
    schemaVersion: 2,
    channel: input.channel,
    version: input.version,
    buildNumber: input.buildNumber,
    commit: input.commit,
    feedURL: input.feedURL,
    minimumSystemVersion: input.minimumSystemVersion,
    clean: input.clean,
    sourceTreeSha256: sourceTreeSha256(sourceFiles),
    sourceFiles,
    sourceEnumeration: {
      ...input.sourceEnumeration,
      exclusionRules: [...input.sourceEnumeration.exclusionRules].sort(),
    },
    executableSha256: checkedSha256(input.executableSha256, "executableSha256"),
    dmgSha256: checkedSha256(input.dmgSha256, "dmgSha256"),
    executableUUIDs: [...new Set(input.executableUUIDs)].sort(),
    dSYMUUIDs: [...new Set(input.dSYMUUIDs)].sort(),
    toolchain: { ...input.toolchain },
    validation: [...input.validation].sort((left, right) => left.name.localeCompare(right.name)),
    createdAt: input.createdAt,
    resumedFromTask: input.resumedFromTask || undefined,
  };
}

export function withValidationEvidence(
  evidence: ReleaseEvidenceV2,
  validation: ValidationEvidence[],
): ReleaseEvidenceV2 {
  return buildReleaseEvidence({ ...evidence, validation, candidate: true });
}

function recursivelySort(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(recursivelySort);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .filter(([, child]) => child !== undefined)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, recursivelySort(child)]),
    );
  }
  return value;
}

export function canonicalReleaseEvidenceJSON(evidence: ReleaseEvidenceV2): string {
  return `${JSON.stringify(recursivelySort(evidence), null, 2)}\n`;
}

export function writeReleaseEvidenceHistory(path: string, evidence: ReleaseEvidenceV2): void {
  writeFileSync(path, canonicalReleaseEvidenceJSON(evidence), { flag: "wx" });
}

export function v2HistoryPath(v1HistoryPath: string): string {
  if (!v1HistoryPath.endsWith(".json")) throw new Error(`Release history path must end in .json: ${v1HistoryPath}`);
  return `${v1HistoryPath.slice(0, -5)}.evidence-v2.json`;
}
