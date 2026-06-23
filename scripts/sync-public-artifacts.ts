import { copyFile, mkdir, stat } from "node:fs/promises"
import { dirname, resolve, relative } from "node:path"

const repoRoot = resolve(import.meta.dir, "..")
const publicRoot = resolve(repoRoot, "../inline-public")

const files = [
  "proto/core.proto",
  "packages/protocol/package.json",
  "packages/protocol/src/core.ts",
  "packages/protocol/src/index.ts",
  "packages/protocol/tsconfig.json",
  "packages/bot-api-types/package.json",
  "packages/bot-api-types/src/index.ts",
  "packages/bot-api-types/tsconfig.json",
]

async function exists(path: string): Promise<boolean> {
  try {
    await stat(path)
    return true
  } catch {
    return false
  }
}

function assertInside(root: string, path: string) {
  const rel = relative(root, path)
  if (rel.startsWith("..") || rel === "") {
    throw new Error(`refusing to write outside public repo: ${path}`)
  }
}

if (!(await exists(resolve(publicRoot, "package.json")))) {
  throw new Error(`public repo not found at ${publicRoot}`)
}

for (const file of files) {
  const src = resolve(repoRoot, file)
  const dest = resolve(publicRoot, file)
  assertInside(publicRoot, dest)
  await mkdir(dirname(dest), { recursive: true })
  await copyFile(src, dest)
  console.log(`synced ${file}`)
}
