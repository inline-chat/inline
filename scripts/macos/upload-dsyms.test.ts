import { describe, expect, test } from "bun:test";
import { selectSentryAuthToken } from "./upload-dsyms";

describe("Sentry dSYM authentication", () => {
  test("prefers an environment token without reading managed auth", () => {
    let managedReads = 0;
    const token = selectSentryAuthToken(" environment-token ", () => {
      managedReads += 1;
      return "managed-token";
    });

    expect(token).toBe("environment-token");
    expect(managedReads).toBe(0);
  });

  test("falls back to the managed CLI token without printing it", () => {
    expect(selectSentryAuthToken(undefined, () => " managed-token\n")).toBe("managed-token");
    expect(selectSentryAuthToken("  ", () => "  ")).toBeUndefined();
  });
});
