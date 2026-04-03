import * as stylex from "@stylexjs/stylex"

export const PageContainer = ({ children }: { children: React.ReactNode }) => {
  return <div {...stylex.props(styles.root)}>{children}</div>
}

export const PageLongFormContent = ({ children }: { children: React.ReactNode }) => {
  return <div {...stylex.props(styles.content)}>{children}</div>
}

export const PageHeader = ({ title, subtitle }: { title: string; subtitle?: string }) => {
  return (
    <div {...stylex.props(styles.header)}>
      <h1 {...stylex.props(styles.title)}>{title}</h1>
      {subtitle && <h2 {...stylex.props(styles.subtitle)}>{subtitle}</h2>}
    </div>
  )
}

const styles = stylex.create({
  root: {
    margin: "0 auto",
    paddingLeft: {
      default: "0",
      "@media (max-width: 1000px)": "12px",
    },

    paddingRight: {
      default: "0",
      "@media (max-width: 1000px)": "12px",
    },

    overflow: "hidden",
    maxWidth: 1100,
    width: "100%",
  },

  content: {
    width: "100%",
    maxWidth: 800,
    marginBottom: 32,
  },

  header: {
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-start",
    justifyContent: "center",
  },

  title: {
    fontSize: 28,
    fontWeight: "bold",
    marginTop: 16,
  },

  subtitle: {
    fontSize: 22,
    fontWeight: "normal",
  },
})
