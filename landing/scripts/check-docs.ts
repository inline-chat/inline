import { join } from "node:path"
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

console.log(`Docs valid: ${publishedPages.length} published, ${draftCount} draft`)
