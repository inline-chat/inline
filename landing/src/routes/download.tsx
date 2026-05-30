import * as stylex from "@stylexjs/stylex"
import { createFileRoute } from "@tanstack/react-router"

import { PageFooter } from "~/landing/components/PageFooter"
import styleCssUrl from "../landing/styles/style.css?url"

const TESTFLIGHT_URL = "https://testflight.apple.com/join/FkC3f7fz"

const DOC_LINKS = [
  { title: "MCP", label: "Setup", href: "/docs/mcp#quick-setup" },
  { title: "OpenClaw", label: "Install", href: "/docs/openclaw#install" },
  { title: "CLI", label: "Install", href: "/docs/cli#install" },
]

export const Route = createFileRoute("/download")({
  component: Download,
  head: () => ({
    links: [{ rel: "stylesheet", href: styleCssUrl }],
    meta: [
      {
        title: "Download Inline",
      },
      {
        name: "description",
        content: "Download Inline for macOS or join the iOS beta on TestFlight.",
      },
    ],
  }),
})

function Download() {
  return (
    <div {...stylex.props(styles.page)}>
      <main {...stylex.props(styles.root)}>
        <header {...stylex.props(styles.header)}>
          <a href="/" {...stylex.props(styles.brand)} aria-label="Inline home">
            <img {...stylex.props(styles.logo)} src="/favicon-black.png?v=2" alt="" />
            <span {...stylex.props(styles.wordmark)}>Inline</span>
          </a>

          <nav {...stylex.props(styles.nav)} aria-label="Main navigation">
            <a href="/docs" {...stylex.props(styles.navLink)}>
              Docs
            </a>
            <a href="/" {...stylex.props(styles.navLink)}>
              Join the Waitlist
            </a>
            <a href="https://x.com/inline_chat" target="_blank" rel="noopener noreferrer" {...stylex.props(styles.navLink)}>
              X
            </a>
            <a
              href="https://github.com/inline-chat/inline/blob/main/SUPPORT.md"
              target="_blank"
              rel="noopener noreferrer"
              {...stylex.props(styles.navLink)}
            >
              Sponsor
            </a>
          </nav>

          <a href="/download" {...stylex.props(styles.navEnd)} aria-current="page">
            Downloads
          </a>
        </header>

        <section {...stylex.props(styles.content)} aria-labelledby="download-title">
          <h1 id="download-title" {...stylex.props(styles.title)}>
            A delightful chat app for work &amp; friends
          </h1>

          <div {...stylex.props(styles.actions)} aria-label="Download options">
            <a href="/download/mac/beta" {...stylex.props(styles.primaryButton)}>
              Download for macOS
            </a>
            <a href={TESTFLIGHT_URL} target="_blank" rel="noopener noreferrer" {...stylex.props(styles.secondaryButton)}>
              Join iOS TestFlight
            </a>
          </div>

          <p {...stylex.props(styles.hint)}>
            Supports macOS 15+ and iOS 18+
            <br />
            Alpha • Currently invite-only
          </p>
        </section>

        <section {...stylex.props(styles.docsLinks)} aria-label="Additional setup docs">
          {DOC_LINKS.map((item) => (
            <div key={item.title} {...stylex.props(styles.docsLinkItem)}>
              <span {...stylex.props(styles.docsLinkTitle)}>{item.title}</span>
              <a href={item.href} {...stylex.props(styles.docsLink)}>
                {item.label}
                <span {...stylex.props(styles.docsLinkArrow)} aria-hidden="true">
                  →
                </span>
              </a>
            </div>
          ))}
        </section>
      </main>
      <PageFooter />
    </div>
  )
}

