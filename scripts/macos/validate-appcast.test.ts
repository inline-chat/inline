import { describe, expect, test } from "bun:test";
import { resolve } from "node:path";

const validator = resolve(import.meta.dir, "validate_appcast.py");

type Item = {
  build: string;
  url: string;
  shortVersion?: string;
  length?: string;
  minimum?: string;
  hardware?: string;
};

function appcast(items: Item[]): string {
  return `<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle">
  <channel>
    ${items.map((item) => `<item>
      <sparkle:version>${item.build}</sparkle:version>
      <sparkle:shortVersionString>${item.shortVersion ?? "1.2.3"}</sparkle:shortVersionString>
      ${item.minimum === undefined ? "" : `<sparkle:minimumSystemVersion>${item.minimum}</sparkle:minimumSystemVersion>`}
      ${item.hardware === undefined ? "" : `<sparkle:hardwareRequirements>${item.hardware}</sparkle:hardwareRequirements>`}
      <enclosure url="${item.url}" sparkle:edSignature="fixture" length="${item.length ?? "123"}" />
    </item>`).join("\n")}
  </channel>
</rss>`;
}

function validate(xml: string, extraArgs: string[]) {
  return Bun.spawnSync({
    cmd: ["python3", validator, "--appcast", "/dev/stdin", ...extraArgs],
    stdin: new TextEncoder().encode(xml),
  });
}

const exactArgs = [
  "--require-build", "4766",
  "--require-short-version", "1.2.3",
  "--require-url", "https://updates.invalid/4766/Inline.dmg",
  "--require-length", "123",
  "--require-hardware", "arm64",
  "--require-minimum-system-version", "15.2",
];

describe("appcast selected-build validation", () => {
  test("accepts an exact artifact-bound item", () => {
    const result = validate(appcast([{
      build: "4766",
      url: "https://updates.invalid/4766/Inline.dmg",
      minimum: "15.2",
      hardware: "arm64",
    }]), exactArgs);
    expect(result.exitCode).toBe(0);
  });

  test("rejects a stale or missing minimum system version", () => {
    for (const minimum of ["15.0", undefined]) {
      const result = validate(appcast([{
        build: "4766",
        url: "https://updates.invalid/4766/Inline.dmg",
        minimum,
        hardware: "arm64",
      }]), exactArgs);
      expect(result.exitCode).toBe(1);
      expect(new TextDecoder().decode(result.stderr)).toContain("minimum system version 15.2");
    }
  });

  test("rejects duplicate selected builds", () => {
    const item = {
      build: "4766",
      url: "https://updates.invalid/4766/Inline.dmg",
      minimum: "15.2",
      hardware: "arm64",
    };
    const result = validate(appcast([item, item]), exactArgs);
    expect(result.exitCode).toBe(1);
    expect(new TextDecoder().decode(result.stderr)).toContain("duplicate entries");
  });

  test("a decoy item cannot satisfy the selected build URL", () => {
    const result = validate(appcast([
      { build: "4766", url: "https://updates.invalid/wrong.dmg", minimum: "15.2", hardware: "arm64" },
      { build: "4765", url: "https://updates.invalid/4766/Inline.dmg", minimum: "15.0", hardware: "arm64" },
    ]), exactArgs);
    expect(result.exitCode).toBe(1);
    expect(new TextDecoder().decode(result.stderr)).toContain("for build 4766");
  });

  test("rejects selected-build short version and length mismatches", () => {
    for (const overrides of [{ shortVersion: "1.2.2" }, { length: "122" }]) {
      const result = validate(appcast([{
        build: "4766",
        url: "https://updates.invalid/4766/Inline.dmg",
        minimum: "15.2",
        hardware: "arm64",
        ...overrides,
      }]), exactArgs);
      expect(result.exitCode).toBe(1);
    }
  });

  test("rejects parseable XML that is not exactly one RSS channel", () => {
    const wrapped = appcast([{ build: "4766", url: "https://updates.invalid/4766/Inline.dmg" }])
      .replace("<rss", "<wrapper")
      .replace("</rss>", "</wrapper>");
    const result = validate(wrapped, ["--require-build", "4766"]);
    expect(result.exitCode).toBe(1);
    expect(new TextDecoder().decode(result.stderr)).toContain("exactly one <rss><channel>");
  });
});
