import { S3Client } from "bun";
import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

type AppcastCondition =
  | { expectedEtag: string; expectAbsent: false }
  | { expectedEtag: ""; expectAbsent: true };

export function validateUploadMode(mode: string): "dmg" | "appcast" {
  if (mode !== "dmg" && mode !== "appcast") {
    throw new Error(`Invalid UPLOAD_MODE: ${mode} (expected dmg or appcast)`);
  }
  return mode;
}

function requireEnv(name: string): string {
  const value = process.env[name]?.trim();
  if (!value) throw new Error(`Missing required env var: ${name}`);
  return value;
}

function trimSlash(value: string): string {
  return value.replace(/^\/+|\/+$/g, "");
}

export function validateDmgAttestation(
  dmgPath: string,
  expectedSizeRaw: string | undefined,
  expectedSha256Raw: string | undefined,
): void {
  const expectedSize = Number.parseInt(expectedSizeRaw?.trim() ?? "", 10);
  const expectedSha256 = expectedSha256Raw?.trim() ?? "";
  if (!Number.isSafeInteger(expectedSize) || expectedSize < 1 || !/^[0-9a-f]{64}$/.test(expectedSha256)) {
    throw new Error("DMG upload requires valid DMG_EXPECTED_SIZE and DMG_EXPECTED_SHA256 attestation values.");
  }
  const actualSize = Bun.file(dmgPath).size;
  const hashResult = Bun.spawnSync(["shasum", "-a", "256", dmgPath]);
  const actualSha256 = new TextDecoder().decode(hashResult.stdout).trim().split(/\s+/, 1)[0] ?? "";
  if (hashResult.exitCode !== 0 || actualSize !== expectedSize || actualSha256 !== expectedSha256) {
    throw new Error(`DMG attestation mismatch: actual ${actualSize} bytes sha256 ${actualSha256 || "unavailable"}; expected ${expectedSize} bytes sha256 ${expectedSha256}.`);
  }
}

function getR2Context() {
  const accessKeyId = requireEnv("PUBLIC_RELEASES_R2_ACCESS_KEY_ID");
  const secretAccessKey = requireEnv("PUBLIC_RELEASES_R2_SECRET_ACCESS_KEY");
  const bucket = requireEnv("PUBLIC_RELEASES_R2_BUCKET");
  const endpoint = requireEnv("PUBLIC_RELEASES_R2_ENDPOINT");
  const publicBaseUrl = trimSlash(requireEnv("PUBLIC_RELEASES_R2_PUBLIC_BASE_URL"));
  const prefix = "mac";
  const r2 = new S3Client({ accessKeyId, secretAccessKey, bucket, endpoint });
  return { r2, publicBaseUrl, prefix };
}

async function uploadFile(
  r2: S3Client,
  key: string,
  path: string,
  contentType: string,
  cacheControl?: string,
) {
  await r2.file(key).write(Bun.file(path), {
    type: contentType,
    cacheControl,
  } as never);
}

export function appcastConditionFromEnv(env: Record<string, string | undefined>): AppcastCondition {
  const expectedEtag = env.APPCAST_EXPECTED_ETAG?.trim() ?? "";
  const expectAbsent = env.APPCAST_EXPECT_ABSENT === "1";
  if (Boolean(expectedEtag) === expectAbsent) {
    throw new Error("Appcast upload requires exactly one of APPCAST_EXPECTED_ETAG or APPCAST_EXPECT_ABSENT=1.");
  }
  if (expectedEtag.includes("\n") || expectedEtag.includes("\r")) {
    throw new Error("APPCAST_EXPECTED_ETAG contains an invalid newline.");
  }
  return expectAbsent ? { expectedEtag: "", expectAbsent: true } : { expectedEtag, expectAbsent: false };
}

export function appcastConditionalHeaders(condition: AppcastCondition): Record<string, string> {
  return condition.expectAbsent
    ? { "If-None-Match": "*" }
    : { "If-Match": condition.expectedEtag };
}

