import {
  resolve,
} from "node:path"

const serverRoot =
  resolve(import.meta.dir, "..")
const patterns = [
  "src/**/*.test.ts",
  "src/**/*.spec.ts",
  "scripts/**/*.test.ts",
  "scripts/**/*.spec.ts",
] as const
const files = new Set<string>()

for (const pattern of patterns) {
  for await (
    const file of new Bun.Glob(
      pattern,
    ).scan({
      cwd: serverRoot,
      onlyFiles: true,
    })
  ) {
    files.add(file)
  }
}

const vitestImport =
  /from\s+["'](?:@effect\/vitest|vitest)["']/
const bunFiles: Array<string> = []

for (
  const file of [...files].sort()
) {
  if (
    file.endsWith(
      ".effect.bun.test.ts",
    )
  ) {
    continue
  }
  const source =
    await Bun.file(
      resolve(serverRoot, file),
    ).text()
  if (!vitestImport.test(source)) {
    bunFiles.push(file)
  }
}

if (bunFiles.length === 0) {
  throw new Error(
    "Canonical Bun test discovery found no files.",
  )
}

console.info(
  `Running ${bunFiles.length} Bun-owned test files; Vitest and explicit Effect Bun files run in test:effect.`,
)
const startedAt = performance.now()
const child = Bun.spawn({
  cmd: [
    process.execPath,
    "test",
    "--timeout=30000",
    ...(process.env["CI"] ? ["--only-failures"] : []),
    ...bunFiles,
  ],
  cwd: serverRoot,
  env: {
    ...process.env,
    NODE_ENV: "test",
  },
  stdin: "inherit",
  stdout: "inherit",
  stderr: "inherit",
})
const exitCode = await child.exited

console.info(
  `Bun-owned suite finished in ${((performance.now() - startedAt) / 1_000).toFixed(2)}s.`,
)

process.exit(exitCode)
