import { describe, expect, test } from "bun:test";
import {
  isPrereleaseVersion,
  manifestObjectKey,
  releaseTag,
} from "./release-cli";

describe("CLI release channels", () => {
  test("keeps stable releases on the stable manifest", () => {
    expect(isPrereleaseVersion("0.7.0")).toBe(false);
    expect(manifestObjectKey("cli", "0.7.0")).toBe("cli/manifest.json");
    expect(releaseTag("0.7.0")).toBe("cli-v0.7.0");
  });

  test("isolates prereleases under their version", () => {
    expect(isPrereleaseVersion("0.7.0-alpha.1")).toBe(true);
    expect(manifestObjectKey("cli", "0.7.0-alpha.1")).toBe(
      "cli/v0.7.0-alpha.1/manifest.json",
    );
    expect(releaseTag("0.7.0-alpha.1")).toBe("cli-v0.7.0-alpha.1");
  });
});
