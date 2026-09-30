import { describe, expect, it } from "bun:test"
import { readFileSync } from "node:fs"
import path from "node:path"
import { parse } from "yaml"
import { checkResults, selectAppleJobs, validationJobs } from "./validation-gates.mjs"

describe("Apple selection", () => {
  it("always qualifies main, manual runs, missing and empty diffs", () => {
    for (const event of ["push", "workflow_dispatch", "pull_request"]) {
      expect(selectAppleJobs(event, undefined)).toEqual(validationJobs.apple)
      expect(selectAppleJobs(event, [])).toEqual(validationJobs.apple)
    }
    expect(selectAppleJobs("push", ["server/src/index.ts"])).toEqual(validationJobs.apple)
  })
  it("skips only known unrelated PR paths", () => {
    expect(selectAppleJobs("pull_request", ["server/src/index.ts", "plugins/hermes-agent/package.json", "cli/src/main.rs", "README.md"])).toEqual([])
    for (const file of ["apple/InlineKit/Package.swift", "proto/core.proto", "packages/protocol/trust-roots/inline-protocol-production.json", "scripts/ci/validation-gates.mjs", "scripts/apple/build-ci-app.sh", ".github/workflows/apple-validation.yml", "bun.lock", "package.json", "new-system/source.ts"]) {
      expect(selectAppleJobs("pull_request", ["server/src/index.ts", file]), file).toEqual(validationJobs.apple)
    }
  })
})

describe("required validation results", () => {
  for (const [kind, jobs] of Object.entries(validationJobs)) {
    const needs = Object.fromEntries([...(kind === "apple" ? ["changes"] : []), ...jobs].map((job) => [job, { result: "success" }]))
    it(`${kind}: matches the entire workflow dependency inventory`, () => {
      const filename = { apple: "apple-validation", integrations: "integrations", server: "server-test" }[kind]
      const workflow = parse(readFileSync(path.resolve(import.meta.dir, `../../.github/workflows/${filename}.yml`), "utf8"))
      expect(Object.keys(workflow.jobs).filter((job) => job !== "required").sort()).toEqual(Object.keys(needs).sort())
      expect([...workflow.jobs.required.needs].sort()).toEqual(Object.keys(needs).sort())
      expect(workflow.jobs.required.if).toBe("${{ always() }}")
      expect(() => checkResults(kind, needs)).not.toThrow()
    })
    it(`${kind}: rejects a failed, cancelled, skipped or missing selected job`, () => {
      for (const job of Object.keys(needs)) {
        for (const result of ["failure", "cancelled", "skipped", undefined]) {
          expect(() => checkResults(kind, { ...needs, [job]: { result } })).toThrow()
        }
      }
      expect(() => checkResults(kind, { ...needs, unknown: { result: "success" } })).toThrow()
    })
  }
  it("accepts Apple skips only with a successful selector and an explicit valid plan", () => {
    const skipped = Object.fromEntries(validationJobs.apple.map((job) => [job, { result: "skipped" }]))
    const needs = { changes: { result: "success" }, ...skipped }
    expect(() => checkResults("apple", needs, [])).not.toThrow()
    expect(() => checkResults("apple", needs, ["contracts"])).toThrow()
    expect(() => checkResults("apple", needs, ["unknown"])).toThrow()
    expect(() => checkResults("apple", { ...needs, changes: { result: "failure" } }, [])).toThrow()
    expect(() => checkResults("apple", { ...needs, contracts: { result: "cancelled" } }, [])).toThrow()
  })
})
