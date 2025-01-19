import * as stylex from "@stylexjs/stylex"
import { PageContainer } from "./Page"

export const PageMenu = () => {
  return (
    <nav {...stylex.props(styles.menu)}>
      <PageContainer>
        <div {...stylex.props(styles.menuContent)}>
          <a href="/" {...stylex.props(styles.brandLink)}>
            <div {...stylex.props(styles.brandContainer)}>
              <img src="/inline-logo-nav.png" alt="Inline" {...stylex.props(styles.icon)} />
              <div {...stylex.props(styles.brand)}>inline</div>
            </div>
          </a>
          <div {...stylex.props(styles.links)}>
            <a href="/" {...stylex.props(styles.link)}>
              Join Waitlist
            </a>
          </div>
        </div>
      </PageContainer>
      <div {...stylex.props(styles.separator)} />
    </nav>
  )
}

const styles = stylex.create({
  menu: {
    width: "100%",
    position: "relative",
    marginBottom: 32,
  },
  menuContent: {
    paddingTop: 12,
    paddingBottom: 12,
    display: "flex",
    justifyContent: "space-between",
    alignItems: "center",
  },
  brandContainer: {
    display: "flex",
    alignItems: "center",
    gap: "8px",
  },
  icon: {
    width: 32,
    height: 32,
  },
  brandLink: {
    textDecoration: "none",
    color: "inherit",
  },
  brand: {
    fontFamily: '"Red Hat Display", sans-serif',
    fontSize: "18px",
    fontWeight: "700",
    opacity: {
      default: "0.9",
      ":hover": "1",
    },
    userSelect: "none",
    cursor: "default",
  },
  links: {
    display: "flex",
    alignItems: "center",
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
  separator: {
    position: "absolute",
    bottom: 0,
    left: 0,
    right: 0,
    height: "1px",
    backgroundColor: "rgba(0, 0, 0, 0.1)",
  },
})
