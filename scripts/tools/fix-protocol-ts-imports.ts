import { readFile, writeFile } from "node:fs/promises"

const files = [
  {
    path: "../packages/protocol/src/client.ts",
    replacements: [
      ['from "./core";', 'from "./core.js";'],
      ["from './core';", "from './core.js';"],
    ],
  },
  {
    path: "../server/src/protocol/server.ts",
    prepend: "// @ts-nocheck\n",
    replacements: [
      ['from "./core";', 'from "@inline-chat/protocol/core";'],
      ["from './core';", "from '@inline-chat/protocol/core';"],
    ],
  },
] as const

const rewrite = (input: string, replacements: readonly (readonly [string, string])[], prepend?: string) => {
  let out = input

  if (prepend && !out.startsWith(prepend)) {
    out = `${prepend}${out}`
  }

  // protobuf-ts 2.9.x emits local core imports; each generated target has a different runtime location.
  for (const [from, to] of replacements) {
    out = out.replaceAll(from, to)
  }

  return out
}

for (const file of files) {
  const before = await readFile(file.path, "utf8")
  const after = rewrite(before, file.replacements, "prepend" in file ? file.prepend : undefined)
  if (after !== before) {
    await writeFile(file.path, after, "utf8")
  }
}
