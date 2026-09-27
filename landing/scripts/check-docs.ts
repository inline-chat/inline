import { existsSync } from "node:fs"
import { join, resolve } from "node:path"
import { fileURLToPath } from "node:url"

import { createDocsPages } from "../src/docs/catalog"
import sidebarConfig from "../src/docs/sidebar.json"
import technicalSidebarConfig from "../src/docs/technical-sidebar.json"
import { docsPublicationOrder, resolveDocsSidebar } from "../src/docs/sidebar"
import { readDocsSources } from "../src/docs/sourceFiles"

const landingRoot = fileURLToPath(new URL("..", import.meta.url))
const contentDirectory = join(landingRoot, "src/docs/content")
const pages = createDocsPages(await readDocsSources(contentDirectory))

resolveDocsSidebar(sidebarConfig, pages, true)
resolveDocsSidebar(technicalSidebarConfig, pages, true)
const publishedPages = docsPublicationOrder([sidebarConfig, technicalSidebarConfig], pages)
const draftCount = pages.filter((page) => page.draft).length

// Keep source references useful in both HTML and the Markdown served to agents.
const repositoryRoot = resolve(landingRoot, "..")
for (const page of publishedPages) {
  const sourceLinks = [
    ...page.markdown.matchAll(/https:\/\/github\.com\/inline-chat\/inline\/(?:blob|tree)\/main\/([^\s)#]+)/g),
  ]
  for (const [, sourcePath] of sourceLinks) {
    if (!existsSync(join(repositoryRoot, sourcePath))) {
      throw new Error(`${page.slug}: GitHub source path does not exist: ${sourcePath}`)
    }
  }
  if (page.slug !== "changelog") {
    const footer = page.markdown.split("\n## Source\n").at(-1) ?? ""
    if (
      !page.markdown.includes("\n## Source\n") ||
      !footer.includes("https://github.com/inline-chat/inline/") ||
      /\n## /.test(footer)
    ) {
      throw new Error(`${page.slug}: end the guide with a Source section linking its implementation`)
    }
  }
}

console.log(`Docs valid: ${publishedPages.length} published, ${draftCount} draft`)
