import { describe, expect, test } from "bun:test";
import { readFileSync } from "node:fs";
import { resolve } from "node:path";

const uploaderPath = resolve(import.meta.dir, "upload-dsyms.sh");
const uploaderSource = readFileSync(uploaderPath, "utf8");
const cloudHookSource = readFileSync(resolve(import.meta.dir, "ci_post_xcodebuild.sh"), "utf8");
const xcodeProjectSource = readFileSync(resolve(import.meta.dir, "../../apple/Inline.xcodeproj/project.pbxproj"), "utf8");

describe("Apple dSYM upload hook", () => {
  test("keeps managed auth out of command arguments and verifies UUIDs", () => {
    expect(uploaderSource).toContain("sentry auth token");
    expect(uploaderSource).toContain("curl --header @-");
    expect(uploaderSource).not.toContain("--auth-token");
    expect(uploaderSource).not.toContain('Authorization: Bearer $auth_token"');
    expect(uploaderSource).toContain("verify_uuid");
    expect(uploaderSource).toContain("Upload archives retained at");
  });

  test("build hooks remain best-effort", () => {
    expect(cloudHookSource).toContain('if ! "$UPLOAD_SCRIPT"');
    expect(cloudHookSource).toContain("continuing Xcode Cloud build");
    expect(xcodeProjectSource).toContain('if ! \\"$SRCROOT/../scripts/apple/upload-dsyms.sh\\"');
    expect(xcodeProjectSource).toContain("warning: failed to upload dSYMs to Sentry");

    const syntax = Bun.spawnSync({ cmd: ["bash", "-n", uploaderPath] });
    expect(syntax.exitCode).toBe(0);
  });
});
