import { describe, expect, test } from "bun:test";
import {
  buildReleaseEvidence,
  canonicalReleaseEvidenceJSON,
  sourceTreeSha256,
  type ReleaseEvidenceInput,
} from "./release-evidence-v2";

const a = "a".repeat(64);
const b = "b".repeat(64);

function input(overrides: Partial<ReleaseEvidenceInput> = {}): ReleaseEvidenceInput {
  return {
    channel: "beta",
    version: "1.2.3",
    buildNumber: "456",
    commit: "1234567890abcdef",
    clean: true,
    sourceFiles: [
      { path: "server/index.ts", sha256: b },
      { path: "apple/InlineMac/InlineApp.swift", sha256: a },
    ],
    executableSha256: a,
    dmgSha256: b,
    dSYMUUIDs: ["BBBB", "AAAA", "AAAA"],
    toolchain: { xcode: "26.4", swift: "6.3", macOS: "26.4" },
    validation: [
      { name: "smoke", status: "skipped", detail: "manual gate" },
      { name: "tests", status: "passed" },
    ],
    createdAt: "2026-08-09T00:00:00.000Z",
    ...overrides,
  };
}

describe("release evidence v2 spike", () => {
  test("normalizes order and produces one deterministic source fingerprint", () => {
    const first = buildReleaseEvidence(input());
    const second = buildReleaseEvidence(input({ sourceFiles: [...input().sourceFiles].reverse() }));

    expect(first.sourceFiles.map((file) => file.path)).toEqual([
      "apple/InlineMac/InlineApp.swift",
      "server/index.ts",
    ]);
    expect(first.sourceTreeSha256).toBe(second.sourceTreeSha256);
    expect(first.dSYMUUIDs).toEqual(["AAAA", "BBBB"]);
    expect(canonicalReleaseEvidenceJSON(first)).toBe(canonicalReleaseEvidenceJSON(second));
  });

  test("the fingerprint binds both path and content digest", () => {
    expect(sourceTreeSha256([{ path: "one", sha256: a }])).not.toBe(
      sourceTreeSha256([{ path: "two", sha256: a }]),
    );
    expect(sourceTreeSha256([{ path: "one", sha256: a }])).not.toBe(
      sourceTreeSha256([{ path: "one", sha256: b }]),
    );
  });

  test("rejects dirty release candidates but permits explicitly non-candidate investigations", () => {
    expect(() => buildReleaseEvidence(input({ clean: false }))).toThrow("clean recorded source tree");
    expect(buildReleaseEvidence(input({ clean: false, candidate: false })).clean).toBeFalse();
  });

  test("rejects secrets and generated dependency/build trees from the manifest", () => {
    for (const path of [".env", ".env.local", "server/.env.production", "apple/.build/output", "node_modules/x", "cli/target/debug/x"]) {
      expect(() => buildReleaseEvidence(input({ sourceFiles: [{ path, sha256: a }] }))).toThrow();
    }
  });

  test("rejects absolute, traversal, duplicate, and malformed digest evidence", () => {
    expect(() => buildReleaseEvidence(input({ sourceFiles: [{ path: "/tmp/source", sha256: a }] }))).toThrow();
    expect(() => buildReleaseEvidence(input({ sourceFiles: [{ path: "../source", sha256: a }] }))).toThrow();
    expect(() => buildReleaseEvidence(input({ sourceFiles: [{ path: "one", sha256: "nope" }] }))).toThrow();
    expect(() => buildReleaseEvidence(input({
      sourceFiles: [
        { path: "one", sha256: a },
        { path: "./one", sha256: b },
      ],
    }))).toThrow("duplicate paths");
  });
});
