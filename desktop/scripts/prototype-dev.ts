import { watch } from "node:fs"

const root = import.meta.dir.replace(/\/scripts$/, "")
const output = `${root}/build/prototype.cjs`

const buildPrototype = async () => {
  console.log("Building prototype...")
  const result = await Bun.build({
    entrypoints: [`${root}/src/prototype/LegacyWindowPrototype.ts`],
    outdir: `${root}/build`,
    naming: "prototype.cjs",
    external: ["electron"],
    target: "node",
    format: "cjs",
  })

  if (!result.success) {
    for (const log of result.logs) console.error(log)
    throw new Error("Electron prototype compilation failed")
  }
}

const run = () => {
  console.log("Running prototype...")

  const proc = Bun.spawn(["bun", "electron", output], {
    cwd: root,
    stdin: "inherit",
    stdout: "inherit",
    stderr: "inherit",
  })

  return () => {
    proc.kill("SIGINT")
  }
}

let stopPrevious: () => void

await buildPrototype()
stopPrevious = run()

watch(`${root}/src/prototype`, async () => {
  stopPrevious()
  try {
    await buildPrototype()
    stopPrevious = run()
  } catch (error) {
    console.error("Failed to build prototype")
    console.error(error)
  }
})
