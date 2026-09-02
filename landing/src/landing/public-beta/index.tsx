import * as stylex from "@stylexjs/stylex"
import type { Locale } from "./preferences"

const paragraphs = [
  "It’s a work chat app. A Slack replacement if you will. But it’s much more than making Slack or Discord a little bit better or more beautiful. It completely redesigns how work chat works from scratch.",
  "Inline is built on top of a simple concept: threads. Threads are a collection of messages. Think of it as a multiplayer append-only document. You can link to them, nest them, branch of a message, create new ones for every conversation or keep chatting in a large one.",
  "I believe threads beat documents for multiplayer collaboration, simply because there’s no coordination needed with others. No stepping on each others toes.",
  "Threads not only enable the workflows in Slack, Discord, iMessage and Telegram, they unlock new workflows that solve the common issues with those apps.",
  "For working with agents, threads are the natural primitive too. We all work in threads in Codex, Claude, and alike. Turns out what works best for thousands of conversations with LLMs, works best for humans too.",
  "I always wanted to open my chat app, press Command+N and start dumping my ideas, screenshots, and @ my teammate for their thoughts. And when I’m done, just hit (X) and get to a clean state. That’s what Inline enables.",
  "If you want to do that in another chat app, think what would it take? Decide if you DM or post in a channel, which channel? A reply thread? Would @ make it look like it’s urgent? Am I ready to post my thoughts publicly yet or I may discard them after a few minutes? Is it really worth sharing? Lots of different friction points.",
] as const

const footerSections = [
  {
    title: "Apps",
    links: [
      { label: "macOS download", href: "/download/mac/beta" },
      { label: "iOS TestFlight", href: "https://testflight.apple.com/join/FkC3f7fz" },
      { label: "What’s New", href: "/docs/changelog" },
    ],
  },
  {
    title: "Get started",
    links: [
      { label: "Docs", href: "/docs" },
      { label: "Set up an agent", href: "/docs/agents" },
      { label: "CLI", href: "/docs/cli" },
      { label: "MCP", href: "/docs/mcp" },
      { label: "Add Inline", href: "/docs/add-inline" },
    ],
  },
  {
    title: "Build",
    links: [
      { label: "OpenClaw", href: "/docs/openclaw" },
      { label: "Hermes", href: "/docs/hermes" },
      { label: "Bot API", href: "/docs/bot-api" },
      { label: "Realtime API", href: "/docs/realtime-api" },
      { label: "Rust SDK", href: "/docs/rust-sdk" },
    ],
  },
  {
    title: "Inline",
    links: [
      { label: "About", href: "/docs/whats-inline" },
      { label: "Roadmap", href: "/docs/roadmap" },
      { label: "GitHub", href: "https://github.com/inline-chat" },
      { label: "X", href: "https://x.com/inline_chat" },
      { label: "YouTube", href: "https://www.youtube.com/@inlinechat" },
      { label: "Status", href: "https://status.inline.chat" },
      { label: "Contact", href: "mailto:hey@inline.chat" },
      { label: "Legal", href: "/legal" },
    ],
  },
] as const

export function PublicBetaLanding({ locale }: { locale: Locale }) {
  return (
    <div lang={locale} {...stylex.props(styles.page)}>
      <div lang="en" dir="ltr" {...stylex.props(styles.shell)}>
        <header {...stylex.props(styles.header)}>
          <a href="/beta" aria-label="Inline beta home" {...stylex.props(styles.brand)}>
            <InlineMark />
            <span {...stylex.props(styles.wordmark)}>Inline</span>
            <span {...stylex.props(styles.betaLabel)}>Beta</span>
          </a>
        </header>

        <main {...stylex.props(styles.main)}>
          <h1 {...stylex.props(styles.heading)}>The interface for multiplayer work</h1>
          <div {...stylex.props(styles.prose)}>
            {paragraphs.map((paragraph) => (
              <p key={paragraph}>{paragraph}</p>
            ))}
          </div>
        </main>

        <footer aria-label="Footer" {...stylex.props(styles.footer)}>
          <div {...stylex.props(styles.footerGrid)}>
            {footerSections.map((section) => (
              <section key={section.title} {...stylex.props(styles.footerSection)}>
                <h2 {...stylex.props(styles.footerHeading)}>{section.title}</h2>
                <div {...stylex.props(styles.footerLinks)}>
                  {section.links.map((link) => (
                    <a key={link.label} href={link.href} {...stylex.props(styles.footerLink)}>
                      {link.label}
                    </a>
                  ))}
                </div>
              </section>
            ))}
          </div>
          <p {...stylex.props(styles.copyright)}>© 2026 Inline Chat</p>
        </footer>
      </div>
    </div>
  )
}

