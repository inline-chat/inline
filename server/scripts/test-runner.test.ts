import { expect, test } from "bun:test"
import { resolve } from "node:path"
import { createTestEnvironment } from "./test-environment"

const root = resolve(import.meta.dir, "..")
const run = async (...args: string[]) => {
  const child = Bun.spawn({
    cmd: [process.execPath, "--no-env-file", resolve(root, "scripts/test-runner.ts"), ...args],
    // This subprocess is a CLI fixture, not another CI lane/report publisher.
    cwd: root, env: createTestEnvironment({ ...process.env, CI: undefined }), stdout: "pipe", stderr: "pipe",
  })
  const [code, stdout, stderr] = await Promise.all([
    child.exited, new Response(child.stdout).text(), new Response(child.stderr).text(),
  ])
  return { code, output: stdout + stderr }
}

test("a misspelled test selection cannot report a successful empty run", async () => {
  const result = await run("--unit", "no-such-test-file-848473")
  expect(result.code).not.toBe(0)
  expect(result.output).toContain("No test files matched")
})

test.each(["--no-isolate", "--concurrent", "--retry=3", "--pass-with-no-tests"])("cannot weaken the suite with %s", async (flag) => {
  const result = await run("--unit", "--", flag)
  expect(result.code).not.toBe(0)
  expect(result.output).toContain("cannot be overridden")
})

test("a unit selection executes successfully with no running database", async () => {
  const result = await run("--unit", "scripts/test-environment.test.ts", "--jobs", "1")
  expect(result.code).toBe(0)
  expect(result.output).toMatch(/\b[1-9]\d* pass\b/)
  expect(result.output).toContain("0 fail")
})
