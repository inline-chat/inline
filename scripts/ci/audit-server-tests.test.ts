import { expect, test } from "bun:test"
import { mkdir, mkdtemp, readFile, writeFile } from "node:fs/promises"
import os from "node:os"
import path from "node:path"

const expectations = JSON.parse(await readFile(path.join(import.meta.dir, "server-test-expectations.json"), "utf8")) as {
  requiredFiles: string[]
}

test("audit requires a completed report for every selected file and rejects skips", async () => {
  const root = await mkdtemp(path.join(os.tmpdir(), "inline-server-audit-"))
  const cases = expectations.requiredFiles.map((file) =>
    `<testsuite name="${file}"><testcase file="${file}" name="runs" /></testsuite>`).join("")
  for (const [lane, files, body] of [
    ["bun", expectations.requiredFiles, cases],
    ["effect", ["src/effect.test.ts"], '<testsuite><testcase classname="src/effect.test.ts" name="runs" /></testsuite>'],
    ["effect-bun", ["src/effect.bun.test.ts"], '<testsuite><testcase file="src/effect.bun.test.ts" name="runs" /></testsuite>'],
    ["preview", ["packages/url-preview/src/preview.test.ts"], '<testsuite><testcase file="packages/url-preview/src/preview.test.ts" name="runs" /></testsuite>'],
  ] as const) {
    const dir = lane === "effect" ? root : path.join(root, `${lane}-test`)
    await mkdir(dir, { recursive: true })
    const report = `${lane}.xml`
    const manifest = lane === "effect" ? "effect-run.json" : "run.json"
    await writeFile(path.join(dir, manifest), JSON.stringify({
      lane, status: "complete", selected: files,
      batches: [{ report, files, exitCode: 0 }],
    }))
    await writeFile(path.join(dir, report), `<testsuites>${body}</testsuites>`)
  }
  const run = () => Bun.spawnSync([process.execPath, "--no-env-file", path.join(import.meta.dir, "audit-server-tests.ts"), root])
  expect(run().exitCode).toBe(0)
  const bunXml = path.join(root, "bun-test/bun.xml")
  const original = await readFile(bunXml, "utf8")
  await writeFile(bunXml, original.replace('name="runs"', 'name="runs"><skipped /></testcase><testcase file="src/__tests__/bot-api.test.ts" name="extra"'))
  expect(run().exitCode).toBe(1)
  await writeFile(bunXml, original)
  const manifestPath = path.join(root, "preview-test/run.json")
  const selected = JSON.parse(await readFile(manifestPath, "utf8"))
  selected.batches[0].exitCode = null
  await writeFile(manifestPath, JSON.stringify(selected))
  expect(run().exitCode).toBe(1)
})