const styles = stylex.create({
  page: {
    minHeight: "100vh",
    display: "flex",
    flexDirection: "column",
    color: {
      default: "#000",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.9)",
    },
    fontFamily: '-apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif',
  },
  root: {
    flex: 1,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    padding: {
      default: "28px 0 70px",
      "@media (max-width: 900px)": "22px 20px 58px",
      "@media (max-width: 560px)": "18px 16px 48px",
    },
  },
  header: {
    width: "100%",
    maxWidth: 1084,
    display: "flex",
    alignItems: "center",
    justifyContent: "space-between",
    flexWrap: {
      default: "nowrap",
      "@media (max-width: 720px)": "wrap",
    },
    gap: 24,
  },
  brand: {
    flex: "1 1 0",
    minWidth: 0,
    display: "inline-flex",
    alignItems: "center",
    gap: 8,
    color: "inherit",
    textDecoration: "none",
    order: 1,
  },
  logo: {
    width: 24,
    height: 24,
    flexShrink: 0,
    filter: {
      default: "none",
      "@media (prefers-color-scheme: dark)": "invert(1)",
    },
  },
  wordmark: {
    fontFamily: '"Days One", "DaysOne-Regular", system-ui, sans-serif',
    fontSize: 21,
    lineHeight: "27px",
  },
  nav: {
    flex: "1 1 auto",
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    order: {
      default: 2,
      "@media (max-width: 720px)": 3,
    },
    width: {
      default: "auto",
      "@media (max-width: 720px)": "100%",
    },
    gap: {
      default: 34,
      "@media (max-width: 900px)": 22,
      "@media (max-width: 680px)": 16,
    },
  },
  navLink: {
    color: "inherit",
    fontSize: 14,
    lineHeight: "18px",
    textDecoration: "none",
    whiteSpace: "nowrap",
    opacity: {
      default: 1,
      ":hover": 0.66,
    },
    transition: "opacity 0.12s ease-out",
  },
  navEnd: {
    flex: "1 1 0",
    minWidth: 0,
    textAlign: "right",
    fontSize: 14,
    lineHeight: "18px",
    whiteSpace: "nowrap",
    order: 2,
    color: "inherit",
    textDecoration: "none",
    opacity: {
      default: 1,
      ":hover": 0.66,
    },
    transition: "opacity 0.12s ease-out",
  },
  content: {
    width: "100%",
    maxWidth: 520,
    flex: 1,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    textAlign: "center",
    justifyContent: "center",
    paddingTop: {
      default: 92,
      "@media (max-width: 560px)": 72,
    },
  },
  title: {
    marginBottom: 48,
    fontFamily: '"Days One", "DaysOne-Regular", system-ui, sans-serif',
    fontSize: {
      default: 43,
      "@media (max-width: 560px)": 34,
      "@media (max-width: 380px)": 30,
    },
    lineHeight: {
      default: "52px",
      "@media (max-width: 560px)": "42px",
      "@media (max-width: 380px)": "38px",
    },
    fontWeight: 400,
    textWrap: "balance",
  },
  actions: {
    display: "flex",
    flexDirection: "column",
    alignItems: "stretch",
    gap: 10,
    width: 331,
    maxWidth: "100%",
    marginBottom: 34,
  },
  primaryButton: {
    height: 40,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 10,
    padding: "0 18px",
    backgroundColor: {
      default: "#000",
      ":hover": "rgba(0, 0, 0, 0.82)",
      "@media (prefers-color-scheme: dark)": "rgba(255, 255, 255, 0.92)",
    },
    color: {
      default: "#fff",
      "@media (prefers-color-scheme: dark)": "#000",
    },
    textDecoration: "none",
    fontFamily: '"Days One", "DaysOne-Regular", system-ui, sans-serif',
    fontSize: 18,
    lineHeight: "22px",
    fontWeight: 400,
    transition: "background-color 0.15s ease-out, transform 0.15s ease-out",
    transform: {
      default: "scale(1)",
      ":active": "scale(0.98)",
    },
  },
  secondaryButton: {
    height: 40,
    display: "inline-flex",
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 10,
    padding: "0 18px",
    borderWidth: 2,
    borderStyle: "solid",
    borderColor: {
      default: "#000",
      "@media (prefers-color-scheme: dark)": "rgba(255, 255, 255, 0.85)",
    },
    backgroundColor: {
      default: "transparent",
      ":hover": "rgba(0, 0, 0, 0.06)",
    },
    color: "inherit",
    textDecoration: "none",
    fontFamily: '"Days One", "DaysOne-Regular", system-ui, sans-serif',
    fontSize: 18,
    lineHeight: "22px",
    fontWeight: 400,
    transition: "background-color 0.15s ease-out, transform 0.15s ease-out",
    transform: {
      default: "scale(1)",
      ":active": "scale(0.98)",
    },
  },
  hint: {
    fontSize: 13,
    lineHeight: "19px",
    color: "inherit",
  },
  docsLinks: {
    width: "100%",
    maxWidth: 372,
    display: "grid",
    gridTemplateColumns: "repeat(3, minmax(0, 1fr))",
    marginTop: {
      default: 76,
      "@media (max-width: 560px)": 60,
    },
    marginBottom: {
      default: 4,
      "@media (max-width: 560px)": 0,
    },
  },
  docsLinkItem: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: 2,
    padding: "0 14px",
    textAlign: "center",
    borderLeftWidth: {
      default: 1,
      ":first-child": 0,
    },
    borderLeftStyle: "solid",
    borderLeftColor: {
      default: "rgba(0, 0, 0, 0.14)",
      "@media (prefers-color-scheme: dark)": "rgba(255, 255, 255, 0.16)",
    },
  },
  docsLinkTitle: {
    fontFamily: '"Days One", "DaysOne-Regular", system-ui, sans-serif',
    fontSize: 15,
    lineHeight: "19px",
    fontWeight: 400,
  },
  docsLink: {
    color: "inherit",
    display: "inline-flex",
    alignItems: "center",
    gap: 3,
    fontFamily: '"Reddit Mono", monospace',
    fontSize: 14,
    lineHeight: "18px",
    textDecoration: "none",
    whiteSpace: "nowrap",
    opacity: {
      default: 0.8,
      ":hover": 1,
    },
    transition: "opacity 0.12s ease-out",
  },
  docsLinkArrow: {
    fontFamily: '"Reddit Mono", monospace',
    fontSize: 12,
    lineHeight: "18px",
    opacity: 0.6,
  },
})
