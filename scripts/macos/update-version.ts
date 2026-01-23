import { $ } from "bun";
import { mkdtemp, mkdir, rm, writeFile } from "fs/promises";
import { tmpdir } from "os";
import { join, posix, relative, resolve, sep } from "path";

const rootDir = resolve(import.meta.dir, "..", "..");
const projectPath = resolve(rootDir, "apple", "Inline.xcodeproj");
const projectPbxprojGitPath = join(
  relative(rootDir, projectPath),
  "project.pbxproj",
)
  .split(sep)
  .join(posix.sep);
const gitRemote = "origin";
const targetName = "InlineMac";
const configNames = ["Debug", "Debug #2", "Release"];

await main();

async function main() {
  try {
    const args = process.argv.slice(2);
    const isUndo = args.includes("--undo");
    const autoYes = args.includes("-y") || args.includes("--yes");
    await assertCleanGit();
    await assertXcodeprojInstalled();

    if (isUndo) {
      await runUndo();
      return;
    }

    const versionArgs = args.filter((arg) => arg !== "--undo" && arg !== "-y" && arg !== "--yes");
    const version = readVersionArg(versionArgs);
    assertSemver(version);

    const currentVersion = await readMarketingVersion(
      projectPath,
      targetName,
      configNames,
    );
    if (!autoYes) {
      await confirmVersionChange(currentVersion, version);
    }

    console.log(`• Updating InlineMac MARKETING_VERSION to ${version}`);
    await updateMarketingVersion(projectPath, targetName, configNames, version);

    console.log("• Committing version bump");
    await $`git add ${projectPath}`;
    await $`git commit -m ${`apple: bump macos to ${version}`}`;

    const tag = `macos-v${version}`;
    console.log(`• Checking tag availability (${tag})`);
    await assertTagDoesNotExist(tag, gitRemote);

    console.log(`• Tagging ${tag}`);
    await $`git tag -a ${tag} -m ${`Inline macOS ${version}`}`;

    console.log(`• Pushing to ${gitRemote}`);
    await $`git push ${gitRemote} HEAD`;
    await $`git push ${gitRemote} ${tag}`;

    console.log(`Release tag created and pushed: ${tag}`);
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    console.error(`Release failed: ${message}`);
    process.exitCode = 1;
  }
}

function readVersionArg(args: string[]): string {
  const versionArgIndex = args.findIndex((arg) => arg === "--version" || arg === "-v");
  if (versionArgIndex !== -1) {
    const value = args[versionArgIndex + 1];
    if (!value) {
      throw new Error("Missing value after --version.");
    }
    return value;
  }
  if (args[0]) {
    return args[0];
  }
  throw new Error(
    "Usage: bun run scripts/macos/update-version.ts --version X.Y.Z [--undo] [-y]",
  );
}

function assertSemver(version: string) {
  if (!/^\d+\.\d+\.\d+$/.test(version)) {
    throw new Error(`Invalid version '${version}'. Expected format X.Y.Z`);
  }
}

async function assertCleanGit() {
  const status = await $`git status --porcelain`.text();
  if (status.trim().length > 0) {
    throw new Error(
      "Working tree is not clean. Commit or stash changes first.",
    );
  }
}

async function assertXcodeprojInstalled() {
  const result = await $`command -v xcodeproj`.text();
  if (!result.trim()) {
    throw new Error(
      "xcodeproj not found. Install with: gem install xcodeproj",
    );
  }
}

async function assertTagDoesNotExist(tag: string, remote: string) {
  const local = await $`git tag --list ${tag}`.text();
  if (local.trim() === tag) {
    throw new Error(`Tag already exists locally: ${tag}`);
  }
  const remoteResult = await $`git ls-remote --tags ${remote} ${tag}`.text();
  if (remoteResult.trim().length > 0) {
    throw new Error(`Tag already exists on ${remote}: ${tag}`);
  }
}

