import { mkdir, writeFile } from "fs/promises";
import { dirname, join } from "path";
import { capture, run } from "./command.ts";
import type { ReleaseLog } from "./release-ui.ts";

type GitOptions = {
  dryRun?: boolean;
  log?: ReleaseLog;
};

export async function statusPorcelain(
  rootDir: string,
  paths: readonly string[] = [],
): Promise<string> {
  const args = ["git", "status", "--porcelain", "--", ...paths];
  const result = await capture(args, { cwd: rootDir, quiet: true });
  return result.stdout.trim();
}

export async function assertCleanWorktree(
  rootDir: string,
  options: { allowDirty?: boolean; paths?: readonly string[] } = {},
) {
  if (options.allowDirty) return;
  const status = await statusPorcelain(rootDir, options.paths ?? []);
  if (status.length > 0) {
    throw new Error(
      `Working tree has release-relevant changes:\n${status}\nCommit them first or pass --allow-dirty.`,
    );
  }
}

export async function tagExistsLocal(rootDir: string, tag: string): Promise<boolean> {
  const result = await capture(["git", "tag", "--list", tag], {
    cwd: rootDir,
    quiet: true,
  });
  return result.stdout.trim() === tag;
}

export async function tagExistsRemote(
  rootDir: string,
  remote: string,
  tag: string,
): Promise<boolean> {
  const result = await capture(["git", "ls-remote", "--tags", remote, tag], {
    cwd: rootDir,
    quiet: true,
  });
  return result.stdout.trim().length > 0;
}

export async function assertTagAvailable(
  rootDir: string,
  remote: string,
  tag: string,
) {
  if (await tagExistsLocal(rootDir, tag)) {
    throw new Error(`Tag already exists locally: ${tag}`);
  }
  if (await tagExistsRemote(rootDir, remote, tag)) {
    throw new Error(`Tag already exists on ${remote}: ${tag}`);
  }
}

export async function commitFiles(
  rootDir: string,
  message: string,
  files: readonly string[],
  options: GitOptions = {},
) {
  if (files.length === 0) return;
  await run(["git", "add", "--", ...files], {
    cwd: rootDir,
    dryRun: options.dryRun,
    log: options.log,
  });
  await run(["git", "commit", "-m", message, "--", ...files], {
    cwd: rootDir,
    dryRun: options.dryRun,
    log: options.log,
  });
}

export async function createAnnotatedTag(
  rootDir: string,
  tag: string,
  message: string,
  options: GitOptions = {},
) {
  await run(["git", "tag", "-a", tag, "-m", message], {
    cwd: rootDir,
    dryRun: options.dryRun,
    log: options.log,
  });
}

export async function pushHeadAndTag(
  rootDir: string,
  remote: string,
  tag: string,
  options: GitOptions = {},
) {
  await run(["git", "push", remote, "HEAD"], {
    cwd: rootDir,
    dryRun: options.dryRun,
    log: options.log,
  });
  await run(["git", "push", remote, tag], {
    cwd: rootDir,
    dryRun: options.dryRun,
    log: options.log,
  });
}

export async function latestTag(
  rootDir: string,
  prefix: string,
): Promise<string | null> {
  const result = await capture(
    ["git", "tag", "--list", `${prefix}*`, "--sort=-creatordate"],
    { cwd: rootDir, quiet: true },
  );
  return result.stdout
    .split("\n")
    .map((line) => line.trim())
    .find((line) => line.length > 0) ?? null;
}

export async function releaseNotes(
  rootDir: string,
  params: {
    paths: readonly string[];
    prefix: string;
    product: string;
    version: string;
  },
): Promise<string> {
  const fromTag = await latestTag(rootDir, params.prefix);
  const range = fromTag ? [`${fromTag}..HEAD`] : ["HEAD"];
  const result = await capture(
    ["git", "log", ...range, "--pretty=format:- %h %s", "--", ...params.paths],
    { cwd: rootDir, quiet: true },
  );
  const body = result.stdout.trim() || "- No scoped commits found.";
  return [
    `# ${params.product} v${params.version}`,
    "",
    fromTag ? `Changes since ${fromTag}.` : "Initial scoped release notes.",
    "",
    body,
    "",
  ].join("\n");
}

export async function writeReleaseNotes(
  rootDir: string,
  params: {
    notesFile?: string | null;
    paths: readonly string[];
    prefix: string;
    product: string;
    version: string;
  },
): Promise<string> {
  const path =
    params.notesFile ??
    join(rootDir, ".tmp", "release-notes", `${params.prefix}${params.version}.md`);
  const notes = await releaseNotes(rootDir, params);
  await mkdir(dirname(path), { recursive: true });
  await writeFile(path, notes);
  return path;
}

export async function createGitHubRelease(
  rootDir: string,
  params: {
    draft?: boolean;
    dryRun?: boolean;
    log?: ReleaseLog;
    notesFile: string;
    prerelease?: boolean;
    repo?: string;
    tag: string;
    title: string;
  },
) {
  const args = ["gh", "release", "create", params.tag, "--title", params.title, "--notes-file", params.notesFile];
  if (params.repo) args.push("--repo", params.repo);
  if (params.prerelease) args.push("--prerelease");
  if (params.draft) args.push("--draft");
  await run(args, { cwd: rootDir, dryRun: params.dryRun, log: params.log });
}
