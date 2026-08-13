import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";
import { readBuiltAppMetadata } from "./app-release-metadata";

const fixtureApp = resolve(import.meta.dir, "test-fixtures/app-release-metadata");
const helper = resolve(import.meta.dir, "app-release-metadata.ts");

describe("built app release metadata", () => {
  test("reads the selected app minimum system version", () => {
    expect(readBuiltAppMetadata(fixtureApp)).toEqual({
      infoPlist: resolve(fixtureApp, "Contents/Info.plist"),
      buildNumber: "4766",
      version: "1.2.3",
      commit: "abc1234",
      feedUrl: "https://updates.invalid/mac/tip/appcast.xml",
      minimumSystemVersion: "15.2",
    });
  });

  test("fails closed when the minimum system version is missing or blank", () => {
    const values: Record<string, string> = {
      CFBundleVersion: "4766",
      CFBundleShortVersionString: "1.2.3",
      InlineCommit: "abc1234",
      SUFeedURL: "https://updates.invalid/appcast.xml",
      LSMinimumSystemVersion: "   ",
    };
    expect(() => readBuiltAppMetadata(fixtureApp, (_path, key) => values[key] ?? ""))
      .toThrow("LSMinimumSystemVersion");
  });

  test("CLI emits only the requested floor", () => {
    const result = Bun.spawnSync([
      process.execPath,
      "run",
      helper,
      "--app-path",
      fixtureApp,
      "--field=minimum-system-version",
    ]);
    expect(result.exitCode).toBe(0);
    expect(new TextDecoder().decode(result.stdout)).toBe("15.2\n");
    expect(new TextDecoder().decode(result.stderr)).toBe("");
  });
});
