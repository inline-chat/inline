import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

export const inlineRouteErrorTitle = (
  error: unknown,
  fallback: string,
) =>
  error instanceof Error && error.message.trim()
    ? error.message
    : fallback

export function RoutePlaceholderView({
  title,
  actionTitle,
  onAction,
}: {
  title: string
  actionTitle?: string
  onAction?: () => void
}) {
  return (
    <main
      data-inline-route-placeholder="true"
      {...stylex.props(styles.root)}
    >
      <div aria-hidden="true" {...stylex.props(styles.symbol)}>
        !
      </div>
      <h1 {...stylex.props(styles.title)}>{title}</h1>
      {actionTitle && onAction ? (
        <button type="button" onClick={onAction} {...stylex.props(styles.action)}>
          {actionTitle}
        </button>
      ) : null}
    </main>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    gap: 8,
    backgroundColor: colors.content,
    color: colors.textPrimary,
  },
  symbol: {
    width: 28,
    height: 28,
    display: "grid",
    placeItems: "center",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.textTertiary,
    borderRadius: "50%",
    color: colors.textSecondary,
    fontSize: 16,
    fontWeight: 600,
  },
  title: {
    maxWidth: 320,
    margin: 0,
    color: colors.textSecondary,
    fontSize: 13,
    fontWeight: 500,
    textAlign: "center",
  },
  action: {
    height: 28,
    marginTop: 2,
    paddingInline: 12,
    borderRadius: 7,
    backgroundColor: {
      default: colors.control,
      ":hover": colors.controlHover,
    },
    color: colors.textPrimary,
    boxShadow: `inset 0 0 0 1px ${colors.controlOutline}`,
    fontSize: 12,
  },
})
