import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readBuiltAppMetadata } from "./app-release-metadata";

const script = readFileSync(join(import.meta.dir, "appcast-only.sh"), "utf8");
const archivedWorkflow = readFileSync(
  join(import.meta.dir, "../../.github/disabled-workflows/macos-direct-release.yml"),
  "utf8",
);

function appFixture(root: string): string {
  const appPath = join(root, "Inline.app");
  const contents = join(appPath, "Contents");
  mkdirSync(join(contents, "MacOS"), { recursive: true });
  writeFileSync(join(contents, "Info.plist"), `<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleVersion</key><string>4766</string>
<key>CFBundleShortVersionString</key><string>0.2</string>
<key>CFBundleExecutable</key><string>Inline</string>
<key>InlineCommit</key><string>7f64de27</string>
<key>SUFeedURL</key><string>https://example.invalid/mac/tip/appcast.xml</string>
<key>LSMinimumSystemVersion</key><string>15.2</string>
</dict></plist>
`);
  return appPath;
}

describe("standalone appcast compatibility wiring", () => {
  test("derives the deployment floor from the selected app instead of a constant", () => {
    expect(script).toContain("app-release-metadata.ts");
    expect(script).toContain("--field minimum-system-version");
    expect(script).toContain('INLINE_MIN_MACOS="${MINIMUM_SYSTEM_VERSION}"');
    expect(script).not.toContain('INLINE_MIN_MACOS="15.0"');
  });

  test("validates the generated item against the same app-derived floor", () => {
    expect(script).toContain('--require-minimum-system-version "${MINIMUM_SYSTEM_VERSION}"');
  });

  test("generic generation fails closed without an explicit deployment floor", () => {
    const generation = Bun.spawnSync({
      cmd: ["python3", join(import.meta.dir, "update_appcast.py")],
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        INLINE_BUILD: "4766",
        INLINE_DMG_URL: "https://example.invalid/Inline.dmg",
      },
      stdout: "pipe",
      stderr: "pipe",
    });

    expect(generation.exitCode).not.toBe(0);
    expect(generation.stderr.toString()).toContain("INLINE_MIN_MACOS");
  });

  test("archived workflow derives and validates the floor before reactivation", () => {
    expect(archivedWorkflow).toContain("app-release-metadata.ts");
    expect(archivedWorkflow).toContain('INLINE_MIN_MACOS="${MINIMUM_SYSTEM_VERSION}"');
    expect(archivedWorkflow).toContain(
      '--require-minimum-system-version "${MINIMUM_SYSTEM_VERSION}"',
    );
    expect(archivedWorkflow).not.toContain('INLINE_MIN_MACOS="15.0"');
    expect(archivedWorkflow).not.toMatch(/\\\\\n/);
  });

  test("app metadata flows through generation and the exact compatibility gate", () => {
    const root = mkdtempSync(join(tmpdir(), "inline-appcast-only-"));
    const metadata = readBuiltAppMetadata(appFixture(root));
    const signUpdatePath = join(root, "sign_update.txt");
    const outputPath = join(root, "appcast.xml");
    writeFileSync(signUpdatePath, 'sparkle:edSignature="fixture-signature" length="123"\n');

    const generation = Bun.spawnSync({
      cmd: ["python3", join(import.meta.dir, "update_appcast.py")],
      env: {
        PATH: process.env.PATH ?? "/usr/bin:/bin",
        INLINE_BUILD: metadata.buildNumber,
        INLINE_VERSION: metadata.version,
        INLINE_CHANNEL: "tip",
        INLINE_DMG_URL: "https://example.invalid/Inline.dmg",
        INLINE_MIN_MACOS: metadata.minimumSystemVersion,
        INLINE_HARDWARE_REQUIREMENTS: "arm64",
        INLINE_COMMIT: metadata.commit,
        SIGN_UPDATE_PATH: signUpdatePath,
        APPCAST_PATH: join(root, "missing-existing-appcast.xml"),
        APPCAST_OUTPUT: outputPath,
      },
      stdout: "pipe",
      stderr: "pipe",
    });
    expect(generation.exitCode).toBe(0);

    const validation = Bun.spawnSync([
      "python3",
      join(import.meta.dir, "validate_appcast.py"),
      "--appcast",
      outputPath,
      "--require-build",
      metadata.buildNumber,
      "--require-url",
      "https://example.invalid/Inline.dmg",
      "--require-hardware",
      "arm64",
      "--require-minimum-system-version",
      metadata.minimumSystemVersion,
    ]);
    expect(validation.exitCode).toBe(0);
  });
});