function InlineMark() {
  return (
    <svg aria-hidden="true" viewBox="0 0 21 21" {...stylex.props(styles.mark)}>
      <path d="M12.0556 0C13.1391 1.22334e-09 13.6808 0 14.1364 0.0539237C17.7074 0.476593 20.5234 3.29255 20.9461 6.86362C21 7.31921 21 7.86094 21 8.9444V12.0556C21 13.1391 21 13.6808 20.9461 14.1364C20.5234 17.7074 17.7074 20.5234 14.1364 20.9461C13.6808 21 13.1391 21 12.0556 21H8.9444L8.22631 20.9993C7.70059 20.9972 7.34217 20.9897 7.03963 20.9639L6.86362 20.9461C3.34825 20.53 0.564864 17.7948 0.0756356 14.303L0.0539237 14.1364C0 13.6808 1.22392e-09 13.1391 0 12.0556V8.9444C-1.44842e-09 7.99637 0 7.46319 0.0361271 7.03963L0.0539237 6.86362C0.470008 3.34825 3.20517 0.564864 6.69704 0.0756356L6.86362 0.0539237C7.20531 0.0135254 7.59542 0.00320339 8.22631 0.000711864L8.9444 0H12.0556ZM8.9444 3.88892C7.74989 3.88892 7.49095 3.89568 7.32064 3.91579C5.5351 4.12721 4.12721 5.5351 3.91579 7.32064C3.89568 7.49095 3.88892 7.74989 3.88892 8.9444V12.0556C3.88892 13.2501 3.89568 13.5091 3.91579 13.6794C4.12721 15.4649 5.5351 16.8728 7.32064 17.0842C7.49095 17.1043 7.74989 17.1111 8.9444 17.1111H12.0556C13.2501 17.1111 13.5091 17.1043 13.6794 17.0842C15.4649 16.8728 16.8728 15.4649 17.0842 13.6794C17.1043 13.5091 17.1111 13.2501 17.1111 12.0556V8.9444C17.1111 7.74989 17.1043 7.49095 17.0842 7.32064C16.8728 5.5351 15.4649 4.12721 13.6794 3.91579C13.5091 3.89568 13.2501 3.88892 12.0556 3.88892H8.9444ZM8.9444 6.61108C9.80344 6.61108 10.5 7.30747 10.5 8.16669V12.8333C10.5 13.6925 9.80344 14.3889 8.9444 14.3889H8.16669C7.30764 14.3887 6.61126 13.6925 6.61108 12.8333V8.16669C6.61126 7.30764 7.30764 6.61126 8.16669 6.61108H8.9444Z" />
    </svg>
  )
}

const styles = stylex.create({
  page: {
    minHeight: "100vh",
    backgroundColor: "#ffffff",
    color: "#090909",
    colorScheme: "light",
    fontFamily: "ui-sans-serif, system-ui, -apple-system, BlinkMacSystemFont, 'Segoe UI', sans-serif",
  },
  shell: {
    width: "100%",
    maxWidth: 970,
    marginInline: "auto",
    paddingInline: { default: 24, "@media (min-width: 720px)": 40 },
  },
  header: {
    paddingTop: { default: 32, "@media (min-width: 720px)": 48 },
  },
  brand: {
    width: "fit-content",
    display: "inline-flex",
    alignItems: "center",
    gap: 8,
    color: "inherit",
    textDecoration: "none",
  },
  mark: {
    width: 25,
    height: 25,
    display: "block",
    fill: "currentColor",
    flexShrink: 0,
  },
  wordmark: {
    fontFamily: "'Days One', ui-sans-serif, system-ui, sans-serif",
    fontSize: 25,
    fontWeight: 400,
    letterSpacing: -0.5,
    lineHeight: 1,
  },
  betaLabel: {
    marginInlineStart: 4,
    paddingBlock: 1,
    paddingInline: 6,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: "currentColor",
    borderRadius: 6,
    fontSize: 11,
    fontWeight: 600,
    letterSpacing: 0.5,
    lineHeight: 1.15,
    textTransform: "uppercase",
  },
  main: {
    paddingTop: { default: 56, "@media (min-width: 720px)": 64 },
    paddingBottom: { default: 72, "@media (min-width: 720px)": 80 },
  },
  heading: {
    margin: 0,
    fontFamily: "'Days One', ui-sans-serif, system-ui, sans-serif",
    fontSize: { default: 34, "@media (min-width: 720px)": 42 },
    fontWeight: 400,
    letterSpacing: { default: -0.4, "@media (min-width: 720px)": 0 },
    lineHeight: 1.16,
  },
  prose: {
    maxWidth: 620,
    marginTop: { default: 50, "@media (min-width: 720px)": 60 },
    display: "flex",
    flexDirection: "column",
    gap: 28,
    fontSize: { default: 18, "@media (min-width: 720px)": 21 },
    fontWeight: 400,
    letterSpacing: 0,
    lineHeight: 1.43,
  },
  footer: {
    paddingTop: { default: 44, "@media (min-width: 720px)": 54 },
    paddingBottom: { default: 44, "@media (min-width: 720px)": 64 },
    borderTopWidth: 1,
    borderTopStyle: "solid",
    borderTopColor: "#dedede",
    fontFamily: "'Reddit Mono', ui-monospace, monospace",
  },
  footerGrid: {
    display: "grid",
    gridTemplateColumns: {
      default: "repeat(2, minmax(0, 1fr))",
      "@media (min-width: 720px)": "repeat(4, minmax(0, 1fr))",
    },
    columnGap: { default: 24, "@media (min-width: 720px)": 48 },
    rowGap: 44,
  },
  footerSection: {
    minWidth: 0,
  },
  footerHeading: {
    margin: 0,
    fontSize: 11,
    fontWeight: 650,
    letterSpacing: 0.7,
    lineHeight: 1.4,
    textTransform: "uppercase",
  },
  footerLinks: {
    marginTop: 18,
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    gap: 11,
  },
  footerLink: {
    color: "#555555",
    fontSize: 13,
    lineHeight: 1.35,
    textDecoration: "none",
    transitionProperty: "color",
    transitionDuration: "120ms",
    ":hover": {
      color: "#090909",
    },
    ":focus-visible": {
      outlineWidth: 2,
      outlineStyle: "solid",
      outlineColor: "#090909",
      outlineOffset: 3,
      borderRadius: 2,
    },
  },
  copyright: {
    marginTop: 56,
    marginBottom: 0,
    color: "#8a8a8a",
    fontSize: 11,
    lineHeight: 1.4,
  },
})
