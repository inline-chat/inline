import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

export const liveKitRemoteURL = "https://github.com/inline-chat/client-sdk-swift.git";

export const liveKitResolvedPaths = [
  "apple/InlineKit/Package.resolved",
  "apple/InlineIOSUI/Package.resolved",
  "apple/InlineMacUI/Package.resolved",
  "apple/InlineUI/Package.resolved",
  "apple/Inline.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved",
] as const;

export const liveKitMirrorPath = "apple/InlineKit/.swiftpm/configuration/mirrors.json";

export const requiredGridAudioSources = [
  "Audio/MacGridAUHALAudioDevice.swift",
  "Audio/MacGridAUHALDirection.swift",
  "Audio/MacGridAudioCapturePacketizer.swift",
  "Audio/MacGridAudioRouteTransition.swift",
  "Audio/MacGridWebRTCAudioBridge.swift",
  "Engine/LiveKitGridAUHALAudioDriver.swift",
  "Engine/MacGridAudioEngineDiagnostics.swift",
] as const;

export const retiredGridAudioSources = [
  "Audio/MacGridAudioIO.swift",
  "Audio/MacGridAudioSampleBuffer.swift",
  "Audio/MacGridPlatformAudioCaptureState.swift",
  "Audio/MacGridWebRTCAudioLifecycleController.swift",
  "Audio/MacGridWebRTCInputDeviceController.swift",
  "Engine/LiveKitGridAudioDriver.swift",
] as const;

export type GridLiveKitPinEvidence = {
  manifestRevision: string | null;
  resolvedRevisions: ReadonlyArray<{ path: string; revision: string | null; location: string | null }>;
  mirrorPresent: boolean;
  remoteRevisionReachable: boolean;
  compiledInlineRTCSources: ReadonlyArray<string>;
};

type ResolvedFile = {
  pins?: Array<{
    identity?: string;
    location?: string;
    state?: { revision?: string };
  }>;
};

type PackageDescription = {
  targets?: Array<{
    name?: string;
    sources?: string[];
  }>;
};

export function parseManifestRevision(source: string): string | null {
  const escapedURL = liveKitRemoteURL.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  const match = source.match(
    new RegExp(`url:\\s*"${escapedURL}"[\\s\\S]{0,300}?revision:\\s*"([0-9a-f]{40})"`),
  );
  return match?.[1] ?? null;
}

export function parseResolvedPin(source: string): { revision: string | null; location: string | null } {
  const parsed = JSON.parse(source) as ResolvedFile;
  const pin = parsed.pins?.find((candidate) => candidate.identity === "client-sdk-swift");
  return {
    revision: pin?.state?.revision ?? null,
    location: pin?.location ?? null,
  };
}

export function parseInlineRTCSources(source: string): string[] {
  const description = JSON.parse(source) as PackageDescription;
  const target = description.targets?.find((candidate) => candidate.name === "InlineRTC");
  return target?.sources ?? [];
}

export function validateGridAudioCutover(sources: ReadonlyArray<string>): string[] {
  const failures: string[] = [];
  const compiled = new Set(sources);
  for (const source of requiredGridAudioSources) {
    if (!compiled.has(source)) {
      failures.push(`SwiftPM does not compile the required Grid AUHAL source ${source}.`);
    }
  }
  for (const source of retiredGridAudioSources) {
    if (compiled.has(source)) {
      failures.push(`SwiftPM still compiles the retired Grid audio source ${source}.`);
    }
  }
  return failures;
}

export function validateGridLiveKitPin(evidence: GridLiveKitPinEvidence): string[] {
  const failures: string[] = [];
  const revision = evidence.manifestRevision;

  if (!revision) {
    failures.push("apple/InlineKit/Package.swift does not contain a 40-character LiveKit fork revision.");
  }
  if (evidence.mirrorPresent) {
    failures.push(
      `SwiftPM reports an active LiveKit mirror (including ${liveKitMirrorPath}); stable dependency proof must use the canonical remote.`,
    );
  }

  for (const pin of evidence.resolvedRevisions) {
    if (!pin.revision) {
      failures.push(`${pin.path} does not contain the client-sdk-swift pin (the package may still be editable).`);
      continue;
    }
    if (pin.location !== liveKitRemoteURL) {
      failures.push(`${pin.path} points LiveKit at ${pin.location ?? "an unknown location"}.`);
    }
    if (revision && pin.revision !== revision) {
      failures.push(`${pin.path} pins ${pin.revision}, expected ${revision}.`);
    }
  }

  if (revision && !evidence.remoteRevisionReachable) {
    failures.push(`LiveKit revision ${revision} is not remotely reachable at ${liveKitRemoteURL}.`);
  }
  failures.push(...validateGridAudioCutover(evidence.compiledInlineRTCSources));
  return failures;
}

