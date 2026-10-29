import { describe, expect, test } from "bun:test";
import { createPublicKey, verify } from "node:crypto";
import { readFile } from "node:fs/promises";
import { resolve } from "node:path";
import { shouldAdvanceSignedChannel } from "./release-cli";
import { signingDomain } from "./cli-release-signing";

const root = resolve(import.meta.dir, "..");
describe("signed CLI release contract", () => {
  test("the shared RFC vector authenticates the exact bytes and rejects mutations", async () => {
    const vector = await Bun.file(resolve(root, "cli/tests/fixtures/signed-channel.json")).json();
    const publicKey = createPublicKey({ format: "jwk", key: { kty: "OKP", crv: "Ed25519", x: Buffer.from(vector.keys.fixture, "base64").toString("base64url") } });
    const payload = Buffer.from(vector.envelope.payload, "base64");
    const signature = Buffer.from(vector.envelope.signatures[0].signature, "base64");
    expect(verify(null, Buffer.concat([signingDomain, payload]), publicKey, signature)).toBe(true);
    expect(JSON.parse(payload.toString("utf8"))).toEqual(vector.release);
    expect(verify(null, Buffer.concat([signingDomain, payload, Buffer.from(" ")]), publicKey, signature)).toBe(false);
    expect(verify(null, payload, publicKey, signature)).toBe(false);
  });

  test("publication never rolls a channel or generation backwards or rebinds a version", () => {
    const old = { version: "1.1.0-alpha.1", sourceSha: "a".repeat(40), generation: 100 };
    expect(shouldAdvanceSignedChannel(old, { ...old, version: "1.1.0-alpha.2", generation: 101 })).toBe(true);
    expect(shouldAdvanceSignedChannel(old, { ...old, version: "1.0.0", generation: 101 })).toBe(false);
    expect(() => shouldAdvanceSignedChannel(old, { ...old, version: "1.1.0-alpha.2", generation: 99 })).toThrow("generation");
    expect(() => shouldAdvanceSignedChannel(old, { ...old, sourceSha: "b".repeat(40) })).toThrow("source");
  });

  test("Rust, Mac bootstrap and release scripts ship identical trust roots and compatibility", async () => {
    const pinned = await readFile(resolve(root, "cli/release-keys.json"), "utf8");
    expect(JSON.parse(await readFile(resolve(root, "apple/InlineMacUI/Sources/InlineCLIInstaller/Resources/CLIReleaseKeys.json"), "utf8"))).toEqual(JSON.parse(pinned));
    const installer = await readFile(resolve(root, "cli/install.sh"), "utf8");
    for (const key of Object.values(JSON.parse(pinned))) {
      const der = Buffer.concat([Buffer.from("302a300506032b6570032100", "hex"), Buffer.from(String(key), "base64")]).toString("base64");
      expect(installer).toContain(der);
    }
    const compatibility = await Bun.file(resolve(root, "cli/update-compatibility.json")).json();
    const source = await readFile(resolve(root, "crates/agent-bridge/src/store.rs"), "utf8");
    expect(Number(source.match(/const CURRENT_SCHEMA_VERSION: i64 = (\d+)/)?.[1])).toBe(compatibility.bridgeSchemaVersion);
    expect(Number(source.match(/const MINIMUM_READER_SCHEMA_VERSION: i64 = (\d+)/)?.[1])).toBe(compatibility.minimumReaderSchemaVersion);
    expect(compatibility.supervisorProtocol).toBe(1);
  });
});
