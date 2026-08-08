import { createHash } from "node:crypto";

export type ReleaseChannel = "stable" | "beta" | "tip";

export type SourceFileEvidence = {
  path: string;
  sha256: string;
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
  clean: boolean;
  sourceFiles: SourceFileEvidence[];
  executableSha256: string;
  dmgSha256: string;
  dSYMUUIDs: string[];
  toolchain: { xcode: string; swift: string; macOS: string };
  validation: ValidationEvidence[];
  createdAt: string;
  candidate?: boolean;
};

export type ReleaseEvidenceV2 = Omit<ReleaseEvidenceInput, "sourceFiles" | "candidate"> & {
  schemaVersion: 2;
  sourceTreeSha256: string;
  sourceFiles: SourceFileEvidence[];
};

const sha256Pattern = /^[a-f0-9]{64}$/;
const forbiddenSegments = new Set([".build", "node_modules", "target"]);

function normalizedRelativePath(path: string): string {
  const normalized = path.replaceAll("\\", "/").replace(/^\.\//, "");
  const segments = normalized.split("/");
  if (!normalized || normalized.startsWith("/") || segments.includes("..") || segments.includes("")) {
    throw new Error(`Source evidence path must be a normalized relative path: ${path}`);
  }
  if (segments.some((segment) => segment === ".env" || segment.startsWith(".env."))) {
    throw new Error(`Source evidence must never include environment files: ${path}`);
  }
  if (segments.some((segment) => forbiddenSegments.has(segment))) {
    throw new Error(`Source evidence excludes generated dependency/build paths: ${path}`);
  }
  return normalized;
}

function checkedSha256(value: string, label: string): string {
  const normalized = value.toLowerCase();
  if (!sha256Pattern.test(normalized)) throw new Error(`${label} must be a SHA-256 hex digest.`);
  return normalized;
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
    clean: input.clean,
    sourceTreeSha256: sourceTreeSha256(sourceFiles),
    sourceFiles,
    executableSha256: checkedSha256(input.executableSha256, "executableSha256"),
    dmgSha256: checkedSha256(input.dmgSha256, "dmgSha256"),
    dSYMUUIDs: [...new Set(input.dSYMUUIDs)].sort(),
    toolchain: { ...input.toolchain },
    validation: [...input.validation].sort((left, right) => left.name.localeCompare(right.name)),
    createdAt: input.createdAt,
  };
}

function recursivelySort(value: unknown): unknown {
  if (Array.isArray(value)) return value.map(recursivelySort);
  if (value && typeof value === "object") {
    return Object.fromEntries(
      Object.entries(value as Record<string, unknown>)
        .sort(([left], [right]) => left.localeCompare(right))
        .map(([key, child]) => [key, recursivelySort(child)]),
    );
  }
  return value;
}

export function canonicalReleaseEvidenceJSON(evidence: ReleaseEvidenceV2): string {
  return `${JSON.stringify(recursivelySort(evidence), null, 2)}\n`;
}
