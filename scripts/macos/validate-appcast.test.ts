import { describe, expect, test } from "bun:test";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const validator = join(import.meta.dir, "validate_appcast.py");

function fixture(minimumSystemVersion: string): string {
  const directory = mkdtempSync(join(tmpdir(), "inline-appcast-validation-"));
  const path = join(directory, "appcast.xml");
  writeFileSync(path, `<?xml version="1.0" encoding="utf-8"?>
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <sparkle:version>4766</sparkle:version>
      <sparkle:shortVersionString>0.2</sparkle:shortVersionString>
      <sparkle:minimumSystemVersion>${minimumSystemVersion}</sparkle:minimumSystemVersion>
      <sparkle:hardwareRequirements>arm64</sparkle:hardwareRequirements>
      <enclosure url="https://example.invalid/Inline.dmg" sparkle:edSignature="signature" length="123" />
    </item>
  </channel>
</rss>
`);
  return path;
}

function validate(path: string, requiredMinimum: string) {
  return Bun.spawnSync([
    "python3",
    validator,
    "--appcast",
    path,
    "--require-build",
    "4766",
    "--require-minimum-system-version",
    requiredMinimum,
  ]);
}

describe("macOS appcast compatibility gate", () => {
  test("accepts the exact deployment floor embedded in the app", () => {
    expect(validate(fixture("15.2"), "15.2").exitCode).toBe(0);
  });

  test("rejects an appcast that offers the build below its deployment floor", () => {
    const result = validate(fixture("15.0"), "15.2");
    expect(result.exitCode).toBe(1);
    expect(result.stderr.toString()).toContain("minimum system version does not match 15.2");
  });
});
