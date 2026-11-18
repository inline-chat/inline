/**
 * The top strip of a window column: the sidebar's and each pane's. One
 * component, so the desktop build can make every title area draggable in
 * one place (`data-window-drag`; Electron's `app-region: drag` goes here,
 * with `no-drag` on its controls) and reserve room for the native window
 * controls. Height is the Mac toolbar's (46 px).
 */

import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { size } from "@inline/ui/tokens/size.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"

export function TitleStrip(props: {
  /** Controls at the leading edge (the sidebar toggle). */
  leading?: ReactNode
  /** The title area: a title, or a chat header. */
  children?: ReactNode
  /** Controls at the trailing edge. */
  trailing?: ReactNode
  /** The sidebar's strip uses the sidebar color. */
  tone?: "sidebar" | "pane"
}) {
  return (
    <header data-window-drag="" {...stylex.props(styles.strip, props.tone === "sidebar" && styles.sidebar)}>
      {props.leading && <div {...stylex.props(styles.controls)}>{props.leading}</div>}
      <div {...stylex.props(styles.title)}>{props.children}</div>
      {props.trailing && <div {...stylex.props(styles.controls)}>{props.trailing}</div>}
    </header>
  )
}

/** A plain one-line title in a strip. */
export function StripTitle(props: { children: ReactNode }) {
  return (
    <h1 {...stylex.props(styles.text)}>
      <span dir="auto">{props.children}</span>
    </h1>
  )
}

const styles = stylex.create({
  strip: {
    // A size container: controls in the strip adapt to its width, so the title keeps priority (`UpdateButton`).
    containerType: "inline-size",
    display: "flex",
    alignItems: "center",
    gap: space.md,
    flexShrink: 0,
    blockSize: size.toolbar,
    paddingInline: space.lg,
    borderBlockEndWidth: 1,
    borderBlockEndStyle: "solid",
    borderBlockEndColor: color.separator,
    backgroundColor: color.windowBackground,
    userSelect: "none",
  },
  sidebar: {
    backgroundColor: color.sidebarBackground,
    borderBlockEndColor: "transparent",
  },
  controls: {
    display: "flex",
    alignItems: "center",
    gap: space.xs,
    flexShrink: 0,
  },
  title: {
    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    flexGrow: 1,
    minInlineSize: 0,
  },
  text: {
    margin: 0,
    textAlign: "start",
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeHeadline,
    fontWeight: font.weightSemibold,
  },
})
