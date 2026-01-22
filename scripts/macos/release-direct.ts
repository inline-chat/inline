import { S3Client } from "bun";
import { existsSync } from "fs";
import { resolve } from "path";

function requireEnv(name: string): string {
  const value = process.env[name];
  if (!value) {
    throw new Error(`Missing required env var: ${name}`);
  }
  return value;
}

function trimSlash(value: string): string {
  return value.replace(/^\/+|\/+$/g, "");
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
  const file = r2.file(key);
  await file.write(Bun.file(path), {
    type: contentType,
    cacheControl,
  } as never);
}

const channel = process.env.CHANNEL ?? "stable";
const build = requireEnv("BUILD_NUMBER");
const dmgPath = resolve(process.env.DMG_PATH ?? "build/macos-direct/Inline.dmg");
const appcastPath = resolve(process.env.APPCAST_PATH ?? "appcast_new.xml");
const uploadMode = process.env.UPLOAD_MODE ?? "all";
if (!["all", "dmg", "appcast"].includes(uploadMode)) {
  throw new Error(`Invalid UPLOAD_MODE: ${uploadMode}`);
}

const { r2, publicBaseUrl, prefix } = getR2Context();

const dmgKey = `${prefix}/${channel}/${build}/Inline.dmg`;
const appcastKey = `${prefix}/${channel}/appcast.xml`;

if (uploadMode === "all" || uploadMode === "dmg") {
  await uploadFile(
    r2,
    dmgKey,
    dmgPath,
    "application/octet-stream",
    "public, max-age=31536000, immutable",
  );
}

if (uploadMode === "all" || uploadMode === "appcast") {
  if (!existsSync(appcastPath)) {
    throw new Error(`Appcast not found at ${appcastPath}`);
  }
  await uploadFile(
    r2,
    appcastKey,
    appcastPath,
    "application/xml",
    "no-cache, max-age=0, must-revalidate",
  );
}

console.log("Uploaded macOS artifacts:");
if (uploadMode === "all" || uploadMode === "dmg") {
  console.log(`  DMG: ${publicBaseUrl}/${dmgKey}`);
}
if (uploadMode === "all" || uploadMode === "appcast") {
  console.log(`  Appcast: ${publicBaseUrl}/${appcastKey}`);
}
