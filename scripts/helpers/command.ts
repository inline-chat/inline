import { ReleaseLog } from "./release-ui.ts";

export type CommandResult = {
  stdout: string;
  stderr: string;
  exitCode: number;
};

type CommandOptions = {
  allowFailure?: boolean;
  cwd?: string;
  dryRun?: boolean;
  env?: Record<string, string | undefined>;
  log?: ReleaseLog;
  quiet?: boolean;
  redact?: (args: readonly string[]) => string[];
};

export async function run(
  args: readonly string[],
  options: CommandOptions = {},
): Promise<CommandResult> {
  const redacted = redactArgs(args, options.redact);
  if (!options.quiet) {
    options.log?.command(commandText(redacted));
  }
  if (options.dryRun) {
    return { stdout: "", stderr: "", exitCode: 0 };
  }

  const proc = Bun.spawn([...args], {
    cwd: options.cwd,
    env: commandEnv(options.env),
    stderr: options.quiet ? "pipe" : "inherit",
    stdout: options.quiet ? "pipe" : "inherit",
  });

  const [stdout, stderr, exitCode] = await Promise.all([
    options.quiet ? new Response(proc.stdout).text() : Promise.resolve(""),
    options.quiet ? new Response(proc.stderr).text() : Promise.resolve(""),
    proc.exited,
  ]);

  if (exitCode !== 0 && !options.allowFailure) {
    throw new Error(`Command failed: ${commandText(redacted)}`);
  }

  return { stdout, stderr, exitCode };
}

export async function capture(
  args: readonly string[],
  options: CommandOptions = {},
): Promise<CommandResult> {
  const redacted = redactArgs(args, options.redact);
  if (!options.quiet) {
    options.log?.command(commandText(redacted));
  }
  if (options.dryRun) {
    return { stdout: "", stderr: "", exitCode: 0 };
  }

  const proc = Bun.spawn([...args], {
    cwd: options.cwd,
    env: commandEnv(options.env),
    stderr: "pipe",
    stdout: "pipe",
  });
  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);

  if (exitCode !== 0 && !options.allowFailure) {
    const output = (stderr || stdout).trim();
    const suffix = output ? `\n${output}` : "";
    throw new Error(`Command failed: ${commandText(redacted)}${suffix}`);
  }

  return { stdout, stderr, exitCode };
}

export async function commandExists(command: string): Promise<boolean> {
  const result = await capture(["which", command], {
    allowFailure: true,
    quiet: true,
  });
  return result.exitCode === 0 && result.stdout.trim().length > 0;
}

export function commandText(args: readonly string[]): string {
  return args.map(shellQuote).join(" ");
}

export function redactArgs(
  args: readonly string[],
  custom?: (args: readonly string[]) => string[],
): string[] {
  if (custom) return custom(args);
  const out = [...args];
  for (let i = 0; i < out.length; i += 1) {
    const arg = out[i];
    if (
      (arg === "--otp" || arg === "--password" || arg === "--token") &&
      i + 1 < out.length
    ) {
      out[i + 1] = "<redacted>";
    } else if (/^--(otp|password|token)=/.test(arg)) {
      out[i] = arg.replace(/=.*/, "=<redacted>");
    }
  }
  return out;
}

function commandEnv(env: Record<string, string | undefined> | undefined) {
  if (!env) return undefined;
  const out: Record<string, string> = {};
  for (const [key, value] of Object.entries(process.env)) {
    if (value !== undefined) out[key] = value;
  }
  for (const [key, value] of Object.entries(env)) {
    if (value === undefined) {
      delete out[key];
    } else {
      out[key] = value;
    }
  }
  return out;
}

function shellQuote(value: string): string {
  if (/^[A-Za-z0-9_./:=@+-]+$/.test(value)) return value;
  return `'${value.replace(/'/g, "'\\''")}'`;
}
