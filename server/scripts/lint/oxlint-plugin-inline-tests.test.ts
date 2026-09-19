import { expect, test } from "bun:test"
import { spawnSync } from "node:child_process"
import { resolve } from "node:path"

const root = resolve(import.meta.dir, "../../..")
const lint = (file: string) => spawnSync(resolve(root, "node_modules/.bin/oxlint"), [
  "--config", resolve(root, ".oxlintrc.json"), "--no-ignore", "--allow", "all",
  "--deny", "inline-tests/no-focused-tests", resolve(import.meta.dir, "fixtures", file),
], { cwd: root, encoding: "utf8" })

test("focused aliases, Effect variants and computed namespace calls cannot pass CI", () => {
  const result = lint("invalid-focused-tests.ts")
  expect(result.status).toBe(1)
  expect(`${result.stdout}${result.stderr}`.match(/Remove focused tests/g)).toHaveLength(4)
})

test("comments, string literals and unrelated only methods are not rejected", () => {
  const result = lint("valid-test-focus-text.ts")
  expect(result.status).toBe(0)
})
