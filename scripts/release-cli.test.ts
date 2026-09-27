import { describe, expect, test } from "bun:test";
import {
  buildArgsForTarget,
  isPrereleaseVersion,
  manifestObjectKey,
  releaseTag,
  updateHomebrewCaskContents,
  validateHomebrewCaskContents,
} from "./release-cli";

const existingHomebrewCask = `cask "inline" do
  version "0.7.4"
  name "Inline CLI"

  on_macos do
    depends_on arch: :arm64
    sha256 "${"1".repeat(64)}"
    url "https://example.com/inline-cli-#{version}-aarch64-apple-darwin.tar.gz"
  end

  on_linux do
    arch arm: "aarch64", intel: "x86_64"
    sha256 arm64_linux:  "${"2".repeat(64)}",
           x86_64_linux: "${"3".repeat(64)}"
    url "https://example.com/inline-cli-#{version}-#{arch}-unknown-linux-gnu.tar.gz"
  end

  binary "inline"
end
`;

const nextHomebrewHashes = {
  macosArm: "a".repeat(64),
  linuxArm: "b".repeat(64),
  linuxIntel: "c".repeat(64),
};

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

describe("Homebrew cask release updates", () => {
  test("keeps platform-specific checksum keys while updating the release", () => {
    const updated = updateHomebrewCaskContents(
      existingHomebrewCask,
      "0.7.5",
      nextHomebrewHashes,
    );

    expect(updated).toContain('version "0.7.5"');
    expect(updated).toContain(`sha256 "${nextHomebrewHashes.macosArm}"`);
    expect(updated).toContain(
      `sha256 arm64_linux:  "${nextHomebrewHashes.linuxArm}",\n` +
        `           x86_64_linux: "${nextHomebrewHashes.linuxIntel}"`,
    );
    expect(updated).not.toMatch(/^\s*sha256 arm:/m);
    validateHomebrewCaskContents(updated);
  });

  test("rejects macOS checksum aliases in the Linux block", () => {
    const invalid = existingHomebrewCask
      .replace("sha256 arm64_linux:", "sha256 arm:")
      .replace("x86_64_linux:", "intel:");

    expect(() => validateHomebrewCaskContents(invalid)).toThrow(
      "Linux checksums must use arm64_linux and x86_64_linux keys",
    );
  });

  test("rejects malformed release checksums before writing the cask", () => {
    expect(() =>
      updateHomebrewCaskContents(existingHomebrewCask, "0.7.5", {
        ...nextHomebrewHashes,
        linuxIntel: "not-a-sha256",
      }),
    ).toThrow("expected 64 lowercase hex digits");
  });
});


describe("portable Linux release builds", () => {
  test("pins glibc even when building for the runner architecture", async () => {
    for (const target of ["x86_64-unknown-linux-gnu", "aarch64-unknown-linux-gnu"]) {
      expect(await buildArgsForTarget(target, true, target)).toEqual([
        "zigbuild", "--release", "--locked", "--target", `${target}.2.28`,
      ]);
      await expect(buildArgsForTarget(target, false, target)).rejects.toThrow("require cargo-zigbuild");
    }
  });
  test("keeps static and macOS targets unchanged", async () => {
    expect(await buildArgsForTarget("aarch64-unknown-linux-musl", true, "aarch64-unknown-linux-gnu"))
      .toEqual(["zigbuild", "--release", "--locked", "--target", "aarch64-unknown-linux-musl"]);
    expect(await buildArgsForTarget("aarch64-apple-darwin", false, "aarch64-apple-darwin"))
      .toEqual(["build", "--release", "--locked", "--target", "aarch64-apple-darwin"]);
  });
});
