import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { metadataMismatches, type BuiltAppMetadata } from "./app-release-metadata";
import {
  appcastXmlForBuildAllocation,
  decideAppcastFetch,
  nextTipArtifactBuild,
  releaseIntegrityGateErrors,
  safeResumeTask,
} from "./release-app";

const releaseAppSource = readFileSync(resolve(import.meta.dir, "release-app.ts"), "utf8");
const buildDirectSource = readFileSync(resolve(import.meta.dir, "build-direct.sh"), "utf8");
const sourceSnapshotSource = readFileSync(resolve(import.meta.dir, "macos-source-snapshot.ts"), "utf8");
const updateAppcastSource = readFileSync(resolve(import.meta.dir, "update_appcast.py"), "utf8");

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

  test("first tip publication does not read a missing appcast", () => {
    let readCount = 0;
    const readExisting = () => {
      readCount += 1;
      return "<rss><channel><item><sparkle:version>5225</sparkle:version></item></channel></rss>";
    };

    expect(appcastXmlForBuildAllocation("create-new", readExisting)).toBeUndefined();
    expect(readCount).toBe(0);
    expect(appcastXmlForBuildAllocation("use-existing", readExisting)).toContain("5225");
    expect(readCount).toBe(1);
  });

  test("tip builds stay integer and advance past feed collisions", () => {
    const appcast = (versions: string[]) => `<rss><channel>${versions.map((version) => `<item><sparkle:version>${version}</sparkle:version></item>`).join("")}</channel></rss>`;
    expect(nextTipArtifactBuild("5226", undefined, false)).toBe("5226");
    expect(nextTipArtifactBuild("5226", undefined, true)).toBe("5227");
    expect(nextTipArtifactBuild("5226", appcast(["5182"]), false)).toBe("5226");
    expect(nextTipArtifactBuild("5226", appcast(["5182"]), true)).toBe("5227");
    expect(nextTipArtifactBuild("5227", appcast(["5227"]), false)).toBe("5228");
    expect(nextTipArtifactBuild("5226", appcast(["5229"]), true)).toBe("5230");
    expect(() => nextTipArtifactBuild("5226", appcast([]), false)).toThrow("has no versions");
    expect(() => nextTipArtifactBuild("5226", appcast(["5226.1"]), true)).toThrow("unsupported");
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
    expect(releaseAppSource).toContain('EXPECTED_SOURCE_COMMIT: ctx.experimentalTip ? "" : ctx.sourceCommit');
    expect(releaseAppSource).toContain('EXPECTED_SOURCE_BUILD: ctx.experimentalTip ? "" : ctx.sourceBuild');
    expect(releaseAppSource).toContain('APP_PATH: ""');
    expect(releaseAppSource).toContain('remoteSha256 !== ctx.dmgSha256');
    expect(releaseAppSource).toContain('APPCAST_EXPECTED_ETAG: ctx.appcastExpectedEtag');
    expect(releaseAppSource).toContain('RELEASE_CHANNEL_LOCK_TOKEN: ctx.channelLockToken');
    expect(releaseAppSource).toContain("Artifact provenance not found");
    expect(releaseAppSource).toContain("provenance.appExecutableSha256 === executableSha256");
    expect(releaseAppSource).toContain('"Latest Sparkle release", ctx.sourceCommit');
    expect(releaseAppSource).toContain("Public macOS releases require a clean frozen source on every channel");
    expect(releaseAppSource).toContain('ctx.experimentalTip ? "1" : "0"');
    expect(releaseAppSource).toContain('provenance.sourceState === "experimental-tip"');
    expect(releaseAppSource).toContain('experimental-${ctx.sourceSnapshot.slice(0, 12)}');
    expect(releaseAppSource).toContain("stageMacosSourceSnapshot(ctx.rootDir, ctx.sourceRoot, ctx.sourceManifestPath)");
    expect(releaseAppSource).toContain('resolve(ctx.sourceRoot || ctx.rootDir, "scripts/macos/build-direct.sh")');
    expect(buildDirectSource).toContain('verify_frozen_source');
    expect(buildDirectSource).toContain('"sourceClean": source_clean == "1"');
    expect(buildDirectSource).toContain('"sourceSnapshotSha256": source_snapshot');
    expect(buildDirectSource).toContain('bun run "${ROOT_DIR}/scripts/macos/macos-source-snapshot.ts"');
    expect(buildDirectSource).toContain('--manifest "${SOURCE_SNAPSHOT_MANIFEST}"');
    expect(buildDirectSource).toContain('RELEASE_CONFIG_ROOT=${RELEASE_CONFIG_ROOT:-"${ROOT_DIR}"}');
    expect(sourceSnapshotSource).toContain('["apple", "scripts/apple", "scripts/macos", "bun.lock"]');
    expect(sourceSnapshotSource).toContain('component === ".env" || component.startsWith(".env.")');
    expect(sourceSnapshotSource).toContain("assertSafeSymlink(rootDir, relativePath, absolutePath)");
    expect(sourceSnapshotSource).toContain("copiedPaths.length !== finalPaths.length");
    expect(sourceSnapshotSource).toContain('sourceSha256 !== stagedSha256 || sourceSha256 !== sourceSha256AfterVerification');
    expect(buildDirectSource).toContain('Artifact provenance: ${ARTIFACT_PROVENANCE_PATH}');
  });

  test("experimental mode is tip-only and never enables GitHub", () => {
    expect(releaseAppSource).toContain('die("--experimental-tip can publish only to --channel tip.")');
    expect(releaseAppSource).toContain('skipGithubRelease: parsed0.experimentalTip ||');
    expect(releaseAppSource).toContain('parsed0.rollback || parsed0.dropBuild || parsed0.experimentalTip');
    expect(releaseAppSource).toContain('? "experimental-tip"');
    expect(updateAppcastSource).toContain('description.text = f"<p>Experimental tip build {build}.</p>"');
    expect(updateAppcastSource).toContain("elif commit:");
  });

  test("release dSYM upload is default and never blocks publication", () => {
    expect(releaseAppSource).not.toContain('if (!uploadSentryDsyms) {\n      skip.add("upload-sentry-dsyms");');
    const taskStart = releaseAppSource.indexOf('id: "upload-sentry-dsyms"');
    const taskEnd = releaseAppSource.indexOf('id: "post-check"', taskStart);
    const taskSource = releaseAppSource.slice(taskStart, taskEnd);
    expect(taskSource).toContain("softFail: true");
    expect(taskSource).toContain("authenticated modern `sentry` CLI");
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