async function updateMarketingVersion(
  project: string,
  target: string,
  configs: string[],
  versionValue: string,
) {
  const script = `
    require "xcodeproj"
    project = Xcodeproj::Project.open(${JSON.stringify(project)})
    target_name = ${JSON.stringify(target)}
    target = project.targets.find { |t| t.name == target_name }
    abort("Target not found: #{target_name}") unless target
    config_names = ${JSON.stringify(configs)}
    updated = false
    target.build_configurations.each do |config|
      next unless config_names.include?(config.name)
      config.build_settings["MARKETING_VERSION"] = ${JSON.stringify(versionValue)}
      updated = true
    end
    abort("No configs updated for #{target_name}") unless updated
    project.save
  `;
  await $`ruby -e ${script}`;
}

async function readMarketingVersion(
  project: string,
  target: string,
  configs: string[],
): Promise<string> {
  const script = `
    require "xcodeproj"
    project = Xcodeproj::Project.open(${JSON.stringify(project)})
    target_name = ${JSON.stringify(target)}
    target = project.targets.find { |t| t.name == target_name }
    abort("Target not found: #{target_name}") unless target
    config_names = ${JSON.stringify(configs)}
    version = nil
    target.build_configurations.each do |config|
      next unless config_names.include?(config.name)
      version = config.build_settings["MARKETING_VERSION"]
      break if version
    end
    abort("MARKETING_VERSION not found for #{target_name}") unless version
    puts version
  `;
  const result = await $`ruby -e ${script}`.text();
  return result.trim();
}

async function runUndo() {
  const lastMessage = (await $`git log -1 --pretty=%s`.text()).trim();
  if (!lastMessage.startsWith("apple: bump macos to ")) {
    throw new Error(
      `Last commit is not a macOS version bump: "${lastMessage}"`,
    );
  }

  const currentVersion = await readMarketingVersion(
    projectPath,
    targetName,
    configNames,
  );

  const previousVersion = await readPreviousMarketingVersion();
  if (!previousVersion) {
    throw new Error("Unable to read previous MARKETING_VERSION from HEAD~1.");
  }
  if (previousVersion === currentVersion) {
    throw new Error(`MARKETING_VERSION already set to ${previousVersion}.`);
  }

  console.log(`• Reverting MARKETING_VERSION to ${previousVersion}`);
  await updateMarketingVersion(projectPath, targetName, configNames, previousVersion);

  console.log("• Committing version revert");
  await $`git add ${projectPath}`;
  await $`git commit -m ${`apple: revert macos to ${previousVersion}`}`;

  console.log(
    "Undo complete. If you already pushed a macos-vX.Y.Z tag, delete it manually if needed.",
  );
}

async function readPreviousMarketingVersion(): Promise<string | null> {
  const tempRoot = await mkdtemp(join(tmpdir(), "inline-macos-undo-"));
  const tempProject = join(tempRoot, "Inline.xcodeproj");
  const pbxprojPath = join(tempProject, "project.pbxproj");
  try {
    const pbxproj = await $`git show HEAD~1:${projectPbxprojGitPath}`.text();
    await mkdir(tempProject, { recursive: true });
    await writeFile(pbxprojPath, pbxproj);
    return await readMarketingVersion(tempProject, targetName, configNames);
  } finally {
    await rm(tempRoot, { recursive: true, force: true });
  }
}

async function confirmVersionChange(current: string, next: string) {
  console.log("Release confirmation:");
  console.log(`  Current MARKETING_VERSION: ${current}`);
  console.log(`  Next MARKETING_VERSION:    ${next}`);
  const answer = await prompt("Proceed? (y/N): ");
  if (!/^(y|yes)$/i.test(answer.trim())) {
    throw new Error("Aborted by user.");
  }
}

async function prompt(message: string): Promise<string> {
  process.stdout.write(message);
  return new Promise((resolve) => {
    process.stdin.setEncoding("utf8");
    process.stdin.once("data", (data) => resolve(String(data)));
  });
}
