import { describe, expect, test } from "bun:test"
import {
  PACKAGE_CONFIGS,
  expectedDistTag,
  isRegistryNotFound,
  parseReleaseArgs,
  parseWorkflowRunUrl,
  resolveDistTag,
  validateManifest,
} from "./release-npm"

describe("release npm arguments", () => {
  test("parses a package with safety and dispatch options", () => {
    expect(
      parseReleaseArgs([
        "hermes-agent",
        "--version",
        "0.0.6",
        "--tag",
        "latest",
        "--no-watch",
        "--yes",
      ]),
    ).toEqual({
      packageKey: "hermes-agent",
      requestedVersion: "0.0.6",
      requestedTag: "latest",
      dryRun: false,
      watch: false,
      yes: true,
    })
  })

  test("rejects unsupported packages and missing flag values", () => {
    expect(() => parseReleaseArgs(["unknown"])).toThrow("Unsupported package key")
    expect(() => parseReleaseArgs(["openclaw", "--tag"])).toThrow("--tag requires a value")
  })
})

describe("release npm dist-tags", () => {
  test("derives stable and prerelease tags", () => {
    expect(expectedDistTag("1.2.3")).toBe("latest")
    expect(expectedDistTag("1.2.3-alpha.4")).toBe("alpha")
    expect(expectedDistTag("1.2.3-beta.1")).toBe("beta")
    expect(expectedDistTag("1.2.3-next.2")).toBe("next")
  })

  test("rejects malformed versions, unsupported channels, and tag mismatches", () => {
    expect(() => expectedDistTag("1.2")).toThrow("Invalid canonical release version")
    expect(() => expectedDistTag("1.2.3-rc.1")).toThrow("Unsupported npm prerelease channel: rc")
    expect(() => resolveDistTag("1.2.3-alpha.1", "latest")).toThrow(
      "must use the alpha dist-tag",
    )
  })
})

describe("release npm manifest", () => {
  const config = PACKAGE_CONFIGS["hermes-agent"]
  const manifest = {
    name: config.name,
    version: "0.0.6",
    repository: {
      type: "git",
      url: "git+https://github.com/inline-chat/inline.git",
      directory: config.directory,
    },
    publishConfig: { access: "public" },
  }

  test("takes the requested tag version without changing the trusted source manifest", () => {
    expect(validateManifest(config, manifest, "0.0.7-alpha.1")).toBe("0.0.7-alpha.1")
    expect(manifest.version).toBe("0.0.6")
  })

  test("rejects private, mismatched, and incorrectly sourced packages", () => {
    expect(() => validateManifest(config, { ...manifest, private: true })).toThrow("marked private")
    expect(() =>
      validateManifest(config, {
        ...manifest,
        repository: { ...manifest.repository, directory: "other" },
      }),
    ).toThrow("repository directory")
    expect(() =>
      validateManifest(config, { ...manifest, publishConfig: { access: "restricted" } }),
    ).toThrow("publishConfig.access must be public")
  })
})

test("parses the workflow run URL emitted by gh", () => {
  expect(
    parseWorkflowRunUrl("https://github.com/inline-chat/inline/actions/runs/30258929111\n"),
  ).toEqual({
    id: 30258929111,
    url: "https://github.com/inline-chat/inline/actions/runs/30258929111",
  })
  expect(parseWorkflowRunUrl("workflow queued")).toBeUndefined()
})

test("recognizes an unpublished package as missing registry state", () => {
  expect(isRegistryNotFound("npm error code E404\nNot Found")).toBe(true)
  expect(isRegistryNotFound("No match found for version 1.2.3")).toBe(false)
  expect(isRegistryNotFound("npm error code E401\nUnauthorized")).toBe(false)
})

test("uses allowlisted package release tags", async () => {
  const workflow = await Bun.file(new URL("../.github/workflows/npm-publish.yml", import.meta.url)).text()
  for (const config of Object.values(PACKAGE_CONFIGS)) expect(workflow).toContain(`'${config.key}-v*'`)
  expect(workflow).toContain("scripts/ci/assert-release-commit.mjs")
  expect(workflow).not.toContain("workflow_dispatch:")
})
