import { describe, expect, test } from "bun:test";
import { mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import {
  buildReleaseEvidence,
  releaseEvidenceIntegrationMode,
  v2HistoryPath,
  writeReleaseEvidenceHistory,
} from "./release-evidence-v2";
import type { ReleaseEvidenceInput } from "./release-evidence-v2";

const digest = "a".repeat(64);
const uuid = "ABCDEF01-2345-6789-ABCD-EF0123456789 (arm64)";

function evidence(resumedFromTask?: string) {
  const input: ReleaseEvidenceInput = {
    channel: "tip",
    version: "0.2",
    buildNumber: "4766",
    commit: "7f64de2700000000000000000000000000000000",
    feedURL: "https://example.invalid/mac/tip/appcast.xml",
    minimumSystemVersion: "15.2",
    clean: true,
    sourceFiles: [{ path: "apple/InlineMac/App.swift", sha256: digest }],
    sourceEnumeration: {
      scope: "tracked-and-untracked-nonignored",
      includedPathCount: 1,
      excludedPathCount: 0,
      exclusionRules: ["environment paths are filtered before reads"],
    },
    executableSha256: digest,
    dmgSha256: digest,
    executableUUIDs: [uuid],
    dSYMUUIDs: [uuid],
    toolchain: { xcode: "Xcode 26.4", swift: "Swift 6.3", macOS: "26.4" },
    validation: [{ name: "post-check", status: "passed" }],
    createdAt: "2026-08-09T00:00:00.000Z",
    resumedFromTask,
  };
  return buildReleaseEvidence(input);
}

describe("additive release history V2 integration", () => {
  test("keeps the V1 record byte-for-byte and writes a separate V2 sidecar", () => {
    const directory = mkdtempSync(join(tmpdir(), "inline-release-history-"));
    const v1Path = join(directory, "20260809-tip-release-4766.json");
    const v1 = '{"schemaVersion":1,"buildNumber":"4766"}\n';
    writeFileSync(v1Path, v1);

    const sidecarPath = v2HistoryPath(v1Path);
    writeReleaseEvidenceHistory(sidecarPath, evidence());

    expect(readFileSync(v1Path, "utf8")).toBe(v1);
    expect(JSON.parse(readFileSync(sidecarPath, "utf8")).schemaVersion).toBe(2);
  });

  test("dry run is describe-only and therefore has no history-write mode", () => {
    expect(releaseEvidenceIntegrationMode(false, false)).toBe("disabled");
    expect(releaseEvidenceIntegrationMode(true, true)).toBe("describe-only");
    expect(releaseEvidenceIntegrationMode(true, false)).toBe("capture-and-write");
  });

  test("resume provenance is explicit in the canonical sidecar", () => {
    expect(evidence("upload-dmg").resumedFromTask).toBe("upload-dmg");
    expect(evidence().resumedFromTask).toBeUndefined();
  });
});
