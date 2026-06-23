import { mkdir, writeFile } from "fs/promises";
import { join, relative, resolve } from "path";
import { capture, commandExists, run } from "./helpers/command.ts";
import {
  assertCleanWorktree,
  assertTagAvailable,
  createAnnotatedTag,
  createGitHubRelease,
  pushHeadAndTag,
  tagExistsLocal,
  tagExistsRemote,
  writeReleaseNotes,
} from "./helpers/git.ts";
import { npmPackDryRun, npmPackageVersionExists, npmPublish, npmViewPackage, npmWhoami } from "./helpers/npm.ts";
import {
  npmTagForChannel,
  parseReleaseArgs,
  releaseUsage,
  type ReleaseArgs,
} from "./helpers/release-args.ts";
import { formatMs, ReleaseLog } from "./helpers/release-ui.ts";
import { assertSemver, bumpVersion, isPrerelease, readJson, writeJson } from "./helpers/version.ts";

type OpenClawPackageJson = {
  name: string;
  openclaw?: {
    release?: {
      publishToClawHub?: boolean;
      publishToNpm?: boolean;
    };
  };
  version: string;
};

type ClawHubSearch = {
  results?: Array<{
    package?: {
      latestVersion?: string;
      name?: string;
    };
  }>;
};

const rootDir = resolve(import.meta.dir, "..");
const packageDir = join(rootDir, "packages", "openclaw");
const packageJsonPath = join(packageDir, "package.json");
const packageJsonRel = relative(rootDir, packageJsonPath);
const gitRemote = process.env.INLINE_RELEASE_GIT_REMOTE ?? "origin";
const githubRepo = process.env.INLINE_RELEASE_GITHUB_REPO ?? "inline-chat/inline";
const tagPrefix = "openclaw-v";
const scopedPaths = ["packages/openclaw"];
const openClawCheckDir = join(rootDir, ".tmp", "openclaw-release-check");
const openClawConfigPath = join(openClawCheckDir, "openclaw.json");
const openClawStateDir = join(openClawCheckDir, "state");
const log = new ReleaseLog();

await main();

