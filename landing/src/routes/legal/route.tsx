import { createFileRoute, Link, Outlet, useRouterState } from "@tanstack/react-router"
import { useEffect, useState } from "react"

import { MoonIcon, SunIcon } from "~/docs/lucide"
import { LEGAL_NAV } from "~/legal/nav"

import styleCssUrl from "../../landing/styles/style.css?url"
import docsCssUrl from "../../landing/styles/docs.css?url"
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
    ],
  }),
})

function LegalLayout() {
  const { pathname, hash } = useRouterState({
    select: (s) => ({ pathname: s.location.pathname, hash: s.location.hash }),
  })

  const normalizePath = (p: string) => (p.length > 1 ? p.replace(/\/+$/g, "") : p)
  const activePath = normalizePath(pathname)

  const [theme, setTheme] = useState<"light" | "dark" | null>(null)
  const [isFooterEmailCopied, setIsFooterEmailCopied] = useState(false)

  useEffect(() => {
    if (typeof window === "undefined") return

    const stored = window.localStorage.getItem("inline_docs_theme")
    const resolved: "light" | "dark" =
      stored === "light" || stored === "dark"
        ? stored
        : window.matchMedia?.("(prefers-color-scheme: dark)")?.matches
          ? "dark"
          : "light"

    document.documentElement.dataset.theme = resolved
    setTheme(resolved)
  }, [])

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
      <header className="docs-topbar" aria-label="Legal top bar">
        <div className="docs-container">
          <div className="docs-topbar-inner">
            <a href="/" className="docs-topbar-home" aria-label="Inline home">
              <img className="docs-topbar-icon docs-topbar-icon--light" src="/favicon-black.png?v=2" alt="" />
              <img className="docs-topbar-icon docs-topbar-icon--dark" src="/favicon-white.png?v=2" alt="" />
              <span className="docs-topbar-wordmark" aria-hidden="true">
                Inline
              </span>
            </a>
            <div className="docs-topbar-actions">
              <button
                type="button"
                className="docs-theme-toggle"
                aria-label="Toggle theme"
                onClick={() => {
                  if (theme === null) return
                  const next = theme === "dark" ? "light" : "dark"
                  document.documentElement.dataset.theme = next
                  window.localStorage.setItem("inline_docs_theme", next)
                  setTheme(next)
                }}
              >
                {theme === "dark" ? <SunIcon /> : <MoonIcon />}
              </button>
            </div>
          </div>
        </div>
      </header>

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

      <footer className="docs-footer" aria-label="Legal footer">
        <div className="docs-container">
          <div className="docs-footer-inner">
            <div className="docs-footer-brand">
              <span className="docs-footer-wordmark">Inline</span>
              <span className="docs-footer-muted">Work chat for high-performance teams.</span>
            </div>
            <div className="docs-footer-links">
              <a href="/docs">Docs</a>
              <a href="/docs/security">Security</a>
              <a href="/legal/terms">Terms</a>
              <a href="/legal/privacy">Privacy</a>
              <a href="/legal/subprocessors">Subprocessors</a>
              <button
                type="button"
                className="docs-footer-copy"
                onClick={async () => {
                  try {
                    await navigator.clipboard.writeText("hey@inline.chat")
                    setIsFooterEmailCopied(true)
                    window.setTimeout(() => setIsFooterEmailCopied(false), 900)
                  } catch {
                    // If clipboard is unavailable, fail silently.
                  }
                }}
              >
                {isFooterEmailCopied ? "hey@inline.chat copied" : "hey@inline.chat"}
              </button>
            </div>
          </div>
        </div>
      </footer>
    </div>
  )
}
