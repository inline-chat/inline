import * as stylex from "@stylexjs/stylex"
import { PageContainer } from "./Page"
import { SUPPORT_EMAIL, emailValue } from "~/lib/email"

const AVAILABILITY = "Available for macOS and iOS in alpha • Web coming soon • Open-source."
const COPYRIGHT = "© 2026 Inline Chat"

export const PageFooter = () => {
  const email = emailValue(SUPPORT_EMAIL)

  return (
    <footer {...stylex.props(styles.footer)}>
      <PageContainer>
        <div {...stylex.props(styles.footerContent)}>
          <div>{AVAILABILITY}</div>
          <div {...stylex.props(styles.links)}>
            <a href="/waitlist" {...stylex.props(styles.link)}>
              Join Waitlist
            </a>
            <a href="/download" {...stylex.props(styles.link)}>
              Downloads
            </a>
            <a href="/docs" {...stylex.props(styles.link)}>
              Docs
            </a>
            <a href="/legal" {...stylex.props(styles.link)}>
              Legal
            </a>
            <a href="https://github.com/inline-chat" {...stylex.props(styles.link)}>
              GitHub
            </a>
            <a href="https://github.com/inline-chat/inline/blob/main/SUPPORT.md" {...stylex.props(styles.link)}>
              Sponsor
            </a>
            <a href="https://x.com/inline_chat" {...stylex.props(styles.link)}>
              X
            </a>
            <a href="https://status.inline.chat" {...stylex.props(styles.link)}>
              Status
            </a>
            <a href={`mailto:${email}`} target="_blank" rel="noopener noreferrer" {...stylex.props(styles.link)}>
              {email}
            </a>
          </div>
          <div {...stylex.props(styles.copyRight)}>{COPYRIGHT}</div>
        </div>
      </PageContainer>
    </footer>
  )
}

const styles = stylex.create({
  footer: {
    width: "100%",
  },
  footerContent: {
    // maxWidth: "1200px",
    // margin: "0 auto",
    paddingBottom: 60,
    paddingTop: 24,
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    alignItems: "center",
    textAlign: "center",
    color: {
      default: "rgba(44, 54, 66, 0.8)",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.8)",
    },
    fontFamily: '"Reddit Mono", monospace',
    fontSize: 14,
  },
  links: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexWrap: "wrap",
    gap: "8px",
    marginTop: 8,
  },
  link: {
    fontWeight: "400",
    opacity: {
      default: "0.8",
      ":hover": "1",
    },
    fontSize: "14px",
    textDecoration: "none",
    padding: "4px 8px",
    transition: "color 0.12s ease-out",
  },
  copyRight: {
    marginTop: 8,
    opacity: 0.5,
  },
})