async function main() {
  const startedAt = Date.now();
  try {
    const args = parseReleaseArgs(process.argv.slice(2));
    if (args.help) {
      console.log(releaseUsage("openclaw"));
      return;
    }

    assertCommand(args.command);
    const pkg = await readPackage();
    const version = targetVersion(pkg.version, args);

    if (args.command === "status") {
      await printStatus(pkg, version);
      return;
    }

    if (args.command === "verify") {
      await verify(version, args);
      return;
    }

    await confirmRelease(pkg.version, version, args);

    const didPrepare = args.command === "prepare" || args.command === "release";
    if (didPrepare) {
      await prepare(pkg, version, args);
    }

    if (args.command === "publish" || args.command === "release") {
      await publish(version, args, { didPrepare });
    }

    log.ok(`OpenClaw ${args.command} completed in ${formatMs(Date.now() - startedAt)}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    log.error(message);
    process.exitCode = 1;
  }
}

async function printStatus(pkg: OpenClawPackageJson, version: string) {
  const npmInfo = await npmViewPackage(packageDir, pkg.name);
  const npmUser = await npmWhoami(packageDir);
  const clawHubVersion = await readClawHubVersion(pkg.name);
  const tag = releaseTag(version);

  log.status("OpenClaw Release Status", [
    { label: "package", value: pkg.name },
    { label: "local version", value: pkg.version },
    { label: "target version", value: version },
    { label: "npm latest", value: npmInfo?.version ?? "not found" },
    {
      label: "npm dist-tags",
      value: npmInfo?.["dist-tags"] ? JSON.stringify(npmInfo["dist-tags"]) : "not found",
    },
    { label: "npm auth", value: npmUser ?? "not logged in" },
    { label: "clawhub latest", value: clawHubVersion ?? "not found" },
    { label: "local tag", value: (await tagExistsLocal(rootDir, tag)) ? "exists" : "missing" },
    { label: "remote tag", value: (await tagExistsRemote(rootDir, gitRemote, tag)) ? "exists" : "missing" },
  ]);
}

async function prepare(
  pkg: OpenClawPackageJson,
  version: string,
  args: ReleaseArgs,
) {
  log.heading("Prepare OpenClaw");
  assertSemver(version);
  const tag = releaseTag(version);
  const changed = pkg.version !== version;

  if (changed) {
    await assertCleanWorktree(rootDir, {
      allowDirty: args.allowDirty,
      paths: [packageJsonRel],
    });
    log.step(`Updating package version ${pkg.version} -> ${version}`);
    await writePackageVersion(pkg, version, args);
  } else {
    log.ok(`package.json already at ${version}`);
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
    product: "Inline OpenClaw",
    version,
  });
  log.ok(`release notes written to ${relative(rootDir, notesFile)}`);

  if (args.skipGit) {
    log.skip("git commit/tag skipped by --skip-git");
    return;
  }

  if (!args.resume && !(await tagExistsLocal(rootDir, tag))) {
    await assertTagAvailable(rootDir, gitRemote, tag);
  }

  if (changed) {
    await commitVersion(version, args);
  }

  if (await tagExistsLocal(rootDir, tag)) {
    log.ok(`tag ${tag} already exists locally`);
  } else {
    log.step(`Creating tag ${tag}`);
    await createAnnotatedTag(rootDir, tag, `Inline OpenClaw v${version}`, {
      dryRun: args.dryRun,
      log,
    });
  }
}

async function publish(
  version: string,
  args: ReleaseArgs,
  options: { didPrepare?: boolean } = {},
) {
  const pkg = await readPackage();
  if (pkg.version !== version && !args.dryRun) {
    throw new Error(
      `package.json is at ${pkg.version}, but release target is ${version}. Run prepare first.`,
    );
  }

  log.heading("Publish OpenClaw");
  const tag = releaseTag(version);
  const notesFile = await writeReleaseNotes(rootDir, {
    notesFile: args.notesFile,
    paths: scopedPaths,
    prefix: tagPrefix,
    product: "Inline OpenClaw",
    version,
  });

  if (!args.skipGit) {
    if (args.dryRun && options.didPrepare) {
      log.ok(`tag ${tag} planned during prepare`);
    } else if (!(await tagExistsLocal(rootDir, tag))) {
      if (args.resume) {
        log.warn(`local tag ${tag} is missing; creating it for resume`);
      } else {
        await assertTagAvailable(rootDir, gitRemote, tag);
      }
      await createAnnotatedTag(rootDir, tag, `Inline OpenClaw v${version}`, {
        dryRun: args.dryRun,
        log,
      });
    }
    if (args.push) {
      log.step(`Pushing HEAD and ${tag}`);
      await pushHeadAndTag(rootDir, gitRemote, tag, {
        dryRun: args.dryRun,
        log,
      });
    } else {
      log.skip("git push skipped by --no-push");
    }
  } else {
    log.skip("git push/tag skipped by --skip-git");
  }

  if (!args.skipNpm) {
    await assertNpmVersionNotPublished(pkg.name, version, args);
    log.step(`Publishing ${pkg.name}@${version} to npm (${npmTagForChannel(args)})`);
    await npmPublish({
      cwd: packageDir,
      dryRun: args.dryRun,
      log,
      tag: npmTagForChannel(args),
    });
  } else {
    log.skip("npm publish skipped by --skip-npm");
  }

  if (!args.skipGitHub) {
    await publishGitHubRelease(version, notesFile, args);
  } else {
    log.skip("GitHub release skipped by --skip-github");
  }

  await verify(version, args);
}

async function verify(version: string, args: ReleaseArgs) {
  const pkg = await readPackage();
  log.heading("Verify OpenClaw");

  if (!args.skipNpm) {
    const exists = await npmPackageVersionExists(packageDir, pkg.name, version);
    if (!exists && !args.dryRun) {
      throw new Error(`npm package is not visible yet: ${pkg.name}@${version}`);
    }
    log.ok(`npm ${pkg.name}@${version}${args.dryRun ? " (dry-run)" : ""}`);
  }

  if (args.channel === "beta") {
    log.skip("ClawHub latest-version verification skipped for beta channel");
    return;
  }
  if (args.skipClawHub) {
    log.skip("ClawHub verification skipped by --skip-clawhub");
    return;
  }

  await waitForClawHub(pkg.name, version, args);
}

async function runChecks(args: ReleaseArgs) {
  log.step("Running package checks");
  await run(["bun", "run", "check"], {
    cwd: packageDir,
    dryRun: args.dryRun,
    log,
  });
  await npmPackDryRun({ cwd: packageDir, dryRun: args.dryRun, log });

  if (await commandExists("openclaw")) {
    await ensureOpenClawCheckConfig();
    await run(["openclaw", "plugins", "validate", "--root", packageDir], {
      cwd: rootDir,
      dryRun: args.dryRun,
      env: openClawEnv(),
      log,
    });
  } else {
    log.warn("openclaw CLI not found; plugin validation skipped");
  }
}

async function publishGitHubRelease(
  version: string,
  notesFile: string,
  args: ReleaseArgs,
) {
  if (!(await commandExists("gh"))) {
    throw new Error("gh CLI not found; pass --skip-github to skip GitHub release creation.");
  }

  const tag = releaseTag(version);
  const existing = await capture(
    ["gh", "release", "view", tag, "--repo", githubRepo, "--json", "tagName"],
    {
      allowFailure: true,
      cwd: rootDir,
      quiet: true,
    },
  );
  if (existing.exitCode === 0) {
    if (args.resume) {
      log.ok(`GitHub release ${tag} already exists`);
      return;
    }
    throw new Error(`GitHub release already exists: ${tag}`);
  }

  log.step(`Creating GitHub release ${tag}`);
  await createGitHubRelease(rootDir, {
    dryRun: args.dryRun,
    log,
    notesFile,
    prerelease: args.channel === "beta" || isPrerelease(version),
    repo: githubRepo,
    tag,
    title: `Inline OpenClaw v${version}`,
  });
}

async function assertNpmVersionNotPublished(
  name: string,
  version: string,
  args: ReleaseArgs,
) {
  if (args.resume || args.dryRun) return;
  const exists = await npmPackageVersionExists(packageDir, name, version);
  if (exists) {
    throw new Error(`${name}@${version} is already published on npm.`);
  }
}

async function waitForClawHub(
  packageName: string,
  version: string,
  args: ReleaseArgs,
) {
  if (args.dryRun) {
    log.skip("ClawHub polling skipped in dry-run mode");
    return;
  }
  if (!(await commandExists("openclaw"))) {
    throw new Error("openclaw CLI not found; cannot verify ClawHub index.");
  }

  const timeoutMs = Number.parseInt(process.env.INLINE_CLAWHUB_TIMEOUT_MS ?? "300000", 10);
  const intervalMs = Number.parseInt(process.env.INLINE_CLAWHUB_POLL_MS ?? "15000", 10);
  const startedAt = Date.now();

  while (Date.now() - startedAt <= timeoutMs) {
    const current = await readClawHubVersion(packageName);
    if (current === version) {
      log.ok(`ClawHub indexed ${packageName}@${version}`);
      return;
    }
    log.info(
      `ClawHub latest is ${current ?? "not found"}; waiting for ${version}...`,
    );
    await sleep(intervalMs);
  }

  throw new Error(
    `ClawHub did not report ${packageName}@${version} within ${formatMs(timeoutMs)}.`,
  );
}

async function readClawHubVersion(packageName: string): Promise<string | null> {
  if (!(await commandExists("openclaw"))) return null;
  await ensureOpenClawCheckConfig();
  const queries = [packageName, packageName.split("/").at(-1) ?? packageName];
  for (const query of queries) {
    const result = await capture(
      ["openclaw", "plugins", "search", query, "--json", "--limit", "10"],
      {
        allowFailure: true,
        cwd: rootDir,
        env: openClawEnv(),
        quiet: true,
      },
    );
    if (result.exitCode !== 0 || !result.stdout.trim()) continue;
    const parsed = JSON.parse(result.stdout) as ClawHubSearch;
    const item = parsed.results?.find((entry) => entry.package?.name === packageName);
    if (item?.package?.latestVersion) return item.package.latestVersion;
  }
  return null;
}

async function ensureOpenClawCheckConfig() {
  await mkdir(openClawCheckDir, { recursive: true });
  await mkdir(openClawStateDir, { recursive: true });
  await writeFile(openClawConfigPath, "{}\n");
}

function openClawEnv(): Record<string, string> {
  return {
    OPENCLAW_CONFIG_PATH: openClawConfigPath,
    OPENCLAW_STATE_DIR: openClawStateDir,
  };
}

async function readPackage(): Promise<OpenClawPackageJson> {
  return await readJson<OpenClawPackageJson>(packageJsonPath);
}

async function writePackageVersion(
  pkg: OpenClawPackageJson,
  version: string,
  args: ReleaseArgs,
) {
  const next = { ...pkg, version };
  if (args.dryRun) {
    log.command(`write ${packageJsonRel} version ${version}`);
    return;
  }
  await writeJson(packageJsonPath, next);
}

async function commitVersion(version: string, args: ReleaseArgs) {
  log.step("Committing OpenClaw version bump");
  await run(["git", "add", "--", packageJsonRel], {
    cwd: rootDir,
    dryRun: args.dryRun,
    log,
  });
  await run(
    ["git", "commit", "-m", `openclaw: release ${version}`, "--", packageJsonRel],
    {
      cwd: rootDir,
      dryRun: args.dryRun,
      log,
    },
  );
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
  if (args.yes || args.dryRun || args.command === "prepare") return;
  log.status("OpenClaw Release Plan", [
    { label: "command", value: args.command },
    { label: "channel", value: args.channel },
    { label: "current", value: current },
    { label: "target", value: version },
    { label: "npm tag", value: npmTagForChannel(args) },
    { label: "tag", value: releaseTag(version) },
  ]);
  const answer = await prompt("Proceed? (y/N): ");
  if (!/^(y|yes)$/i.test(answer.trim())) {
    throw new Error("Aborted by user.");
  }
}

function assertCommand(command: string) {
  if (!["prepare", "publish", "release", "status", "verify"].includes(command)) {
    throw new Error(`Unknown command: ${command}\n\n${releaseUsage("openclaw")}`);
  }
}

function sleep(ms: number): Promise<void> {
  return new Promise((resolve) => setTimeout(resolve, ms));
}

async function prompt(message: string): Promise<string> {
  process.stdout.write(message);
  return await new Promise<string>((resolve) => {
    process.stdin.setEncoding("utf8");
    process.stdin.once("data", (data) => resolve(String(data)));
  });
}
