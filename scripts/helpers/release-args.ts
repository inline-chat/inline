export type ReleaseChannel = "stable" | "beta";
export type VersionBump = "major" | "minor" | "patch" | "prerelease";

export type ReleaseArgs = {
  allowDirty: boolean;
  bump: VersionBump | null;
  channel: ReleaseChannel;
  command: string;
  dryRun: boolean;
  help: boolean;
  notesFile: string | null;
  npmTag: string | null;
  push: boolean;
  resume: boolean;
  skipChecks: boolean;
  skipClawHub: boolean;
  skipGit: boolean;
  skipGitHub: boolean;
  skipNpm: boolean;
  version: string | null;
  yes: boolean;
};

type ParseOptions = {
  defaultCommand?: string;
};

const boolFlags = new Set([
  "allow-dirty",
  "dry-run",
  "help",
  "no-push",
  "push",
  "resume",
  "skip-checks",
  "skip-clawhub",
  "skip-git",
  "skip-github",
  "skip-npm",
  "yes",
]);

const valueFlags = new Set([
  "bump",
  "channel",
  "notes-file",
  "npm-tag",
  "version",
]);

export function parseReleaseArgs(
  argv: readonly string[],
  options: ParseOptions = {},
): ReleaseArgs {
  const out: ReleaseArgs = {
    allowDirty: false,
    bump: null,
    channel: "stable",
    command: options.defaultCommand ?? "release",
    dryRun: false,
    help: false,
    notesFile: null,
    npmTag: null,
    push: true,
    resume: false,
    skipChecks: false,
    skipClawHub: false,
    skipGit: false,
    skipGitHub: false,
    skipNpm: false,
    version: null,
    yes: false,
  };

  let commandSeen = false;
  for (let i = 0; i < argv.length; i += 1) {
    const raw = argv[i];
    if (!raw.startsWith("-")) {
      if (commandSeen) {
        throw new Error(`Unexpected positional argument: ${raw}`);
      }
      out.command = raw;
      commandSeen = true;
      continue;
    }

    const flag = raw.replace(/^-+/, "");
    const [name, inlineValue] = flag.split("=", 2);
    if (name === "y") {
      out.yes = true;
      continue;
    }

    if (boolFlags.has(name)) {
      setBool(out, name);
      continue;
    }

    if (!valueFlags.has(name)) {
      throw new Error(`Unknown option: --${name}`);
    }

    const value = inlineValue ?? argv[i + 1];
    if (!value || value.startsWith("-")) {
      throw new Error(`Missing value for --${name}`);
    }
    if (inlineValue === undefined) i += 1;
    setValue(out, name, value);
  }

  return out;
}

export function npmTagForChannel(args: ReleaseArgs): string {
  return args.npmTag ?? (args.channel === "stable" ? "latest" : "beta");
}

export function releaseUsage(product: string): string {
  return [
    `Usage: bun run release:${product} -- <command> [options]`,
    "",
    "Commands:",
    "  status      Show versions, auth, tags, and remote publish state",
    "  prepare     Bump/version/check/commit without publishing externally",
    "  publish     Publish the current checked-in version",
    "  release     Prepare if needed, then publish",
    "  verify      Verify remote publish state",
    "",
    "Options:",
    "  --channel stable|beta",
    "  --version X.Y.Z[-beta.N]",
    "  --bump major|minor|patch|prerelease",
    "  --npm-tag <tag>",
    "  --dry-run",
    "  --yes",
    "  --resume",
    "  --skip-checks",
    "  --skip-git",
    "  --skip-github",
    "  --skip-npm",
    "  --skip-clawhub",
    "  --allow-dirty",
  ].join("\n");
}

function setBool(out: ReleaseArgs, name: string) {
  switch (name) {
    case "allow-dirty":
      out.allowDirty = true;
      return;
    case "dry-run":
      out.dryRun = true;
      return;
    case "help":
      out.help = true;
      return;
    case "no-push":
      out.push = false;
      return;
    case "push":
      out.push = true;
      return;
    case "resume":
      out.resume = true;
      return;
    case "skip-checks":
      out.skipChecks = true;
      return;
    case "skip-clawhub":
      out.skipClawHub = true;
      return;
    case "skip-git":
      out.skipGit = true;
      return;
    case "skip-github":
      out.skipGitHub = true;
      return;
    case "skip-npm":
      out.skipNpm = true;
      return;
    case "yes":
      out.yes = true;
      return;
    default:
      throw new Error(`Unhandled option: --${name}`);
  }
}

function setValue(out: ReleaseArgs, name: string, value: string) {
  switch (name) {
    case "bump":
      if (!isVersionBump(value)) {
        throw new Error(`Invalid bump: ${value}`);
      }
      out.bump = value;
      return;
    case "channel":
      if (value !== "stable" && value !== "beta") {
        throw new Error(`Invalid channel: ${value}`);
      }
      out.channel = value;
      return;
    case "notes-file":
      out.notesFile = value;
      return;
    case "npm-tag":
      out.npmTag = value;
      return;
    case "version":
      out.version = value;
      return;
    default:
      throw new Error(`Unhandled option: --${name}`);
  }
}

function isVersionBump(value: string): value is VersionBump {
  return ["major", "minor", "patch", "prerelease"].includes(value);
}
