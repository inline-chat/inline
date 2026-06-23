import { capture, commandExists, run } from "./command.ts";
import type { ReleaseLog } from "./release-ui.ts";

const registry = "https://registry.npmjs.org/";

type NpmOptions = {
  cwd: string;
  dryRun?: boolean;
  log: ReleaseLog;
};

export async function npmWhoami(cwd: string): Promise<string | null> {
  const result = await capture(["npm", "whoami", "--registry", registry], {
    allowFailure: true,
    cwd,
    quiet: true,
  });
  return result.exitCode === 0 ? result.stdout.trim() : null;
}

export async function ensureNpmPublishAuth(options: NpmOptions) {
  const user = await npmWhoami(options.cwd);
  if (user) {
    options.log.ok(`npm authenticated as ${user}`);
    return;
  }
  if (options.dryRun) {
    options.log.skip("npm login skipped in dry-run mode");
    return;
  }

  options.log.step("Refreshing npm session with 1Password");
  if (!(await commandExists("op"))) {
    throw new Error("1Password CLI not found. Install/sign in to `op` or run npm login manually.");
  }
  if (!(await commandExists("expect"))) {
    throw new Error("expect not found. Install expect or run npm login manually.");
  }

  const username = await op(["read", "op://Codex/NPM/username"]);
  const password = await op(["read", "op://Codex/NPM/password"]);
  const otp = await npmOtp();
  const script = `log_user 0
set timeout 60
spawn npm login --auth-type=legacy --registry=${registry}
expect {
  -re "Username:" { send -- "$env(NPM_USER)\\r"; exp_continue }
  -re "Password:" { send -- "$env(NPM_PASS)\\r"; exp_continue }
  -re "Email:.*" { send -- "\\r"; exp_continue }
  -re "one-time password|OTP|otp" { send -- "$env(NPM_OTP)\\r"; exp_continue }
  eof { catch wait result; exit [lindex $result 3] }
  timeout { exit 124 }
}`;
  const result = await run(["expect", "-c", script], {
    allowFailure: true,
    cwd: options.cwd,
    env: {
      NPM_OTP: otp,
      NPM_PASS: password,
      NPM_USER: username,
    },
    quiet: true,
  });
  if (result.exitCode !== 0) {
    throw new Error("npm login failed. Check the Codex/NPM 1Password item.");
  }

  const nextUser = await npmWhoami(options.cwd);
  if (!nextUser) {
    throw new Error("npm login completed but npm whoami still failed.");
  }
  options.log.ok(`npm authenticated as ${nextUser}`);
}

export async function npmPublish(
  options: NpmOptions & {
    access?: "public" | "restricted";
    tag: string;
  },
) {
  await ensureNpmPublishAuth(options);
  const otp = options.dryRun ? "<dry-run>" : await npmOtp();
  await run(
    [
      "npm",
      "publish",
      "--access",
      options.access ?? "public",
      "--tag",
      options.tag,
      "--otp",
      otp,
    ],
    {
      cwd: options.cwd,
      dryRun: options.dryRun,
      log: options.log,
    },
  );
}

export async function npmPackDryRun(options: NpmOptions) {
  await run(["npm", "pack", "--dry-run"], {
    cwd: options.cwd,
    dryRun: options.dryRun,
    log: options.log,
  });
}

export async function npmPackageVersionExists(
  cwd: string,
  name: string,
  version: string,
): Promise<boolean> {
  const result = await capture(
    ["npm", "view", `${name}@${version}`, "version", "--registry", registry],
    {
      allowFailure: true,
      cwd,
      quiet: true,
    },
  );
  return result.exitCode === 0 && result.stdout.trim() === version;
}

export async function npmViewPackage(
  cwd: string,
  name: string,
): Promise<{ version?: string; "dist-tags"?: Record<string, string> } | null> {
  const result = await capture(
    ["npm", "view", name, "version", "dist-tags", "--json", "--registry", registry],
    {
      allowFailure: true,
      cwd,
      quiet: true,
    },
  );
  if (result.exitCode !== 0 || !result.stdout.trim()) return null;
  return JSON.parse(result.stdout) as {
    version?: string;
    "dist-tags"?: Record<string, string>;
  };
}

async function npmOtp(): Promise<string> {
  return await op(["item", "get", "NPM", "--vault", "Codex", "--otp"]);
}

async function op(args: readonly string[]): Promise<string> {
  const result = await capture(["op", ...args], { quiet: true });
  return result.stdout.trim();
}
