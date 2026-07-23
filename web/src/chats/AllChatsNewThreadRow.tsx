import * as stylex from "@stylexjs/stylex"
import { useState } from "react"
import { Icon } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"

export function AllChatsNewThreadRow({
  onCreate,
}: {
  onCreate: () => Promise<void>
}) {
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string>()

  const create = async () => {
    if (creating) return
    setCreating(true)
    setError(undefined)
    try {
      await onCreate()
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Could not create a new thread.",
      )
    } finally {
      setCreating(false)
    }
  }

  return (
    <div {...stylex.props(styles.root)}>
      <button
        type="button"
        aria-label="New Thread"
        aria-busy={creating || undefined}
        disabled={creating}
        onClick={() => void create()}
        {...stylex.props(styles.row)}
      >
        <span {...stylex.props(styles.icon)}>
          <Icon name="newThread" size={15} />
        </span>
        <span>{creating ? "Creating thread…" : "New thread"}</span>
      </button>
      {error ? (
        <span role="alert" {...stylex.props(styles.error)}>
          {error}
        </span>
      ) : null}
    </div>
  )
}

const styles = stylex.create({
  root: {
    width: "calc(100% - 10px)",
    marginInline: 5,
  },
  row: {
    width: "100%",
    height: 46,
    display: "grid",
    gridTemplateColumns: "30px minmax(0, 1fr)",
    alignItems: "center",
    gap: 9,
    paddingInline: 8,
    borderRadius: 6,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    fontSize: 13,
    textAlign: "left",
    ":disabled": {
      opacity: 0.6,
    },
  },
  icon: {
    width: 30,
    height: 30,
    display: "grid",
    placeItems: "center",
    borderRadius: "50%",
    backgroundColor:
      "light-dark(rgba(0,0,0,.04), rgba(255,255,255,.06))",
  },
  error: {
    display: "block",
    marginBlock: "-2px 5px",
    paddingInlineStart: 47,
    color: colors.destructive,
    fontSize: 10,
  },
})
