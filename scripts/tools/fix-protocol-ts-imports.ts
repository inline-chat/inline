import { readFile, writeFile } from "node:fs/promises"

const files = [
  "../packages/protocol/src/client.ts",
  "../packages/protocol/src/server.ts",
] as const

const rewrite = (input: string) => {
  let out = input

  // protobuf-ts 2.9.x emits extensionless relative imports; Node ESM needs explicit .js.
  out = out.replaceAll('from "./core";', 'from "./core.js";')
  out = out.replaceAll("from './core';", "from './core.js';")

  return out
}

for (const rel of files) {
  const before = await readFile(rel, "utf8")
  const after = rewrite(before)
  if (after !== before) {
    await writeFile(rel, after, "utf8")
  }
}

