import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const appcastOnlyPath = resolve(import.meta.dir, "appcast-only.sh");
const generator = resolve(import.meta.dir, "update_appcast.py");
const validator = resolve(import.meta.dir, "validate_appcast.py");
const rollback = resolve(import.meta.dir, "rollback_appcast.py");
const prune = resolve(import.meta.dir, "prune_appcast.py");
const signUpdate = resolve(import.meta.dir, "test-fixtures/sign-update.txt");
const existingAppcast = resolve(import.meta.dir, "test-fixtures/appcast-existing-build.xml");

const executablePath = process.env.PATH ?? "/usr/bin:/bin";

describe("standalone appcast floor", () => {
  test("derives one floor from the selected app for generation and validation", () => {
    const source = readFileSync(appcastOnlyPath, "utf8");
    expect(source).not.toContain('INLINE_MIN_MACOS="15.0"');
    expect(source).toContain("app-release-metadata.ts");
    expect(source).toContain('INLINE_MIN_MACOS="${MINIMUM_SYSTEM_VERSION}"');
    expect(source).toContain('--require-minimum-system-version "${MINIMUM_SYSTEM_VERSION}"');
    expect(source).toContain('--verify-dmg "${DMG_PATH}"');
    expect(source).toContain('Artifact provenance not found at ${PROVENANCE_PATH}');
    expect(source).toContain('cmp -s "${DMG_PATH}" "${REMOTE_DMG_PATH}"');
    expect(source).toContain('acquire_lock "${LOCK_ROOT}/channel-${CHANNEL}.lockdir"');
    expect(source).toContain('acquire_lock "${LOCK_ROOT}/derived-data-${DERIVED_LOCK_HASH}.lockdir"');
    expect(source).toContain('bash "${ROOT_DIR}/scripts/macos/post-check.sh"');
    expect(source).toContain('APPCAST_EXPECTED_ETAG="${APPCAST_EXPECTED_ETAG}"');
    expect(source).toContain('RELEASE_CHANNEL_LOCK_TOKEN="${LOCK_TOKEN}"');
    expect(source).toContain("--create-new-appcast");
    expect(source).toContain('status --porcelain');
  });

  test("generator fails closed without an explicit floor", () => {
    const result = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.3",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/Inline.dmg",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: "/path/that/does/not/exist.xml",
        APPCAST_OUTPUT: "/dev/stdout",
        ALLOW_NEW_APPCAST: "1",
      },
    });
    expect(result.exitCode).toBe(1);
    expect(new TextDecoder().decode(result.stderr)).toContain("INLINE_MIN_MACOS");
  });

  test("a derived 15.2 floor flows through generation and exact validation", () => {
    const generated = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.3",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/Inline.dmg",
        INLINE_MIN_MACOS: "15.2",
        INLINE_HARDWARE_REQUIREMENTS: "arm64",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: "/path/that/does/not/exist.xml",
        APPCAST_OUTPUT: "/dev/stdout",
        ALLOW_NEW_APPCAST: "1",
      },
    });
    expect(generated.exitCode).toBe(0);

    const validated = Bun.spawnSync({
      cmd: [
        "python3", validator,
        "--appcast", "/dev/stdin",
        "--require-build", "4766",
        "--require-url", "https://updates.invalid/4766/Inline.dmg",
        "--require-hardware", "arm64",
        "--require-minimum-system-version", "15.2",
      ],
      stdin: generated.stdout,
    });
    expect(validated.exitCode).toBe(0);
  });

  test("same-build regeneration replaces the existing item", () => {
    const generated = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.4",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/replacement.dmg",
        INLINE_MIN_MACOS: "15.2",
        INLINE_HARDWARE_REQUIREMENTS: "arm64",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: existingAppcast,
        APPCAST_OUTPUT: "/dev/stdout",
      },
    });

    expect(generated.exitCode).toBe(0);
    const xml = new TextDecoder().decode(generated.stdout);
    expect(xml.match(/<sparkle:version>4766<\/sparkle:version>/g)).toHaveLength(1);
    expect(xml).toContain("https://updates.invalid/4766/replacement.dmg");
    expect(xml).not.toContain("https://updates.invalid/4766/original.dmg");
  });

  test("generator requires explicit first-publication authorization", () => {
    const generated = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.3",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/Inline.dmg",
        INLINE_MIN_MACOS: "15.2",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: "/path/that/does/not/exist.xml",
        APPCAST_OUTPUT: "/dev/stdout",
      },
    });
    expect(generated.exitCode).toBe(1);
    expect(new TextDecoder().decode(generated.stderr)).toContain("without ALLOW_NEW_APPCAST=1");
  });

  test("generator refuses to replace malformed feed history", () => {
    const generated = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.3",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/Inline.dmg",
        INLINE_MIN_MACOS: "15.2",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: "/dev/stdin",
        APPCAST_OUTPUT: "/dev/stdout",
      },
      stdin: new TextEncoder().encode("<rss><broken>"),
    });
    expect(generated.exitCode).toBe(1);
    expect(new TextDecoder().decode(generated.stderr)).toContain("Refusing to replace malformed existing appcast");
  });

  test("generator refuses to reinterpret parseable non-feed XML as a first publication", () => {
    const generated = Bun.spawnSync({
      cmd: ["python3", generator],
      env: {
        PATH: executablePath,
        INLINE_BUILD: "4766",
        INLINE_VERSION: "1.2.3",
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://updates.invalid/4766/Inline.dmg",
        INLINE_MIN_MACOS: "15.2",
        SIGN_UPDATE_PATH: signUpdate,
        APPCAST_PATH: "/dev/stdin",
        APPCAST_OUTPUT: "/dev/stdout",
        ALLOW_NEW_APPCAST: "1",
      },
      stdin: new TextEncoder().encode("<rss><not-channel /></rss>"),
    });
    expect(generated.exitCode).toBe(1);
    expect(new TextDecoder().decode(generated.stderr)).toContain("invalid existing appcast structure");
  });

  test("rollback and prune reject parseable non-RSS feed shapes", () => {
    const invalidFeed = new TextEncoder().encode(`
      <wrapper xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
        <channel><item><sparkle:version>1</sparkle:version><enclosure url="https://invalid/1" /></item></channel>
      </wrapper>
    `);
    for (const command of [
      ["python3", rollback, "--appcast", "/dev/stdin", "--output", "/dev/null", "--metadata-output", "/dev/null"],
      ["python3", prune, "--appcast", "/dev/stdin", "--output", "/dev/null", "--metadata-output", "/dev/null", "--drop-build", "1"],
    ]) {
      const result = Bun.spawnSync({ cmd: command, stdin: invalidFeed });
      expect(result.exitCode).toBe(1);
      expect(new TextDecoder().decode(result.stderr)).toContain("exactly one <rss><channel>");
    }
  });
});
