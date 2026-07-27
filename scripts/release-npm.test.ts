import { describe, expect, test } from "bun:test"
import {
  PACKAGE_CONFIGS,
  expectedDistTag,
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
    expect(() => expectedDistTag("1.2")).toThrow("Invalid semantic version")
    expect(() => expectedDistTag("1.2.3-rc.1")).toThrow("unsupported dist-tag rc")
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

  test("returns the committed version for a public trusted package", () => {
    expect(validateManifest(config, manifest, "0.0.6")).toBe("0.0.6")
  })

  test("rejects private, mismatched, and incorrectly sourced packages", () => {
    expect(() => validateManifest(config, { ...manifest, private: true })).toThrow("marked private")
    expect(() => validateManifest(config, manifest, "0.0.7")).toThrow("Version mismatch")
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

test("keeps the local allowlist aligned with the workflow security boundary", async () => {
  const workflow = await Bun.file(
    new URL("../.github/workflows/npm-publish.yml", import.meta.url),
  ).text()

  for (const config of Object.values(PACKAGE_CONFIGS)) {
    expect(workflow).toContain(`          - ${config.key}`)

    const branch = workflow
      .split(`            ${config.key})`, 2)[1]
      ?.split("              ;;", 1)[0]
    expect(branch).toBeDefined()
    expect(branch).toContain(`              package_dir="${config.directory}"`)
    expect(branch).toContain(`              package_name="${config.name}"`)
  }
})
