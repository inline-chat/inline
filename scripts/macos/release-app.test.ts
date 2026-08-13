import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { metadataMismatches, type BuiltAppMetadata } from "./app-release-metadata";
import { decideAppcastFetch, releaseIntegrityGateErrors, safeResumeTask } from "./release-app";

const releaseAppSource = readFileSync(resolve(import.meta.dir, "release-app.ts"), "utf8");
const buildDirectSource = readFileSync(resolve(import.meta.dir, "build-direct.sh"), "utf8");

function metadata(overrides: Partial<BuiltAppMetadata> = {}): BuiltAppMetadata {
  return {
    infoPlist: "/fixture/Inline.app/Contents/Info.plist",
    buildNumber: "4766",
    version: "1.2.3",
    commit: "abc1234",
    feedUrl: "https://updates.invalid/mac/tip/appcast.xml",
    minimumSystemVersion: "15.2",
    ...overrides,
  };
}

describe("release integrity helpers", () => {
  test("resume restarts from the nearest durable prerequisite", () => {
    expect(safeResumeTask("build", "release")).toBe("build");
    expect(safeResumeTask("upload-dmg", "release")).toBe("post-check");
    expect(safeResumeTask("gen-appcast", "release")).toBe("post-check");
    expect(safeResumeTask("validate-appcast", "release")).toBe("post-check");
    expect(safeResumeTask("upload-appcast", "release")).toBe("post-check");
    expect(safeResumeTask("github", "release")).toBe("post-check");
    expect(safeResumeTask("validate-appcast", "rollback")).toBe("fetch-appcast");
    expect(safeResumeTask("upload-appcast", "drop-build")).toBe("fetch-appcast");
  });

  test("appcast history is created only from an explicit confirmed 404", () => {
    expect(decideAppcastFetch(0, 200, false)).toBe("use-existing");
    expect(decideAppcastFetch(0, 404, true)).toBe("create-new");
    expect(() => decideAppcastFetch(0, 200, true)).toThrow("already exists");
    expect(() => decideAppcastFetch(0, 404, false)).toThrow("does not exist");
    expect(() => decideAppcastFetch(28, 0, true)).toThrow("Refusing to replace feed history");
    expect(() => decideAppcastFetch(28, 404, true)).toThrow("curl exit 28");
    expect(() => decideAppcastFetch(22, 500, false)).toThrow("HTTP 500");
  });

  test("channel and DerivedData ownership use exclusive filesystem locks", () => {
    expect(releaseAppSource).toContain('mkdirSync(path, { mode: 0o700 })');
    expect(releaseAppSource).toContain('`channel-${ctx.channel}.lockdir`');
    expect(releaseAppSource).toContain('pathLockName("derived-data", ctx.derivedData)');
    expect(releaseAppSource).toContain("existsSync(path) ? realpathSync(path) : resolve(path)");
    expect(releaseAppSource).toContain("if (handlingInterrupt) throw new Error");
    expect(releaseAppSource).toContain("release locks were intentionally preserved");
  });

  test("publication cannot skip its integrity gates", () => {
    const base = { releaseTag: "tip", skipGithubRelease: false };
    expect(releaseIntegrityGateErrors({ ...base, skip: new Set() })).toEqual([]);
    expect(releaseIntegrityGateErrors({
      ...base,
      skip: new Set(["post-check", "verify-dmg", "gen-appcast", "validate-appcast"]),
    })).toEqual([
      "post-check cannot be skipped while publishing a DMG or appcast",
      "verify-dmg cannot be skipped while publishing to R2",
      "gen-appcast cannot be skipped while uploading appcast.xml",
      "validate-appcast cannot be skipped while uploading appcast.xml",
    ]);
    expect(releaseIntegrityGateErrors({
      releaseTag: "",
      skipGithubRelease: true,
      skip: new Set(["upload-dmg", "upload-appcast", "post-check", "verify-dmg", "gen-appcast", "validate-appcast"]),
    })).toEqual([]);
  });

  test("publication binds frozen source and exact local/remote artifacts", () => {
    expect(releaseAppSource).toContain('EXPECTED_SOURCE_COMMIT: ctx.sourceCommit');
    expect(releaseAppSource).toContain('EXPECTED_SOURCE_BUILD: ctx.sourceBuild');
    expect(releaseAppSource).toContain('APP_PATH: ""');
    expect(releaseAppSource).toContain('remoteSha256 !== ctx.dmgSha256');
    expect(releaseAppSource).toContain('APPCAST_EXPECTED_ETAG: ctx.appcastExpectedEtag');
    expect(releaseAppSource).toContain('RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken');
    expect(releaseAppSource).toContain("Clean-source artifact provenance not found");
    expect(releaseAppSource).toContain("provenance.appExecutableSha256 === executableSha256");
    expect(releaseAppSource).toContain('"Latest Sparkle release", ctx.sourceCommit');
    expect(releaseAppSource).toContain("Public macOS releases require a clean frozen source on every channel");
    expect(buildDirectSource).toContain('verify_frozen_source');
    expect(buildDirectSource).toContain('"sourceClean": source_clean == "1"');
    expect(buildDirectSource).toContain('Artifact provenance: ${ARTIFACT_PROVENANCE_PATH}');
  });

  test("app and DMG identity compares every release-bearing field", () => {
    expect(metadataMismatches(metadata(), metadata())).toEqual([]);
    expect(metadataMismatches(metadata(), metadata({
      buildNumber: "4765",
      version: "1.2.2",
      commit: "def5678",
      feedUrl: "https://updates.invalid/mac/beta/appcast.xml",
      minimumSystemVersion: "15.0",
    }))).toEqual([
      "buildNumber is 4765, expected 4766",
      "version is 1.2.2, expected 1.2.3",
      "commit is def5678, expected abc1234",
      "feedUrl is https://updates.invalid/mac/beta/appcast.xml, expected https://updates.invalid/mac/tip/appcast.xml",
      "minimumSystemVersion is 15.0, expected 15.2",
    ]);
  });
});
