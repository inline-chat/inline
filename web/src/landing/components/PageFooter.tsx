import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { PageContainer } from "./Page"

export const PageFooter = () => {
  const [isCopied, setIsCopied] = useState(false)

  return (
    <footer {...stylex.props(styles.footer)}>
      <PageContainer>
        <div {...stylex.props(styles.footerContent)}>
          <div {...stylex.props(styles.brandContainer)}>
            <div {...stylex.props(styles.brand)}>inline</div>
            <div {...stylex.props(styles.description)}>
              Inline is a messaging app for teams and communities that focuses on speed and ease of use.
            </div>
          </div>
          <div {...stylex.props(styles.links)}>
            <button
              onClick={() => {
                navigator.clipboard.writeText("hey@inline.chat")
                setIsCopied(true)
                setTimeout(() => {
                  setIsCopied(false)
                }, 1000)
              }}
              {...stylex.props(styles.emailLink)}
            >
              {isCopied ? "copied to clipboard" : "hey@inline.chat"}
            </button>
            <a href="/waitlist" {...stylex.props(styles.link)}>
              Join Waitlist
            </a>
            <a href="https://github.com/inline-chat" {...stylex.props(styles.link)}>
              GitHub
            </a>
            <a href="https://x.com/inline_chat" {...stylex.props(styles.link)}>
              X (Twitter)
            </a>
            <a href="https://status.inline.chat" {...stylex.props(styles.link)}>
              Status
            </a>
          </div>
        </div>
      </PageContainer>
    </footer>
  )
}

const styles = stylex.create({
  footer: {
    width: "100%",
    borderTop: "1px solid rgba(0, 0, 0, 0.1)",
  },
  footerContent: {
    // maxWidth: "1200px",
    // margin: "0 auto",
    paddingBottom: 24,
    paddingTop: 24,
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
  },
  brandContainer: {
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    flexShrink: 1,
    flexGrow: 1,
  },
  brand: {
    fontFamily: '"Red Hat Display", sans-serif',
    fontSize: "18px",
    fontWeight: "700",
    opacity: {
      default: "0.9",
      ":hover": "1",
    },
  },
  links: {
    display: "flex",
    alignItems: "center",
    gap: "24px",
  },
  link: {
    fontWeight: "400",
    opacity: {
      default: "0.8",
      ":hover": "1",
    },
    fontSize: "14px",
    textDecoration: "none",
    transition: "color 0.15s ease-out",
  },
  emailLink: {
    fontWeight: "400",
    opacity: {
      default: "0.4",
      ":hover": "1",
    },
    fontSize: "14px",
    textDecoration: "none",
    transition: "color 0.15s ease-out",
    cursor: "pointer",
    background: "none",
    border: "none",
    padding: 0,
    color: "inherit",
  },
  description: {
    fontSize: "14px",
    opacity: "0.6",
    marginTop: "4px",
    maxWidth: "400px",
  },
})
