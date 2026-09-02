import { useEffect, useState } from "react"

import { SUPPORT_EMAIL, emailValue } from "~/lib/email"

const INLINE_LOGOTYPE_SRC = "/logotype-white.svg?v=2"
const INLINE_SYMBOL_SRC = "/inline-logo.svg"
const BETA_BADGE_SRC = "/beta-badge.svg"

const FOOTER_GROUPS = [
  {
    title: "Connect",
    links: [
      { label: "X / Twitter", href: "https://x.com/inline_chat", external: true, icon: "external" },
      { label: "GitHub", href: "https://github.com/inline-chat", external: true, icon: "external" },
      {
        label: "YouTube",
        href: "https://www.youtube.com/@inlinechat",
        external: true,
        icon: "external",
      },
      { label: emailValue(SUPPORT_EMAIL), href: `mailto:${emailValue(SUPPORT_EMAIL)}` },
    ],
  },
  {
    title: "Apps",
    links: [
      { label: "iOS TestFlight", href: "https://testflight.apple.com/join/FkC3f7fz", external: true },
      { label: "macOS", href: "/download/mac/beta" },
      { label: "CLI", href: "/docs/cli" },
    ],
  },
  {
    title: "Agents",
    links: [
      { label: "Set up agents", href: "/docs/add-inline" },
      { label: "OpenClaw", href: "/docs/openclaw" },
      { label: "Hermes Agent", href: "/docs/hermes" },
    ],
  },
  {
    title: "Developers",
    links: [
      { label: "Connect Inline MCP", href: "/docs/mcp" },
      { label: "Realtime API", href: "/docs/realtime-api" },
      { label: "Rust SDK", href: "/docs/rust-sdk" },
      { label: "Bot API", href: "/docs/bot-api" },
    ],
  },
  {
    title: "Resources",
    links: [
      { label: "Documentation", href: "/docs" },
      {
        label: "Beta Announcement",
        href: "https://www.youtube.com/watch?v=rjb4MVZbglg",
        external: true,
        icon: "play",
      },
      {
        label: "FAQ",
        href: "https://www.youtube.com/watch?v=ruJnO_ty74g",
        external: true,
        icon: "play",
      },
      { label: "Status", href: "https://status.inline.chat", external: true },
      { label: "What's New", href: "/docs/changelog" },
    ],
  },
  {
    title: "Legal",
    links: [
      { label: "Privacy", href: "/legal/privacy" },
      { label: "Terms", href: "/legal/terms" },
      { label: "Acceptable use", href: "/legal/aup" },
      { label: "Subprocessors", href: "/legal/subprocessors" },
      { label: "DPA", href: "/legal/dpa" },
    ],
  },
] as const

function FooterLinkIcon({ kind }: { kind: "external" | "play" }) {
  if (kind === "play") {
    return (
      <svg
        className="site-footer__link-icon site-footer__link-icon--play"
        viewBox="0 0 14 14"
        fill="none"
        aria-hidden="true"
      >
        <circle cx="7" cy="7" r="5.75" stroke="currentColor" strokeWidth="1.25" />
        <path d="M5.8 4.65 9.15 7 5.8 9.35Z" fill="currentColor" />
      </svg>
    )
  }

  return (
    <svg
      className="site-footer__link-icon"
      viewBox="0 0 12 12"
      fill="none"
      aria-hidden="true"
    >
      <path
        d="M3 9 9 3M4 3h5v5"
        stroke="currentColor"
        strokeWidth="1.25"
        strokeLinecap="round"
        strokeLinejoin="round"
      />
    </svg>
  )
}

export function SiteHeader({ layout = "landing" }: { layout?: "landing" | "docs" }) {
  const isDocs = layout === "docs"
  const [isScrolled, setIsScrolled] = useState(false)

  useEffect(() => {
    if (!isDocs) return

    const updateScrolledState = () => setIsScrolled(window.scrollY > 0)
    updateScrolledState()
    window.addEventListener("scroll", updateScrolledState, { passive: true })

    return () => window.removeEventListener("scroll", updateScrolledState)
  }, [isDocs])

  return (
    <header className={`site-header site-header--${layout}${isScrolled ? " site-header--scrolled" : ""}`}>
      <div className="site-chrome-frame">
        <a className="site-header__brand" href="/" aria-label="Inline home">
          <img
            src={isDocs ? INLINE_LOGOTYPE_SRC : INLINE_SYMBOL_SRC}
            alt=""
            width={isDocs ? 82 : 36}
            height={isDocs ? 18 : 36}
          />
        </a>
      </div>
    </header>
  )
}

export function SiteFooter({ ariaLabel = "Inline footer" }: { ariaLabel?: string }) {
  return (
    <footer className="site-footer" aria-label={ariaLabel}>
      <div className="site-chrome-frame">
        <div className="site-footer__content">
          <nav className="site-footer__grid" aria-label="Inline resources">
            {FOOTER_GROUPS.map((group) => {
              const titleId = `footer-${group.title.toLowerCase()}-title`

              return (
                <section className="site-footer__group" aria-labelledby={titleId} key={group.title}>
                  {group.title === "Connect" ? (
                    <a className="site-footer__brand" href="/" id={titleId} aria-label="Inline home">
                      <span className="site-footer__wordmark-crop" aria-hidden="true">
                        <img src={INLINE_LOGOTYPE_SRC} alt="" width="72" height="16" />
                      </span>
                      <img
                        className="site-footer__beta"
                        src={BETA_BADGE_SRC}
                        alt="Beta"
                        width="35"
                        height="13"
                      />
                    </a>
                  ) : (
                    <h2 id={titleId}>{group.title}</h2>
                  )}
                  {group.links.map((link) => (
                    <a
                      className={"icon" in link ? "site-footer__link--with-icon" : undefined}
                      href={link.href}
                      key={link.label}
                      target={"external" in link && link.external ? "_blank" : undefined}
                      rel={"external" in link && link.external ? "noopener noreferrer" : undefined}
                    >
                      <span>{link.label}</span>
                      {"icon" in link ? <FooterLinkIcon kind={link.icon} /> : null}
                    </a>
                  ))}
                  {group.title === "Connect" ? <span className="site-footer__copyright">© 2026</span> : null}
                </section>
              )
            })}
          </nav>
        </div>
      </div>
    </footer>
  )
}
