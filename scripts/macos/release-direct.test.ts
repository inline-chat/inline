import { describe, expect, test } from "bun:test";
import { createHash } from "node:crypto";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import {
  appcastConditionFromEnv,
  appcastConditionalHeaders,
  conditionalAppcastPut,
  uploadDmgPut,
  validateDmgAttestation,
  validateUploadMode,
} from "./release-direct";

describe("conditional appcast publication", () => {
  test("the uploader accepts only one explicit mutation mode", () => {
    expect(validateUploadMode("dmg")).toBe("dmg");
    expect(validateUploadMode("appcast")).toBe("appcast");
    expect(() => validateUploadMode("all")).toThrow("expected dmg or appcast");
    expect(() => validateUploadMode("")).toThrow("expected dmg or appcast");
  });

  test("DMG upload requires an exact size and SHA-256 attestation", () => {
    const fixture = resolve(import.meta.dir, "test-fixtures/sign-update.txt");
    const file = Bun.file(fixture);
    const hash = new TextDecoder().decode(Bun.spawnSync(["shasum", "-a", "256", fixture]).stdout).split(/\s+/, 1)[0];
    expect(() => validateDmgAttestation(fixture, String(file.size), hash)).not.toThrow();
    expect(() => validateDmgAttestation(fixture, String(file.size + 1), hash)).toThrow("attestation mismatch");
    expect(() => validateDmgAttestation(fixture, String(file.size), "0".repeat(64))).toThrow("attestation mismatch");
    expect(() => validateDmgAttestation(fixture, "", "")).toThrow("requires valid");
  });

  test("DMG upload uses a bounded immutable presigned PUT", async () => {
    let method = "";
    let headers: Headers | undefined;
    let signal: AbortSignal | null | undefined;
    const fakeFetch: typeof fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      method = init?.method ?? "";
      headers = new Headers(init?.headers);
      signal = init?.signal;
      return new Response(null, { status: 200 });
    }) as typeof fetch;
    await uploadDmgPut(
      "https://r2.invalid/Inline.dmg",
      resolve(import.meta.dir, "test-fixtures/sign-update.txt"),
      fakeFetch,
    );
    expect(method).toBe("PUT");
    expect(headers?.get("if-none-match")).toBe("*");
    expect(headers?.get("content-type")).toBe("application/octet-stream");
    expect(headers?.get("cache-control")).toBe("public, max-age=31536000, immutable");
    expect(signal).toBeInstanceOf(AbortSignal);
  });
  test("DMG upload refuses to replace an occupied build object", async () => {
    const fakeFetch: typeof fetch = (async (_input: RequestInfo | URL, _init?: RequestInit) =>
      new Response("PreconditionFailed", { status: 412 })) as typeof fetch;
    await expect(uploadDmgPut(
      "https://r2.invalid/Inline.dmg",
      resolve(import.meta.dir, "test-fixtures/sign-update.txt"),
      fakeFetch,
    )).rejects.toThrow("refusing to overwrite immutable release bytes");
  });
  test("a resumed DMG upload accepts only identical remote bytes", async () => {
    const path = resolve(import.meta.dir, "test-fixtures/sign-update.txt");
    const bytes = readFileSync(path);
    const existing = {
      readUrl: "https://r2.invalid/read/Inline.dmg",
      size: bytes.length,
      sha256: createHash("sha256").update(bytes).digest("hex"),
    };
    const fakeFetch: typeof fetch = (async (_input: RequestInfo | URL, init?: RequestInit) =>
      init?.method === "PUT"
        ? new Response("PreconditionFailed", { status: 412 })
        : new Response(bytes)) as typeof fetch;
    await expect(uploadDmgPut("https://r2.invalid/Inline.dmg", path, fakeFetch, existing)).resolves.toBeUndefined();
    await expect(uploadDmgPut("https://r2.invalid/Inline.dmg", path, fakeFetch, {
      ...existing,
      sha256: "0".repeat(64),
    })).rejects.toThrow("differs from the attested artifact");
  });
  test("existing feeds require their exact fetched ETag", () => {
    const condition = appcastConditionFromEnv({ APPCAST_EXPECTED_ETAG: '"abc123"' });
    expect(appcastConditionalHeaders(condition)).toEqual({ "If-Match": '"abc123"' });
  });

  test("first publication requires absent-object semantics", () => {
    const condition = appcastConditionFromEnv({ APPCAST_EXPECT_ABSENT: "1" });
    expect(appcastConditionalHeaders(condition)).toEqual({ "If-None-Match": "*" });
    expect(() => appcastConditionFromEnv({})).toThrow("requires exactly one");
    expect(() => appcastConditionFromEnv({ APPCAST_EXPECTED_ETAG: '"abc"', APPCAST_EXPECT_ABSENT: "1" })).toThrow("requires exactly one");
  });

  test("stale feed tokens fail closed at the actual PUT", async () => {
    let headers: Headers | undefined;
    const fakeFetch: typeof fetch = (async (_input: RequestInfo | URL, init?: RequestInit) => {
      headers = new Headers(init?.headers);
      return new Response("PreconditionFailed", { status: 412 });
    }) as typeof fetch;
    await expect(conditionalAppcastPut(
      "https://r2.invalid/appcast.xml",
      resolve(import.meta.dir, "test-fixtures/appcast-existing-build.xml"),
      { expectedEtag: '"stale"', expectAbsent: false },
      fakeFetch,
    )).rejects.toThrow("changed after it was fetched");
    expect(headers?.get("if-match")).toBe('"stale"');
  });
});
