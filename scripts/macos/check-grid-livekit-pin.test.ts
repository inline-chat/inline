import { describe, expect, test } from "bun:test";
import {
  liveKitRemoteURL,
  parseInlineRTCSources,
  parseManifestRevision,
  parseResolvedPin,
  requiredGridAudioSources,
  retiredGridAudioSources,
  validateGridAudioCutover,
  validateGridLiveKitPin,
  type GridLiveKitPinEvidence,
} from "./check-grid-livekit-pin";

const revision = "1234567890abcdef1234567890abcdef12345678";

function evidence(overrides: Partial<GridLiveKitPinEvidence> = {}): GridLiveKitPinEvidence {
  return {
    manifestRevision: revision,
    resolvedRevisions: [
      { path: "one/Package.resolved", revision, location: liveKitRemoteURL },
      { path: "two/Package.resolved", revision, location: liveKitRemoteURL },
    ],
    mirrorPresent: false,
    remoteRevisionReachable: true,
    compiledInlineRTCSources: [...requiredGridAudioSources],
    ...overrides,
  };
}

describe("Grid LiveKit release pin", () => {
  test("parses the manifest revision adjacent to the canonical remote", () => {
    expect(
      parseManifestRevision(`
        .package(
          url: "${liveKitRemoteURL}",
          revision: "${revision}"
        )
      `),
    ).toBe(revision);
  });

  test("parses the canonical resolved pin", () => {
    expect(
      parseResolvedPin(JSON.stringify({
        pins: [{
          identity: "client-sdk-swift",
          location: liveKitRemoteURL,
          state: { revision },
        }],
      })),
    ).toEqual({ revision, location: liveKitRemoteURL });
  });

  test("parses SwiftPM's resolved InlineRTC source list", () => {
    expect(
      parseInlineRTCSources(JSON.stringify({
        targets: [
          { name: "InlineKit", sources: ["InlineKit.swift"] },
          { name: "InlineRTC", sources: [...requiredGridAudioSources] },
        ],
      })),
    ).toEqual([...requiredGridAudioSources]);
  });

  test("accepts only the directional AUHAL runtime", () => {
    expect(validateGridAudioCutover(requiredGridAudioSources)).toEqual([]);
  });

  test("rejects a missing AUHAL bridge and any recompiled retired backend", () => {
    const sources: string[] = requiredGridAudioSources.filter(
      (source) => source !== "Audio/MacGridWebRTCAudioBridge.swift",
    );
    sources.push(retiredGridAudioSources[0]);
    const failures = validateGridAudioCutover(sources);
    expect(failures).toHaveLength(2);
    expect(failures.join("\n")).toContain("required Grid AUHAL source");
    expect(failures.join("\n")).toContain("retired Grid audio source");
  });

  test("rejects every retired Grid audio source independently", () => {
    for (const source of retiredGridAudioSources) {
      expect(validateGridAudioCutover([
        ...requiredGridAudioSources,
        source,
      ])).toEqual([
        `SwiftPM still compiles the retired Grid audio source ${source}.`,
      ]);
    }
  });

  test("accepts one remotely reachable revision across every lockfile", () => {
    expect(validateGridLiveKitPin(evidence())).toEqual([]);
  });

  test("rejects local mirrors, editable lockfiles, drift, and unreachable revisions", () => {
    const failures = validateGridLiveKitPin(evidence({
      mirrorPresent: true,
      remoteRevisionReachable: false,
      resolvedRevisions: [
        { path: "missing/Package.resolved", revision: null, location: null },
        {
          path: "drifted/Package.resolved",
          revision: "abcdef1234567890abcdef1234567890abcdef12",
          location: "file:///tmp/livekit",
        },
      ],
    }));

    expect(failures).toHaveLength(5);
    expect(failures.join("\n")).toContain("active LiveKit mirror");
    expect(failures.join("\n")).toContain("may still be editable");
    expect(failures.join("\n")).toContain("expected");
    expect(failures.join("\n")).toContain("not remotely reachable");
  });
});
