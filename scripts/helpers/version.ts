import { readFile, writeFile } from "fs/promises";
import type { ReleaseChannel, VersionBump } from "./release-args.ts";

type Semver = {
  major: number;
  minor: number;
  patch: number;
  pre: string | null;
  preNum: number | null;
};

export async function readJson<T>(path: string): Promise<T> {
  return JSON.parse(await readFile(path, "utf8")) as T;
}

export async function writeJson(path: string, value: unknown) {
  await writeFile(path, `${JSON.stringify(value, null, 2)}\n`);
}

export function assertSemver(version: string) {
  parseSemver(version);
}

export function bumpVersion(
  current: string,
  bump: VersionBump,
  channel: ReleaseChannel,
): string {
  const parsed = parseSemver(current);
  if (bump === "major") {
    return `${parsed.major + 1}.0.0`;
  }
  if (bump === "minor") {
    return `${parsed.major}.${parsed.minor + 1}.0`;
  }
  if (bump === "patch") {
    return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}`;
  }

  const pre = channel === "beta" ? "beta" : "rc";
  if (parsed.pre === pre && parsed.preNum !== null) {
    return `${parsed.major}.${parsed.minor}.${parsed.patch}-${pre}.${parsed.preNum + 1}`;
  }
  return `${parsed.major}.${parsed.minor}.${parsed.patch + 1}-${pre}.1`;
}

export function isPrerelease(version: string): boolean {
  return parseSemver(version).pre !== null;
}

function parseSemver(version: string): Semver {
  const match = /^(\d+)\.(\d+)\.(\d+)(?:-([A-Za-z0-9.-]+))?$/.exec(version);
  if (!match) {
    throw new Error(`Invalid semver: ${version}`);
  }
  const pre = match[4] ?? null;
  const preMatch = pre ? /^([A-Za-z][A-Za-z0-9-]*)\.(\d+)$/.exec(pre) : null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
    pre: preMatch?.[1] ?? (pre ? pre : null),
    preNum: preMatch ? Number(preMatch[2]) : null,
  };
}
