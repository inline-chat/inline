import { spawnSync } from "bun";
import { existsSync, mkdtempSync, rmdirSync } from "node:fs";
import { tmpdir } from "node:os";
import { resolve } from "node:path";

export type BuiltAppMetadata = {
  infoPlist: string;
  buildNumber: string;
  version: string;
  commit: string;
  feedUrl: string;
  minimumSystemVersion: string;
};

const comparableMetadataFields = [
  "buildNumber",
  "version",
  "commit",
  "feedUrl",
  "minimumSystemVersion",
] as const;

type PlistReader = (plistPath: string, key: string) => string;

function readPlistString(plistPath: string, key: string): string {
  const result = spawnSync({
    cmd: ["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, plistPath],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return "";
  return new TextDecoder().decode(result.stdout).trim();
}

export function readBuiltAppMetadata(
  appPath: string,
  readPlist: PlistReader = readPlistString,
): BuiltAppMetadata {
  if (!existsSync(appPath)) throw new Error(`App not found at ${appPath}`);

  const infoPlist = resolve(appPath, "Contents/Info.plist");
  const metadata = {
    infoPlist,
    buildNumber: readPlist(infoPlist, "CFBundleVersion").trim(),
    version: readPlist(infoPlist, "CFBundleShortVersionString").trim(),
    commit: readPlist(infoPlist, "InlineCommit").trim(),
    feedUrl: readPlist(infoPlist, "SUFeedURL").trim(),
    minimumSystemVersion: readPlist(infoPlist, "LSMinimumSystemVersion").trim(),
  };
  const required = [
    ["CFBundleVersion", metadata.buildNumber],
    ["CFBundleShortVersionString", metadata.version],
    ["InlineCommit", metadata.commit],
    ["SUFeedURL", metadata.feedUrl],
    ["LSMinimumSystemVersion", metadata.minimumSystemVersion],
  ];
  const missing = required.flatMap(([key, value]) => value ? [] : [key]);
  if (missing.length) {
    throw new Error(`Built app metadata missing in ${infoPlist}: ${missing.join(", ")}`);
  }
  return metadata;
}

export function readDmgAppMetadata(dmgPath: string): BuiltAppMetadata {
  if (!existsSync(dmgPath)) throw new Error(`DMG not found at ${dmgPath}`);
  const mountPoint = mkdtempSync(resolve(tmpdir(), "inline-release-dmg-"));
  const attach = spawnSync({
    cmd: ["hdiutil", "attach", "-nobrowse", "-readonly", "-mountpoint", mountPoint, dmgPath],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (attach.exitCode !== 0) {
    rmdirSync(mountPoint);
    throw new Error(`Unable to mount DMG ${dmgPath}: ${new TextDecoder().decode(attach.stderr).trim()}`);
  }
  let metadata: BuiltAppMetadata | undefined;
  let metadataError: unknown;
  try {
    metadata = readBuiltAppMetadata(resolve(mountPoint, "Inline.app"));
  } catch (error) {
    metadataError = error;
  }
  const detach = spawnSync({ cmd: ["hdiutil", "detach", mountPoint], stdout: "pipe", stderr: "pipe" });
  if (detach.exitCode === 0) rmdirSync(mountPoint);
  if (detach.exitCode !== 0) {
    throw new Error(`Unable to detach mounted DMG at ${mountPoint}: ${new TextDecoder().decode(detach.stderr).trim()}`);
  }
  if (metadataError) throw metadataError;
  if (!metadata) throw new Error(`DMG app metadata unavailable at ${mountPoint}`);
  return metadata;
}

export function metadataMismatches(expected: BuiltAppMetadata, actual: BuiltAppMetadata): string[] {
  return comparableMetadataFields.flatMap((field) => expected[field] === actual[field]
    ? []
    : [`${field} is ${actual[field]}, expected ${expected[field]}`]);
}

export function verifyAppAndDmgMetadata(
  appPath: string,
  dmgPath: string,
  expectedBuild?: string,
  expectedCommit?: string,
): BuiltAppMetadata {
  const appMetadata = readBuiltAppMetadata(appPath);
  const mismatches = metadataMismatches(appMetadata, readDmgAppMetadata(dmgPath));
  if (expectedBuild && appMetadata.buildNumber !== expectedBuild) {
    mismatches.push(`buildNumber is ${appMetadata.buildNumber}, expected frozen build ${expectedBuild}`);
  }
  if (expectedCommit && appMetadata.commit !== expectedCommit) {
    mismatches.push(`commit is ${appMetadata.commit}, expected frozen commit ${expectedCommit}`);
  }
  if (mismatches.length) {
    throw new Error(`Release app/DMG metadata mismatch:\n- ${mismatches.join("\n- ")}`);
  }
  return appMetadata;
}

function cli(argv: string[]): number {
  const valueAfter = (flag: string): string => {
    const index = argv.indexOf(flag);
    return index === -1 ? "" : argv[index + 1] ?? "";
  };
  const appPath = valueAfter("--app-path");
  const dmgPath = valueAfter("--verify-dmg");
  const expectedBuild = valueAfter("--expect-build");
  const expectedCommit = valueAfter("--expect-commit");
  const minimumField = argv.includes("--field=minimum-system-version");
  if (!appPath || (minimumField === Boolean(dmgPath))) {
    console.error("Usage: bun run app-release-metadata.ts --app-path <app> (--field=minimum-system-version | --verify-dmg <dmg> [--expect-build <build>] [--expect-commit <short-sha>])");
    return 2;
  }

  try {
    if (minimumField) console.log(readBuiltAppMetadata(appPath).minimumSystemVersion);
    else verifyAppAndDmgMetadata(appPath, dmgPath, expectedBuild, expectedCommit);
    return 0;
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    return 1;
  }
}

if (import.meta.main) {
  process.exitCode = cli(process.argv.slice(2));
}
