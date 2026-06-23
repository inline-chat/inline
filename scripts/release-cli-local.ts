import { readFile, writeFile } from "fs/promises";
import { join, relative, resolve } from "path";
import { commandExists, commandText, run } from "./helpers/command.ts";
import {
  assertCleanWorktree,
  assertTagAvailable,
  tagExistsLocal,
  tagExistsRemote,
  writeReleaseNotes,
} from "./helpers/git.ts";
import {
  parseReleaseArgs,
  releaseUsage,
  type ReleaseArgs,
} from "./helpers/release-args.ts";
import { formatMs, ReleaseLog } from "./helpers/release-ui.ts";
import { assertSemver, bumpVersion, isPrerelease } from "./helpers/version.ts";

const rootDir = resolve(import.meta.dir, "..");
const cliDir = join(rootDir, "cli");
const cargoTomlPath = join(cliDir, "Cargo.toml");
const cargoLockPath = join(cliDir, "Cargo.lock");
const lowLevelScript = join(rootDir, "scripts", "release-cli.ts");
const cargoTomlRel = relative(rootDir, cargoTomlPath);
const cargoLockRel = relative(rootDir, cargoLockPath);
const gitRemote = process.env.INLINE_CLI_GIT_REMOTE ?? "origin";
const tagPrefix = process.env.INLINE_CLI_GITHUB_TAG_PREFIX ?? "cli-v";
const scopedPaths = ["cli", "scripts/release-cli.ts"];
const log = new ReleaseLog();

await main();

