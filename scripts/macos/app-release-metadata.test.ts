import { describe, expect, test } from "bun:test";
import { mkdirSync, mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { readBuiltAppMetadata } from "./app-release-metadata";

function fixture(overrides: Partial<Record<string, string>> = {}): string {
  const root = mkdtempSync(join(tmpdir(), "inline-app-metadata-"));
  const appPath = join(root, "Inline.app");
  const contents = join(appPath, "Contents");
  mkdirSync(join(contents, "MacOS"), { recursive: true });
  const values = {
    CFBundleVersion: "4766",
    CFBundleShortVersionString: "0.2",
    CFBundleExecutable: "Inline",
    InlineCommit: "7f64de27",
    SUFeedURL: "https://example.invalid/mac/tip/appcast.xml",
    LSMinimumSystemVersion: "15.2",
    ...overrides,
  };
  const entries = Object.entries(values)
    .map(([key, value]) => `<key>${key}</key><string>${value}</string>`)
    .join("\n");
  writeFileSync(
    join(contents, "Info.plist"),
    `<?xml version="1.0" encoding="UTF-8"?>\n<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n<plist version="1.0"><dict>${entries}</dict></plist>\n`,
  );
  return appPath;
}

describe("built app release metadata", () => {
  test("reads the app's exact deployment floor and executable path", () => {
    const appPath = fixture();
    const metadata = readBuiltAppMetadata(appPath);

    expect(metadata.minimumSystemVersion).toBe("15.2");
    expect(metadata.executablePath).toBe(join(appPath, "Contents/MacOS/Inline"));
    expect(metadata.buildNumber).toBe("4766");
  });

  test("fails closed when the deployment floor is absent", () => {
    const appPath = fixture({ LSMinimumSystemVersion: "" });
    expect(() => readBuiltAppMetadata(appPath)).toThrow("LSMinimumSystemVersion");
  });

  test("the command emits only the selected non-secret field", () => {
    const appPath = fixture();
    const result = Bun.spawnSync([
      "bun",
      "run",
      join(import.meta.dir, "app-release-metadata.ts"),
      "--app-path",
      appPath,
      "--field",
      "minimum-system-version",
    ]);

    expect(result.exitCode).toBe(0);
    expect(result.stdout.toString()).toBe("15.2\n");
    expect(result.stderr.toString()).toBe("");
  });
});
