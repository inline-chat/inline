import { readdir, readFile } from "node:fs/promises"
import { join } from "node:path"

import type { DocsSource } from "./catalog"

export async function listDocsMarkdownFiles(directory: string, prefix = ""): Promise<string[]> {
  const entries = await readdir(join(directory, prefix), { withFileTypes: true })
  const paths = await Promise.all(
    entries.map(async (entry): Promise<string[]> => {
      const relativePath = prefix ? `${prefix}/${entry.name}` : entry.name
      if (entry.isDirectory()) return listDocsMarkdownFiles(directory, relativePath)
      if (entry.isFile() && entry.name.endsWith(".md")) return [relativePath]
      return []
    }),
  )
  return paths.flat().sort()
}

export async function readDocsSources(directory: string): Promise<DocsSource[]> {
  const paths = await listDocsMarkdownFiles(directory)
  return Promise.all(
    paths.map(async (relativePath) => ({
      path: `./content/${relativePath}`,
      markdown: await readFile(join(directory, relativePath), "utf8"),
    })),
  )
}
