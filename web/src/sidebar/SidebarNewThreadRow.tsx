import * as stylex from "@stylexjs/stylex"
import { useCallback, useState } from "react"
import { colors, metrics, typography } from "../styles/tokens.stylex"
import { Icon } from "~/ui/Icon"

export function SidebarNewThreadRow({
  large = true,
  onCreate,
}: {
  large?: boolean
  onCreate: () => Promise<void>
}) {
  const [creating, setCreating] = useState(false)
  const [error, setError] = useState<string>()
  const create = useCallback(async () => {
    if (creating) return
    setCreating(true)
    setError(undefined)
    try {
      await onCreate()
    } catch (cause) {
      setError(
        cause instanceof Error
          ? cause.message
          : "Failed to create thread.",
      )
    } finally {
      setCreating(false)
    }
  }, [creating, onCreate])

  return (
    <div {...stylex.props(styles.root)}>
      <button
        type="button"
        aria-label="New Thread"
        aria-busy={creating || undefined}
        title="New Thread"
        disabled={creating}
        onClick={() => void create()}
        {...stylex.props(
          styles.row,
          !large && styles.compact,
          creating && styles.creating,
        )}
      >
        <span {...stylex.props(styles.icon)}>
          <Icon name="newThread" size={large ? 14 : 12} />
        </span>
        <span {...stylex.props(styles.title)}>
          {creating ? "Creating thread…" : "New thread"}
        </span>
      </button>
      {error ? (
        <span role="alert" title={error} {...stylex.props(styles.error)}>
          {error}
        </span>
      ) : null}
    </div>
  )
}

const styles = stylex.create({
  root: {
    width: `calc(100% - ${metrics.sidebarOuterInset} * 2)`,
    marginInline: metrics.sidebarOuterInset,
  },
  row: {
    width: "100%",
    height: metrics.sidebarRowHeight,
    display: "grid",
    gridTemplateColumns: `${metrics.sidebarIconSize} minmax(0, 1fr)`,
    alignItems: "center",
    gap: 8,
    paddingInline: metrics.sidebarInnerInset,
    borderRadius: metrics.sidebarRadius,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    textAlign: "left",
  },
  creating: {
    opacity: 0.65,
  },
  compact: {
    height: 30,
    gridTemplateColumns: "22px minmax(0, 1fr)",
  },
  icon: {
    width: metrics.sidebarIconSize,
    height: metrics.sidebarIconSize,
    display: "grid",
    placeItems: "center",
    borderRadius: "50%",
    backgroundColor: "light-dark(rgba(0,0,0,.04), rgba(255,255,255,.06))",
  },
  title: {
    overflow: "hidden",
    fontSize: typography.sidebarTitle,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
  error: {
    display: "block",
    overflow: "hidden",
    marginBlock: "-2px 5px",
    paddingInline: `calc(${metrics.sidebarInnerInset} + ${metrics.sidebarIconSize} + 8px)`,
    color: colors.destructive,
    fontSize: 10,
    lineHeight: 1.2,
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
