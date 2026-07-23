import * as stylex from "@stylexjs/stylex"
import { colors, metrics } from "../styles/tokens.stylex"

export function AppBootView() {
  return (
    <div aria-label="Opening Inline" {...stylex.props(styles.window)}>
      <aside {...stylex.props(styles.sidebar)}>
        <div {...stylex.props(styles.topBar)} />
        <div {...stylex.props(styles.sidebarRows)}>
          <span {...stylex.props(styles.sidebarRow, styles.sidebarRowWide)} />
          <span {...stylex.props(styles.separator)} />
          <span {...stylex.props(styles.sidebarRow)} />
          <span {...stylex.props(styles.sidebarRow, styles.sidebarRowShort)} />
        </div>
      </aside>
      <main {...stylex.props(styles.detail)}>
        <span aria-hidden="true" {...stylex.props(styles.spinner)} />
      </main>
    </div>
  )
}

const styles = stylex.create({
  window: {
    width: "100%",
    height: "100%",
    display: "grid",
    gridTemplateColumns: `minmax(${metrics.sidebarMinWidth}, ${metrics.sidebarIdealWidth}) minmax(315px, 1fr)`,
    overflow: "hidden",
    backgroundColor: colors.window,
  },
  sidebar: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    backgroundColor: colors.sidebar,
  },
  topBar: {
    height: metrics.toolbarHeight,
    flexShrink: 0,
  },
  sidebarRows: {
    paddingInline: 17,
    display: "flex",
    flexDirection: "column",
    gap: 12,
  },
  sidebarRow: {
    width: "68%",
    height: 11,
    borderRadius: 6,
    backgroundColor: colors.skeleton,
  },
  sidebarRowWide: {
    width: "82%",
  },
  sidebarRowShort: {
    width: "54%",
  },
  separator: {
    height: 1,
    marginBlock: 1,
    backgroundColor: colors.separator,
  },
  detail: {
    minWidth: 315,
    minHeight: 0,
    display: "grid",
    placeItems: "center",
    borderLeftWidth: 1,
    borderLeftStyle: "solid",
    borderLeftColor: colors.separator,
    backgroundColor: colors.content,
  },
  spinner: {
    width: 14,
    height: 14,
    borderWidth: 2,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderTopColor: colors.textSecondary,
    borderRadius: "50%",
    animationName: stylex.keyframes({
      to: { transform: "rotate(360deg)" },
    }),
    animationDuration: "0.8s",
    animationTimingFunction: "linear",
    animationIterationCount: "infinite",
  },
})
