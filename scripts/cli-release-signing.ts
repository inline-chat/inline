import { createPrivateKey, createPublicKey, sign, verify, type KeyObject } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";

const root = resolve(import.meta.dir, "..");
export const signingDomain = Buffer.from("inline-cli-channel-v1\0");
export type Channel = "stable" | "alpha";
type Manifest = { version: string; sourceSha: string; publishedAt: string; targets: Record<string, { url: string; sha256: string; size: number }> };
export type SignedEnvelope = { payload: string; signatures: { keyId: string; signature: string }[] };

export async function releaseSigner(): Promise<{ keyId: string; key: KeyObject }> {
  const encoded = process.env.INLINE_CLI_MANIFEST_SIGNING_KEY;
  if (!encoded) throw new Error("Missing INLINE_CLI_MANIFEST_SIGNING_KEY; publication cannot enable unsigned automatic updates");
  let key: KeyObject;
  try { key = createPrivateKey({ key: Buffer.from(encoded, "base64"), type: "pkcs8", format: "der" }); }
  catch { throw new Error("Invalid CLI manifest signing key"); }
  if (key.asymmetricKeyType !== "ed25519") throw new Error("CLI release signing requires Ed25519");
  const publicKey = createPublicKey(key).export({ format: "jwk" });
  if (!publicKey.x) throw new Error("CLI signing key has no public component");
  const raw = Buffer.from(publicKey.x, "base64url").toString("base64");
  const pinned = JSON.parse(await readFile(resolve(root, "cli/release-keys.json"), "utf8")) as Record<string, string>;
  const keyId = Object.keys(pinned).find((id) => pinned[id] === raw);
  if (!keyId) throw new Error("CLI signer does not match a shipped verification key");
  const probe = Buffer.from("inline-cli-signing-preflight");
  if (!verify(null, probe, createPublicKey(key), sign(null, probe, key))) throw new Error("CLI signing preflight failed");
  return { keyId, key };
}

export function signedPayload(payload: unknown, keyId: string, key: KeyObject): SignedEnvelope {
  const bytes = Buffer.from(JSON.stringify(payload));
  return { payload: bytes.toString("base64"), signatures: [{ keyId, signature: sign(null, Buffer.concat([signingDomain, bytes]), key).toString("base64") }] };
}

export async function signedChannel(manifest: Manifest, channel: Channel): Promise<string> {
  const { keyId, key } = await releaseSigner();
  if (!manifest.sourceSha || !/^[a-f0-9]{40}$/.test(manifest.sourceSha)) throw new Error("Signed CLI release requires an exact source identity");
  if (channel === "stable" && manifest.version.includes("-")) throw new Error("Stable channel cannot name a prerelease");
  const compatibility = JSON.parse(await readFile(resolve(root, "cli/update-compatibility.json"), "utf8"));
  const generation = Date.parse(manifest.publishedAt);
  if (!Number.isSafeInteger(generation) || generation <= 0) throw new Error("Invalid CLI publication generation");
  const envelope = signedPayload({ formatVersion: 1, channel, generation, version: manifest.version, sourceSha: manifest.sourceSha, ...compatibility, targets: manifest.targets }, keyId, key);
  return JSON.stringify(envelope);
}

export async function authenticatedChannelVersion(text: string, channel: Channel): Promise<{ version: string; sourceSha: string; generation: number }> {
  const envelope = JSON.parse(text) as SignedEnvelope;
  const payload = Buffer.from(envelope.payload, "base64");
  const keys = JSON.parse(await readFile(resolve(root, "cli/release-keys.json"), "utf8")) as Record<string, string>;
  const valid = envelope.signatures.some(({ keyId, signature }) => {
    const raw = keys[keyId];
    if (!raw) return false;
    const key = createPublicKey({ key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(raw, "base64").toString("base64url") }, format: "jwk" });
    return verify(null, Buffer.concat([signingDomain, payload]), key, Buffer.from(signature, "base64"));
  });
  if (!valid) throw new Error("Existing channel metadata failed verification");
  const decoded = JSON.parse(payload.toString("utf8"));
  if (decoded.channel !== channel || decoded.formatVersion !== 1 || !Number.isSafeInteger(decoded.generation) || decoded.generation <= 0 || !/^[a-f0-9]{40}$/.test(decoded.sourceSha) || typeof decoded.version !== "string") throw new Error("Existing channel metadata has an incompatible contract");
  return decoded;
}
