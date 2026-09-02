import { createFileRoute, Link, Outlet, useRouterState } from "@tanstack/react-router"
import { useEffect } from "react"

import { SiteFooter, SiteHeader } from "~/landing/SiteChrome"
import { LEGAL_NAV } from "~/legal/nav"

import styleCssUrl from "../../landing/styles/style.css?url"
import docsCssUrl from "../../landing/styles/docs.css?url"
import siteChromeCssUrl from "../../landing/styles/site-chrome.css?url"
import "../../landing/styles/page-content.css"

export const Route = createFileRoute("/legal")({
  component: LegalLayout,
  head: () => ({
    meta: [
      { title: "Legal - Inline" },
      {
        name: "description",
        content: "Legal policies and agreements for Inline.",
      },
    ],
    links: [
      { rel: "stylesheet", href: styleCssUrl },
      { rel: "stylesheet", href: docsCssUrl },
      { rel: "stylesheet", href: siteChromeCssUrl },
    ],
  }),
})

function LegalLayout() {
  const { pathname, hash } = useRouterState({
    select: (s) => ({ pathname: s.location.pathname, hash: s.location.hash }),
  })

  const normalizePath = (p: string) => (p.length > 1 ? p.replace(/\/+$/g, "") : p)
  const activePath = normalizePath(pathname)

  useEffect(() => {
    if (typeof document === "undefined") return
    if (!hash) return
    const id = hash.startsWith("#") ? hash.slice(1) : hash
    if (!id) return

    const el = document.getElementById(id)
    if (!el) return

    requestAnimationFrame(() => {
      el.scrollIntoView({ block: "start" })
    })
  }, [hash, pathname])

  return (
    <div className="docs-page legal-page">
      <SiteHeader />

      <div className="docs-body">
        <div className="docs-container">
          <div className="docs-layout legal-layout">
            <aside className="docs-sidebar legal-sidebar" aria-label="Legal navigation">
              {LEGAL_NAV.map((group) => (
                <div className="docs-sidebar-group" key={group.title}>
                  <div className="docs-sidebar-title">{group.title}</div>
                  {group.items.map((item) => {
                    const isActive = activePath === normalizePath(item.to)
                    const className = `docs-sidebar-link${isActive ? " docs-sidebar-link-active" : ""}`
                    return (
                      <Link key={item.to} to={item.to} className={className} aria-current={isActive ? "page" : undefined}>
                        {item.title}
                      </Link>
                    )
                  })}
                </div>
              ))}
            </aside>

            <main className="docs-main legal-main">
              <Outlet />
            </main>
          </div>
        </div>
      </div>

      <SiteFooter ariaLabel="Legal footer" />
    </div>
  )
}
