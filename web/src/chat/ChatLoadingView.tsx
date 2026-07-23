import * as stylex from "@stylexjs/stylex"
import { colors } from "../styles/tokens.stylex"

/** Inline macOS `SpinnerView` expressed as the route's deliberate cold-chat
 * surface. The sidebar stays mounted while the selected chat is prepared. */
export function ChatLoadingView() {
  return (
    <section aria-label="Loading chat" {...stylex.props(styles.root)}>
      <span aria-hidden="true" {...stylex.props(styles.spinner)} />
    </section>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "grid",
    placeItems: "center",
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