async function main() {
  const startedAt = Date.now();
  try {
    const args = parseReleaseArgs(process.argv.slice(2));
    if (args.help) {
      console.log(releaseUsage("cli"));
      return;
    }
    assertCommand(args.command);

    if (args.skipNpm) log.skip("--skip-npm has no effect for CLI releases");
    if (args.skipClawHub) log.skip("--skip-clawhub has no effect for CLI releases");

    const current = await readCargoVersion();
    const version = targetVersion(current, args);

    if (args.command === "status") {
      await printStatus(current, version, args);
      return;
    }

    if (args.command === "verify") {
      await verify(version, args);
      return;
    }

    await confirmRelease(current, version, args);

    if (args.command === "prepare" || args.command === "release") {
      await prepare(current, version, args);
    }

    if (args.command === "build") {
      await runLowLevel("build", version, args);
    } else if (args.command === "publish") {
      await runLowLevel("publish", version, args);
    } else if (args.command === "release") {
      if (!args.skipGit && args.push) {
        log.step("Pushing HEAD before CLI release tag is created");
        await run(["git", "push", gitRemote, "HEAD"], {
          cwd: rootDir,
          dryRun: args.dryRun,
          log,
        });
      }
      await runLowLevel("release", version, args);
    }

    log.ok(`CLI ${args.command} completed in ${formatMs(Date.now() - startedAt)}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log.error(message);
    process.exitCode = 1;
  }
}

async function printStatus(current: string, version: string, args: ReleaseArgs) {
  const tag = releaseTag(version);
  log.status("CLI Release Status", [
    { label: "local version", value: current },
    { label: "target version", value: version },
    { label: "channel", value: args.channel },
    { label: "tag", value: tag },
    { label: "local tag", value: (await tagExistsLocal(rootDir, tag)) ? "exists" : "missing" },
    { label: "remote tag", value: (await tagExistsRemote(rootDir, gitRemote, tag)) ? "exists" : "missing" },
    { label: "R2 access key", value: envStatus("PUBLIC_RELEASES_R2_ACCESS_KEY_ID") },
    { label: "R2 secret", value: envStatus("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY") },
    { label: "R2 bucket", value: envStatus("PUBLIC_RELEASES_R2_BUCKET") },
    { label: "R2 endpoint", value: envStatus("PUBLIC_RELEASES_R2_ENDPOINT") },
    { label: "R2 public URL", value: envStatus("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL") },
    { label: "signing identity", value: envStatus("APPLE_SIGNING_IDENTITY") },
    { label: "low-level script", value: relative(rootDir, lowLevelScript) },
  ]);
}

async function verify(version: string, args: ReleaseArgs) {
  const tag = releaseTag(version);
  log.heading("Verify CLI");
  log.info(`channel: ${args.channel}`);
  log.info(`tag: ${tag}`);

  const local = await tagExistsLocal(rootDir, tag);
  const remote = await tagExistsRemote(rootDir, gitRemote, tag);
  if (!local) log.warn(`local tag missing: ${tag}`);
  if (!remote) log.warn(`remote tag missing: ${tag}`);
  if (local && remote) log.ok(`git tag exists locally and on ${gitRemote}`);

  if (!(await commandExists("gh"))) {
    throw new Error("gh CLI not found; cannot verify GitHub release.");
  }

  const result = await run(
    ["gh", "release", "view", tag, "--json", "tagName,name,isPrerelease"],
    {
      allowFailure: true,
      cwd: rootDir,
      quiet: true,
    },
  );
  if (result.exitCode === 0) {
    log.ok(`GitHub release exists for ${tag}`);
  } else if (args.dryRun) {
    log.skip("GitHub release verification skipped in dry-run mode");
  } else {
    throw new Error(`GitHub release missing for ${tag}`);
  }
}

async function prepare(current: string, version: string, args: ReleaseArgs) {
  log.heading("Prepare CLI");
  assertSemver(version);
  const changed = current !== version;

  if (changed) {
    await assertCleanWorktree(rootDir, {
      allowDirty: args.allowDirty,
      paths: [cargoTomlRel, cargoLockRel],
    });
    log.step(`Updating Cargo version ${current} -> ${version}`);
    await writeCargoVersion(version, args);
  } else {
    log.ok(`Cargo.toml already at ${version}`);
  }

  if (!args.skipChecks) {
    await runChecks(args);
  } else {
    log.skip("checks skipped by --skip-checks");
  }

  const notesFile = await writeReleaseNotes(rootDir, {
    notesFile: args.notesFile,
    paths: scopedPaths,
    prefix: tagPrefix,
    product: "Inline CLI",
    version,
  });
  log.ok(`release notes written to ${relative(rootDir, notesFile)}`);

  if (args.skipGit) {
    log.skip("version commit skipped by --skip-git");
    return;
  }

  if (!args.resume) {
    await assertTagAvailable(rootDir, gitRemote, releaseTag(version));
  }

  if (changed) {
    log.step("Committing CLI version bump");
    const files = await changedVersionFiles();
    await run(["git", "add", "--", ...files], {
      cwd: rootDir,
      dryRun: args.dryRun,
      log,
    });
    await run(["git", "commit", "-m", `cli: release ${version}`, "--", ...files], {
      cwd: rootDir,
      dryRun: args.dryRun,
      log,
    });
  }
}

async function runChecks(args: ReleaseArgs) {
  log.step("Running CLI checks");
  await run(["bun", "run", "typecheck"], {
    cwd: cliDir,
    dryRun: args.dryRun,
    log,
  });
  await run(["bun", "run", "lint"], {
    cwd: cliDir,
    dryRun: args.dryRun,
    log,
  });
  await run(["bun", "run", "test"], {
    cwd: cliDir,
    dryRun: args.dryRun,
    log,
  });
}

async function runLowLevel(
  command: "build" | "publish" | "release",
  version: string,
  args: ReleaseArgs,
  extra: { resume?: boolean } = {},
) {
  if (args.skipGit && command !== "build") {
    throw new Error("CLI publisher manages tags/releases; --skip-git is only valid for prepare.");
  }

  const notesFile = await writeReleaseNotes(rootDir, {
    notesFile: args.notesFile,
    paths: scopedPaths,
    prefix: tagPrefix,
    product: "Inline CLI",
    version,
  });
  const env = {
    INLINE_CLI_RELEASE_CHANNEL: args.channel,
    INLINE_CLI_RELEASE_NOTES_FILE: notesFile,
    INLINE_CLI_RELEASE_RESUME: args.resume || extra.resume ? "1" : undefined,
    INLINE_CLI_SKIP_GITHUB_RELEASE: args.skipGitHub ? "1" : undefined,
  };
  const commandArgs = ["bun", "run", lowLevelScript, command];

  if (args.dryRun) {
    log.command(
      `INLINE_CLI_RELEASE_CHANNEL=${args.channel} INLINE_CLI_RELEASE_NOTES_FILE=${notesFile} ${commandText(commandArgs)}`,
    );
    return;
  }

  await run(commandArgs, {
    cwd: rootDir,
    env,
    log,
  });
}

async function readCargoVersion(): Promise<string> {
  const contents = await readFile(cargoTomlPath, "utf8");
  const match = contents.match(/^version\s*=\s*"([^"]+)"/m);
  if (!match) {
    throw new Error("Failed to read CLI version from Cargo.toml");
  }
  return match[1];
}

async function writeCargoVersion(version: string, args: ReleaseArgs) {
  const contents = await readFile(cargoTomlPath, "utf8");
  const updated = contents.replace(
    /^version\s*=\s*"[^"]+"/m,
    `version = "${version}"`,
  );
  if (updated === contents) {
    throw new Error("Failed to update Cargo.toml version.");
  }
  if (args.dryRun) {
    log.command(`write ${cargoTomlRel} version ${version}`);
    log.command("cargo metadata --format-version 1");
    return;
  }
  await writeFile(cargoTomlPath, updated);
  await run(["cargo", "metadata", "--format-version", "1"], {
    cwd: cliDir,
    log,
    quiet: true,
  });
}

async function changedVersionFiles(): Promise<string[]> {
  const files = [cargoTomlRel];
  const status = await runStatus([cargoLockRel]);
  if (status.length > 0) {
    files.push(cargoLockRel);
  }
  return files;
}

async function runStatus(paths: readonly string[]): Promise<string> {
  const result = await run(
    ["git", "status", "--porcelain", "--", ...paths],
    {
      cwd: rootDir,
      quiet: true,
    },
  );
  return result.stdout.trim();
}

function targetVersion(current: string, args: ReleaseArgs): string {
  if (args.version && args.bump) {
    throw new Error("Use either --version or --bump, not both.");
  }
  if (args.version) {
    assertSemver(args.version);
    return args.version;
  }
  if (args.bump) {
    return bumpVersion(current, args.bump, args.channel);
  }
  return current;
}

function releaseTag(version: string): string {
  return `${tagPrefix}${version}`;
}

async function confirmRelease(
  current: string,
  version: string,
  args: ReleaseArgs,
) {
  if (args.yes || args.dryRun || args.command === "prepare" || args.command === "build") {
    return;
  }
  log.status("CLI Release Plan", [
    { label: "command", value: args.command },
    { label: "channel", value: args.channel },
    { label: "current", value: current },
    { label: "target", value: version },
    { label: "tag", value: releaseTag(version) },
    { label: "prerelease", value: String(args.channel === "beta" || isPrerelease(version)) },
  ]);
  const answer = await prompt("Proceed? (y/N): ");
  if (!/^(y|yes)$/i.test(answer.trim())) {
    throw new Error("Aborted by user.");
  }
}

function assertCommand(command: string) {
  if (!["build", "prepare", "publish", "release", "status", "verify"].includes(command)) {
    throw new Error(`Unknown command: ${command}\n\n${releaseUsage("cli")}`);
  }
}

function envStatus(name: string): string {
  return process.env[name] ? "set" : "missing";
}

async function prompt(message: string): Promise<string> {
  process.stdout.write(message);
  return await new Promise<string>((resolve) => {
    process.stdin.setEncoding("utf8");
    process.stdin.once("data", (data) => resolve(String(data)));
  });
}
