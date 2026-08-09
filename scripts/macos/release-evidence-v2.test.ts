import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import {
  buildReleaseEvidence,
  canonicalReleaseEvidenceJSON,
  collectSourceFileEvidence,
  collectToolchainEvidence,
  parseDwarfUUIDs,
  requireMatchingDwarfUUIDs,
  sha256File,
  sourceTreeSha256,
  v2HistoryPath,
} from "./release-evidence-v2";
import type { ReleaseEvidenceInput } from "./release-evidence-v2";

const a = "a".repeat(64);
const b = "b".repeat(64);

function input(overrides: Partial<ReleaseEvidenceInput> = {}): ReleaseEvidenceInput {
  return {
    channel: "beta",
    version: "1.2.3",
    buildNumber: "456",
    commit: "1234567890abcdef",
    feedURL: "https://example.invalid/mac/beta/appcast.xml",
    minimumSystemVersion: "15.2",
    clean: true,
    sourceFiles: [
      { path: "server/index.ts", sha256: b },
      { path: "apple/InlineMac/InlineApp.swift", sha256: a },
    ],
    sourceEnumeration: {
      scope: "tracked-and-untracked-nonignored",
      includedPathCount: 2,
      excludedPathCount: 0,
      exclusionRules: ["exclude environment files"],
    },
    executableSha256: a,
    dmgSha256: b,
    executableUUIDs: ["AAAA (arm64)"],
    dSYMUUIDs: ["AAAA (arm64)", "AAAA (arm64)"],
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
    expect(first.dSYMUUIDs).toEqual(["AAAA (arm64)"]);
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

  test("artifact hashing streams a file without changing the digest", () => {
    const fixture = resolve(import.meta.dir, "../fixtures/release-evidence/abc.txt");
    expect(sha256File(fixture)).toBe("edeaaff3f1774ad2888673770c6d64097e391bc362d7d6fb34982ddf0efd18cb");
  });

  test("rejects dirty release candidates but permits explicitly non-candidate investigations", () => {
    expect(() => buildReleaseEvidence(input({ clean: false }))).toThrow("clean recorded source tree");
    expect(buildReleaseEvidence(input({ clean: false, candidate: false })).clean).toBeFalse();
  });

  test("parses, normalizes, and requires exact executable/dSYM UUID equality", () => {
    const output = [
      "UUID: abcdef01-2345-6789-abcd-ef0123456789 (arm64) /tmp/Inline",
      "UUID: ABCDEF01-2345-6789-ABCD-EF0123456789 (arm64) /tmp/Inline",
    ].join("\n");
    const uuids = parseDwarfUUIDs(output);
    expect(uuids).toEqual(["ABCDEF01-2345-6789-ABCD-EF0123456789 (arm64)"]);
    expect(() => requireMatchingDwarfUUIDs(uuids, uuids)).not.toThrow();
    expect(() => requireMatchingDwarfUUIDs(uuids, ["11111111-1111-1111-1111-111111111111 (arm64)"]))
      .toThrow("UUID mismatch");
  });

  test("filters secret and generated paths before any content digest is requested", () => {
    const digested: string[] = [];
    const result = collectSourceFileEvidence("/unused", {
      listPaths: () => [
        "apple/Inline.swift",
        ".env",
        ".envrc",
        "server/.env.production",
        "apple/.build/result",
        "node_modules/package/index.js",
        "cli/target/release/inline",
        "signing/AuthKey.p8",
        "config/credentials/service.json",
      ],
      digestPath: (_root, path) => {
        digested.push(path);
        return a;
      },
    });

    expect(digested).toEqual(["apple/Inline.swift"]);
    expect(result.files).toEqual([{ path: "apple/Inline.swift", sha256: a }]);
    expect(result.enumeration.includedPathCount).toBe(1);
    expect(result.enumeration.excludedPathCount).toBe(8);
  });

  test("collects concise toolchain records through an injectable command boundary", () => {
    const invocations: string[] = [];
    const toolchain = collectToolchainEvidence("/repo", (command) => {
      invocations.push(command.join(" "));
      if (command[0] === "xcodebuild") return "Xcode 26.4\nBuild version 1A2B";
      if (command[0] === "swift") return "Swift version 6.3";
      return "26.4";
    });

    expect(toolchain.xcode).toBe("Xcode 26.4; Build version 1A2B");
    expect(toolchain.swift).toBe("Swift version 6.3");
    expect(toolchain.macOS).toBe("26.4");
    expect(invocations).toEqual(["xcodebuild -version", "swift --version", "sw_vers -productVersion"]);
  });

  test("derives an additive sidecar path without replacing V1 history", () => {
    expect(v2HistoryPath("/history/20260809-tip-release-4766.json")).toBe(
      "/history/20260809-tip-release-4766.evidence-v2.json",
    );
    expect(() => v2HistoryPath("/history/not-json")).toThrow("must end in .json");
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
