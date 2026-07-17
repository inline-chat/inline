import { describe, expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { fileURLToPath } from "node:url"
import path from "node:path"

const repositoryRoot = fileURLToPath(new URL("../../../", import.meta.url))
const oxlint = path.join(repositoryRoot, "node_modules/.bin/oxlint")
const config = path.join(repositoryRoot, ".oxlintrc.json")
const fixtures = path.join(repositoryRoot, "server/scripts/lint/fixtures")

const lintFixture = (filename: string) => {
  const result = spawnSync(
    oxlint,
    [
      "--config",
      config,
      "--no-ignore",
      "--deny-warnings",
      "--report-unused-disable-directives",
      path.join(fixtures, filename),
    ],
    {
      cwd: repositoryRoot,
      encoding: "utf8",
    },
  )

  return {
    status: result.status,
    output: `${result.stdout}\n${result.stderr}`,
  }
}

describe("inline-effect Oxlint plugin", () => {
  test("rejects imported Effect escape hatches", () => {
    const result = lintFixture("invalid-effect-escape-hatch.ts")

    expect(result.status).toBe(1)
    expect(result.output).toContain("inline-effect(no-effect-escape-hatch)")
  })

  test("rejects suppressions without a categorized reason", () => {
    const result = lintFixture("invalid-suppression-reason.ts")

    expect(result.status).toBe(1)
    expect(result.output).toContain("inline-effect(require-suppression-reason)")
  })

  test("rejects file-wide suppressions", () => {
    const result = lintFixture("invalid-blanket-suppression.ts")

    expect(result.status).toBe(1)
    expect(result.output).toContain("inline-effect(require-suppression-reason)")
    expect(result.output).toContain("Do not use file-wide")
  })

  test("accepts a narrow, reasoned boundary suppression", () => {
    const result = lintFixture("valid-boundary-suppression.ts")

    expect(result.status).toBe(0)
    expect(result.output).not.toContain("inline-effect/")
  })

  test("accepts typed failures and unrelated properties", () => {
    const result = lintFixture("valid-typed-failure.ts")

    expect(result.status).toBe(0)
    expect(result.output).not.toContain("inline-effect/")
  })
})
