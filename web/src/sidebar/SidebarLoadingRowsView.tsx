import * as stylex from "@stylexjs/stylex"
import { InlineSkeleton } from "~/ui/InlineSkeleton"

const rows = [0.72, 0.58, 0.81] as const

/** Deliberate cold-replica state. Cached Inbox rows bypass this view entirely. */
export function SidebarLoadingRowsView() {
  return (
    <div aria-label="Opening chats" {...stylex.props(styles.root)}>
      {rows.map((width, index) => (
        <div key={width} {...stylex.props(styles.row)}>
          <InlineSkeleton width={32} height={32} radius="50%" />
          <span {...stylex.props(styles.copy)}>
            <InlineSkeleton
              width={`${Math.round(width * 100)}%`}
              height={10}
              radius={5}
            />
            <InlineSkeleton
              width={`${Math.round((width - 0.16 + index * 0.03) * 100)}%`}
              height={8}
              radius={4}
            />
          </span>
        </div>
      ))}
    </div>
  )
}

const styles = stylex.create({
  root: {
    display: "flex",
    flexDirection: "column",
    gap: 4,
    paddingInline: 17,
    paddingBlock: 4,
  },
  row: {
    height: 44,
    display: "flex",
    alignItems: "center",
    gap: 8,
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flex: 1,
    flexDirection: "column",
    gap: 6,
  },
})