export async function conditionalAppcastPut(
  uploadUrl: string,
  appcastPath: string,
  condition: AppcastCondition,
  fetchImpl: typeof fetch = fetch,
): Promise<void> {
  const response = await fetchImpl(uploadUrl, {
    method: "PUT",
    headers: {
      ...appcastConditionalHeaders(condition),
      "Content-Type": "application/xml",
      "Cache-Control": "no-cache, max-age=0, must-revalidate",
    },
    body: Bun.file(appcastPath),
  });
  if (response.ok) return;
  const detail = (await response.text()).trim().slice(0, 500);
  if (response.status === 412) {
    throw new Error("Appcast changed after it was fetched; conditional R2 upload failed with HTTP 412. Fetch the current feed and retry.");
  }
  throw new Error(`Conditional appcast upload failed with HTTP ${response.status}${detail ? `: ${detail}` : ""}`);
}

function assertOwnedChannelLock(rootDir: string, channel: string, token: string): void {
  const lockDir = resolve(rootDir, "build/macos-release-locks", `channel-${channel}.lockdir`);
  const ownerPath = resolve(lockDir, "owner.json");
  if (!existsSync(ownerPath)) throw new Error(`Owned channel lock not found at ${ownerPath}`);
  const owner = JSON.parse(readFileSync(ownerPath, "utf8")) as { token?: string; channel?: string };
  if (owner.token !== token || owner.channel !== channel) {
    throw new Error(`Channel lock ownership mismatch at ${ownerPath}`);
  }
}

async function main(): Promise<void> {
  const rootDir = resolve(import.meta.dir, "../..");
  const supportedChannels = ["stable", "beta", "tip"] as const;
  const channel = requireEnv("CHANNEL");
  if (!supportedChannels.some((supportedChannel) => supportedChannel === channel)) {
    throw new Error(`Invalid CHANNEL: ${channel}`);
  }
  const build = requireEnv("BUILD_NUMBER");
  const uploadMode = validateUploadMode(requireEnv("UPLOAD_MODE"));

  const dmgPath = process.env.DMG_PATH ? resolve(process.env.DMG_PATH) : "";
  const appcastPath = process.env.APPCAST_PATH ? resolve(process.env.APPCAST_PATH) : "";
  if (uploadMode === "dmg" && (!dmgPath || !existsSync(dmgPath))) {
    throw new Error(`DMG_PATH must name an existing file for UPLOAD_MODE=${uploadMode}`);
  }
  if (uploadMode === "appcast" && (!appcastPath || !existsSync(appcastPath))) {
    throw new Error(`APPCAST_PATH must name an existing file for UPLOAD_MODE=${uploadMode}`);
  }
  if (uploadMode === "dmg") {
    validateDmgAttestation(dmgPath, process.env.DMG_EXPECTED_SIZE, process.env.DMG_EXPECTED_SHA256);
  }
  const condition = uploadMode === "appcast" ? appcastConditionFromEnv(process.env) : undefined;
  const lockToken = requireEnv("RELEASE_CHANNEL_LOCK_TOKEN");
  assertOwnedChannelLock(rootDir, channel, lockToken);
  const { r2, publicBaseUrl, prefix } = getR2Context();
  const dmgKey = `${prefix}/${channel}/${build}/Inline.dmg`;
  const appcastKey = `${prefix}/${channel}/appcast.xml`;

  if (uploadMode === "dmg") {
    await uploadFile(r2, dmgKey, dmgPath, "application/octet-stream", "public, max-age=31536000, immutable");
  }

  if (uploadMode === "appcast") {
    const uploadUrl = r2.presign(appcastKey, { method: "PUT", expiresIn: 300 });
    await conditionalAppcastPut(uploadUrl, appcastPath, condition!);
  }

  console.log("Uploaded macOS artifacts:");
  if (uploadMode === "dmg") console.log(`  DMG: ${publicBaseUrl}/${dmgKey}`);
  if (uploadMode === "appcast") console.log(`  Appcast: ${publicBaseUrl}/${appcastKey}`);
}

if (import.meta.main) await main();
