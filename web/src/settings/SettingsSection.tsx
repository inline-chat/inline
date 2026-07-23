import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"

export function SettingsPage({
  title,
  children,
}: {
  title: string
  children: ReactNode
}) {
  return (
    <div {...stylex.props(styles.page)}>
      <h2 {...stylex.props(styles.pageTitle)}>{title}</h2>
      {children}
    </div>
  )
}

export function SettingsSection({
  title,
  children,
}: {
  title?: string
  children: ReactNode
}) {
  return (
    <section {...stylex.props(styles.section)}>
      {title ? <h3 {...stylex.props(styles.sectionTitle)}>{title}</h3> : null}
      <div {...stylex.props(styles.surface)}>{children}</div>
    </section>
  )
}

export function SettingsRow({
  title,
  detail,
  control,
}: {
  title: string
  detail?: string
  control?: ReactNode
}) {
  return (
    <div {...stylex.props(styles.row)}>
      <span {...stylex.props(styles.copy)}>
        <span {...stylex.props(styles.rowTitle)}>{title}</span>
        {detail ? <span {...stylex.props(styles.detail)}>{detail}</span> : null}
      </span>
      {control ? <span {...stylex.props(styles.control)}>{control}</span> : null}
    </div>
  )
}

const styles = stylex.create({
  page: {
    width: "min(620px, calc(100% - 40px))",
    marginInline: "auto",
    paddingBlock: "28px 48px",
  },
  pageTitle: {
    marginBlock: "0 24px",
    fontSize: 20,
    fontWeight: 650,
  },
  section: {
    marginBottom: 26,
  },
  sectionTitle: {
    marginBlock: "0 7px",
    marginInline: 4,
    color: colors.textSecondary,
    fontSize: 11,
    fontWeight: 600,
  },
  surface: {
    overflow: "hidden",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.separator,
    borderRadius: 10,
    backgroundColor: colors.replyPane,
  },
  row: {
    minHeight: 52,
    display: "flex",
    alignItems: "center",
    gap: 20,
    paddingBlock: 9,
    paddingInline: 13,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
    ":last-child": {
      borderBottomWidth: 0,
    },
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    flex: 1,
    gap: 2,
  },
  rowTitle: {
    fontSize: 13,
    fontWeight: 500,
  },
  detail: {
    color: colors.textSecondary,
    fontSize: 11,
    lineHeight: 1.35,
  },
  control: {
    flexShrink: 0,
  },
})
