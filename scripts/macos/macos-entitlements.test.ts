import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const timeSensitiveEntitlement = /<key>com\.apple\.developer\.usernotifications\.time-sensitive<\/key>\s*<true\/>/;

describe("macOS notification entitlements", () => {
  for (const name of ["InlineMac.entitlements", "InlineMacDebug.entitlements", "InlineMacDirect.entitlements"]) {
    test(`${name} enables time-sensitive notifications`, () => {
      const path = resolve(import.meta.dir, "../../apple/InlineMac", name);
      expect(readFileSync(path, "utf8")).toMatch(timeSensitiveEntitlement);
    });
  }
});
