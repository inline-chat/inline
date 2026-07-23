import * as stylex from "@stylexjs/stylex"
import { InlineSkeleton } from "~/ui/InlineSkeleton"

const rows = [0.48, 0.62, 0.43, 0.71, 0.54, 0.66] as const

/** Stable All Chats geometry while the account replica is genuinely cold. */
export function AllChatsLoadingView() {
  return (
    <div aria-label="Opening all chats" {...stylex.props(styles.root)}>
      <InlineSkeleton width={54} height={9} radius={5} />
      {rows.map((width) => (
        <div key={width} {...stylex.props(styles.row)}>
          <InlineSkeleton width={30} height={30} radius="50%" />
          <span {...stylex.props(styles.copy)}>
            <InlineSkeleton
              width={`${Math.round(width * 100)}%`}
              height={10}
              radius={5}
            />
            <InlineSkeleton
              width={`${Math.round(Math.max(0.3, width - 0.08) * 100)}%`}
              height={9}
              radius={5}
            />
          </span>
          <InlineSkeleton width={46} height={8} radius={4} />
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
    paddingInline: 18,
    paddingBlock: 12,
  },
  row: {
    height: 50,
    display: "grid",
    gridTemplateColumns: "30px minmax(0, 1fr) 46px",
    alignItems: "center",
    gap: 9,
  },
  copy: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    gap: 7,
  },
})
