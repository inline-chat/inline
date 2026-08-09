import { spawnSync } from "bun";
import { existsSync } from "node:fs";
import { resolve } from "node:path";

export type BuiltAppMetadata = {
  infoPlist: string;
  buildNumber: string;
  version: string;
  executableName: string;
  executablePath: string;
  commit: string;
  feedUrl: string;
  minimumSystemVersion: string;
};

function readPlistString(plistPath: string, key: string): string {
  const result = spawnSync({
    cmd: ["/usr/libexec/PlistBuddy", "-c", `Print :${key}`, plistPath],
    stdout: "pipe",
    stderr: "pipe",
  });
  if (result.exitCode !== 0) return "";
  return new TextDecoder().decode(result.stdout).trim();
}

export function readBuiltAppMetadata(appPath: string): BuiltAppMetadata {
  if (!existsSync(appPath)) throw new Error(`App not found at ${appPath}`);

  const infoPlist = resolve(appPath, "Contents/Info.plist");
  const buildNumber = readPlistString(infoPlist, "CFBundleVersion");
  const version = readPlistString(infoPlist, "CFBundleShortVersionString");
  const executableName = readPlistString(infoPlist, "CFBundleExecutable");
  const commit = readPlistString(infoPlist, "InlineCommit");
  const feedUrl = readPlistString(infoPlist, "SUFeedURL");
  const minimumSystemVersion = readPlistString(infoPlist, "LSMinimumSystemVersion");

  const missing = [
    ["CFBundleVersion", buildNumber],
    ["CFBundleShortVersionString", version],
    ["CFBundleExecutable", executableName],
    ["InlineCommit", commit],
    ["SUFeedURL", feedUrl],
    ["LSMinimumSystemVersion", minimumSystemVersion],
  ].flatMap(([key, value]) => (value ? [] : [key]));
  if (missing.length) {
    throw new Error(`Built app metadata missing in ${infoPlist}: ${missing.join(", ")}`);
  }

  return {
    infoPlist,
    buildNumber,
    version,
    executableName,
    executablePath: resolve(appPath, "Contents/MacOS", executableName),
    commit,
    feedUrl,
    minimumSystemVersion,
  };
}

function usage(): string {
  return "Usage: bun run app-release-metadata.ts --app-path <path> --field minimum-system-version";
}

function main(argv: string[]): void {
  let appPath = "";
  let field = "";
  for (let index = 0; index < argv.length; index++) {
    const argument = argv[index];
    if (argument === "--app-path") {
      appPath = argv[++index] ?? "";
    } else if (argument === "--field") {
      field = argv[++index] ?? "";
    } else if (argument === "--help" || argument === "-h") {
      console.log(usage());
      return;
    } else {
      throw new Error(`Unknown argument: ${argument}\n${usage()}`);
    }
  }

  if (!appPath) throw new Error(`Missing --app-path\n${usage()}`);
  if (field !== "minimum-system-version") {
    throw new Error(`Unsupported --field: ${field || "<missing>"}\n${usage()}`);
  }
  console.log(readBuiltAppMetadata(resolve(appPath)).minimumSystemVersion);
}

if (import.meta.main) {
  try {
    main(process.argv.slice(2));
  } catch (error) {
    console.error(error instanceof Error ? error.message : String(error));
    process.exit(1);
  }
}
