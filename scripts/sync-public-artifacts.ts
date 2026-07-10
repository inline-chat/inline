import { copyFile, mkdir, stat } from "node:fs/promises"
import { dirname, resolve, relative } from "node:path"

const repoRoot = resolve(import.meta.dir, "..")
const publicRoot = resolve(repoRoot, "../inline-public")

const files: Array<{ source: string; destination: string }> = [
  { source: "proto/core.proto", destination: "proto/core.proto" },
  { source: "proto/core.proto", destination: "crates/protocol/proto/core.proto" },
  { source: "packages/protocol/src/core.ts", destination: "packages/protocol/src/core.ts" },
  { source: "packages/protocol/src/index.ts", destination: "packages/protocol/src/index.ts" },
  { source: "packages/protocol/tsconfig.json", destination: "packages/protocol/tsconfig.json" },
  { source: "packages/bot-api-types/src/index.ts", destination: "packages/bot-api-types/src/index.ts" },
  { source: "packages/bot-api-types/tsconfig.json", destination: "packages/bot-api-types/tsconfig.json" },
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
  const src = resolve(repoRoot, file.source)
  const dest = resolve(publicRoot, file.destination)
  assertInside(publicRoot, dest)
  await mkdir(dirname(dest), { recursive: true })
  await copyFile(src, dest)
  console.log(`synced ${file.source} -> ${file.destination}`)
}
