import sidebarConfig from "./sidebar.json"
import technicalSidebarConfig from "./technical-sidebar.json"
import { ALL_DOCS_PAGES, DOCS_INCLUDE_DRAFTS } from "./pages"
import { docsPublicationOrder, resolveDocsSidebar, type DocsNavGroup } from "./sidebar"

export type { DocsNavGroup }

export const DOCS_NAV = resolveDocsSidebar(sidebarConfig, ALL_DOCS_PAGES, DOCS_INCLUDE_DRAFTS).groups
export const TECHNICAL_DOCS_NAV = resolveDocsSidebar(
  technicalSidebarConfig,
  ALL_DOCS_PAGES,
  DOCS_INCLUDE_DRAFTS,
).groups
export const DOCS_PUBLICATION_PAGES = docsPublicationOrder(
  [sidebarConfig, technicalSidebarConfig],
  ALL_DOCS_PAGES,
)
