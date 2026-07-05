import { DOCS_NAV_GROUPS, DOCS_PAGES } from "~/docs/pages"

export type DocsNavGroup = {
  title: string
  items: Array<{
    title: string
    to: string
  }>
}

export const DOCS_NAV: DocsNavGroup[] = DOCS_NAV_GROUPS.map((group) => ({
  title: group.title,
  items: DOCS_PAGES.filter((page) => page.navGroup === group.id).map((page) => ({
    title: ("navTitle" in page ? page.navTitle : undefined) ?? page.title,
    to: page.route,
  })),
})).map((group) =>
  group.title === "Policies"
    ? {
        ...group,
        items: [...group.items, { title: "Legal", to: "/legal" }],
      }
    : group,
)