async function remoteRevisionIsReachable(revision: string): Promise<boolean> {
  const result = Bun.spawnSync(["git", "ls-remote", liveKitRemoteURL], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) {
    const detail = result.stderr.toString().trim();
    throw new Error(`Could not inspect the LiveKit fork remote.${detail ? ` ${detail}` : ""}`);
  }
  const advertisedRevisions = new Set(
    result.stdout
      .toString()
      .split("\n")
      .map((line) => line.trim().split(/\s+/, 1)[0])
      .filter((revision) => /^[0-9a-f]{40}$/.test(revision)),
  );
  if (advertisedRevisions.has(revision)) return true;

  const response = await fetch(
    `https://api.github.com/repos/inline-chat/client-sdk-swift/git/commits/${revision}`,
    {
      headers: {
        Accept: "application/vnd.github+json",
        "X-GitHub-Api-Version": "2022-11-28",
      },
    },
  );
  if (response.status === 404 || response.status === 422) return false;
  if (!response.ok) {
    throw new Error(
      `Could not verify LiveKit revision reachability through GitHub (HTTP ${response.status}).`,
    );
  }
  const commit = await response.json() as { sha?: string };
  return commit.sha === revision;
}

function liveKitMirrorIsConfigured(rootDir: string): boolean {
  if (existsSync(resolve(rootDir, liveKitMirrorPath))) return true;

  const result = Bun.spawnSync([
    "swift",
    "package",
    "--package-path",
    resolve(rootDir, "apple/InlineKit"),
    "config",
    "get-mirror",
    "--original",
    liveKitRemoteURL,
  ], {
    stdout: "pipe",
    stderr: "pipe",
  });
  const stdout = result.stdout.toString().trim();
  const stderr = result.stderr.toString().trim();
  if (stdout === "not found" || stderr === "not found") return false;
  if (result.exitCode !== 0) {
    throw new Error(`Could not inspect SwiftPM mirror configuration.${stderr ? ` ${stderr}` : ""}`);
  }
  return stdout.length > 0;
}

function compiledInlineRTCSources(rootDir: string): string[] {
  const result = Bun.spawnSync([
    "swift",
    "package",
    "--package-path",
    resolve(rootDir, "apple/InlineKit"),
    "describe",
    "--type",
    "json",
  ], {
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) {
    const detail = result.stderr.toString().trim();
    throw new Error(`Could not resolve InlineRTC's compiled source list.${detail ? ` ${detail}` : ""}`);
  }
  return parseInlineRTCSources(result.stdout.toString());
}

export async function collectGridLiveKitPinEvidence(rootDir: string): Promise<GridLiveKitPinEvidence> {
  const manifestRevision = parseManifestRevision(
    readFileSync(resolve(rootDir, "apple/InlineKit/Package.swift"), "utf8"),
  );
  const resolvedRevisions = liveKitResolvedPaths.map((path) => ({
    path,
    ...parseResolvedPin(readFileSync(resolve(rootDir, path), "utf8")),
  }));
  return {
    manifestRevision,
    resolvedRevisions,
    mirrorPresent: liveKitMirrorIsConfigured(rootDir),
    remoteRevisionReachable: manifestRevision
      ? await remoteRevisionIsReachable(manifestRevision)
      : false,
    compiledInlineRTCSources: compiledInlineRTCSources(rootDir),
  };
}

if (import.meta.main) {
  const rootDir = resolve(import.meta.dir, "../..");
  let evidence: GridLiveKitPinEvidence;
  try {
    evidence = await collectGridLiveKitPinEvidence(rootDir);
  } catch (error) {
    console.error(`Grid LiveKit release pin check failed: ${String(error)}`);
    process.exit(1);
  }
  const failures = validateGridLiveKitPin(evidence);
  if (failures.length > 0) {
    console.error("Grid LiveKit release pin check failed:");
    for (const failure of failures) console.error(`- ${failure}`);
    process.exit(1);
  }
  console.log(
    `Grid LiveKit release pin and directional AUHAL cutover verified: ${evidence.manifestRevision} across ${evidence.resolvedRevisions.length} lockfiles and the remote fork.`,
  );
}
