import { createFileRoute, Link, Outlet, useRouterState } from "@tanstack/react-router"
import { useEffect, useRef } from "react"

import { DOCS_NAV, TECHNICAL_DOCS_NAV, type DocsNavGroup } from "~/docs/nav"
import { SiteFooter, SiteHeader } from "~/landing/SiteChrome"

import styleCssUrl from "../../landing/styles/style.css?url"
import docsCssUrl from "../../landing/styles/docs.css?url"
import siteChromeCssUrl from "../../landing/styles/site-chrome.css?url"
import "../../landing/styles/page-content.css"

const normalizePath = (path: string) => (path.length > 1 ? path.replace(/\/+$/g, "") : path)

function DocsNavLinks({
  activePath,
  groups,
  onNavigate,
}: {
  activePath: string
  groups: DocsNavGroup[]
  onNavigate?: () => void
}) {
  return groups.map((group) => (
    <div className="docs-sidebar-group" key={group.title}>
      <div className="docs-sidebar-title">{group.title}</div>
      {group.items.map((item) => {
        const isActive = activePath === normalizePath(item.to)
        const className = `docs-sidebar-link${isActive ? " docs-sidebar-link-active" : ""}${item.external ? " docs-sidebar-link-external" : ""}`
        return (
          <Link
            key={item.to}
            to={item.to}
            activeOptions={{ exact: true }}
            className={className}
            aria-current={isActive ? "page" : undefined}
            onClick={onNavigate}
          >
            {item.title}
            {item.draft ? <span className="docs-sidebar-draft">Draft</span> : null}
          </Link>
        )
      })}
    </div>
  ))
}

export const Route = createFileRoute("/docs")({
  component: DocsLayout,
  head: () => ({
    meta: [{ title: "Docs - Inline" }],
    links: [
      { rel: "stylesheet", href: styleCssUrl },
      { rel: "stylesheet", href: docsCssUrl },
      { rel: "stylesheet", href: siteChromeCssUrl },
    ],
  }),
})

function DocsLayout() {
  const mobileNavRef = useRef<HTMLDetailsElement>(null)
  const { pathname, hash } = useRouterState({
    select: (s) => ({ pathname: s.location.pathname, hash: s.location.hash }),
  })

  const activePath = normalizePath(pathname)
  const isTechnicalDocs = activePath === "/docs/technical" || activePath.startsWith("/docs/technical/")
  const navGroups = isTechnicalDocs ? TECHNICAL_DOCS_NAV : DOCS_NAV
  const navLabel = isTechnicalDocs ? "Technical Docs" : "Docs"
  const activeTitle = navGroups.flatMap((group) => group.items).find(
    (item) => normalizePath(item.to) === activePath,
  )?.title

  useEffect(() => {
    if (typeof document === "undefined") return
    if (!hash) return
    const id = hash.startsWith("#") ? hash.slice(1) : hash
    if (!id) return

    const el = document.getElementById(id)
    if (!el) return

    // Wait a frame for nested routes/markdown to paint before scrolling.
    requestAnimationFrame(() => {
      el.scrollIntoView({ block: "start" })
    })
  }, [hash, pathname])

  return (
    <div className="docs-page">
      <SiteHeader layout="docs" />

      <div className="docs-body">
        <div className="docs-container">
          <div className="docs-layout">
            <aside className="docs-sidebar" aria-label={`${navLabel} navigation`}>
              <DocsNavLinks activePath={activePath} groups={navGroups} />
            </aside>

            <details ref={mobileNavRef} className="docs-mobile-nav">
              <summary>
                <span>{navLabel}</span>
                <strong>{activeTitle ?? "Navigation"}</strong>
              </summary>
              <nav aria-label={`Mobile ${navLabel.toLowerCase()} navigation`}>
                <DocsNavLinks
                  activePath={activePath}
                  groups={navGroups}
                  onNavigate={() => {
                    if (mobileNavRef.current) mobileNavRef.current.open = false
                  }}
                />
              </nav>
            </details>

            <main className="docs-main">
              <Outlet />
            </main>
          </div>
        </div>
      </div>

      <SiteFooter ariaLabel="Docs footer" />
    </div>
  )
}
