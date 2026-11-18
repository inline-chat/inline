/**
 * Non-message rows of the timeline: the day separator, the unread line and
 * the row that stands in for older history while it loads. Each has a fixed
 * height and no vertical margins, so the timeline's compensation can count it.
 *
 * Mac: `MessageListAppKit.swift` (`DateSeparatorTableCell`: 34 pt, 12 pt
 * secondary label raised 4 pt) and `UnreadSeparatorTableCell.swift` (a 24 pt
 * band with 9 pt above and below, "Unread messages").
 */

import * as stylex from "@stylexjs/stylex"
import { Progress } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { memo } from "react"

export type DaySeparatorRowProps = {
  /** "Today", "Yesterday" or "Nov 17, 2026": `TimeFormatter.dayLabel(date).text`, prepared above the list. */
  readonly label: string
  readonly itemKey?: string
}

/** The day separator. */
export const DaySeparatorRow = memo(function DaySeparatorRow(props: DaySeparatorRowProps) {
  return (
    <div role="separator" aria-label={props.label} data-timeline-key={props.itemKey} {...stylex.props(styles.day)}>
      <span aria-hidden="true" {...stylex.props(styles.dayLabel)}>
        {props.label}
      </span>
    </div>
  )
})

export type UnreadLineRowProps = {
  readonly label?: string
  readonly itemKey?: string
}

/** The unread line: placed by the timeline above the first unread message, fixed for the visit. */
export const UnreadLineRow = memo(function UnreadLineRow(props: UnreadLineRowProps) {
  const label = props.label ?? "Unread messages"
  return (
    <div role="separator" aria-label={label} data-timeline-key={props.itemKey} {...stylex.props(styles.unread)}>
      <div aria-hidden="true" {...stylex.props(styles.unreadBand)}>
        <span {...stylex.props(styles.unreadLabel)}>{label}</span>
      </div>
    </div>
  )
})

export type LoadingOlderRowProps = {
  /** Shows the spinner. The row keeps its height either way. */
  readonly loading: boolean
  readonly itemKey?: string
}

/** Stands at the top of a window that has older history, with a reserved, fixed height. */
export const LoadingOlderRow = memo(function LoadingOlderRow(props: LoadingOlderRowProps) {
  return (
    <div data-timeline-key={props.itemKey} aria-busy={props.loading} {...stylex.props(styles.loading)}>
      {props.loading && <Progress variant="spinner" label="Loading older messages" />}
    </div>
  )
})

const styles = stylex.create({
  day: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    blockSize: "34px",
    paddingInline: "12px",
    boxSizing: "border-box",
    userSelect: "none",
  },
  dayLabel: {
    transform: "translateY(-4px)",
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
    lineHeight: "16px",
    color: color.secondaryLabel,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  unread: {
    paddingBlock: "9px",
    boxSizing: "border-box",
    blockSize: "42px",
    userSelect: "none",
  },
  unreadBand: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    blockSize: "24px",
    paddingInline: "12px",
    boxSizing: "border-box",
    backgroundColor: "light-dark(rgb(0 0 0 / 0.03), rgb(255 255 255 / 0.05))",
    // Forced colors drop the band's background; keep a line.
    borderBlockWidth: { default: 0, "@media (forced-colors: active)": "1px" },
    borderBlockStyle: "solid",
    borderBlockColor: "CanvasText",
  },
  unreadLabel: {
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
    lineHeight: "16px",
    color: color.secondaryLabel,
    whiteSpace: "nowrap",
    overflow: "hidden",
    textOverflow: "ellipsis",
  },
  loading: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    blockSize: "34px",
  },
})
