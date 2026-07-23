import * as stylex from "@stylexjs/stylex"
import { RoutePlaceholderView } from "~/app/RoutePlaceholderView"
import { colors } from "../../styles/tokens.stylex"

const reloadInline = () => window.location.reload()

export function InlineCoreRecoveryView({
  failureCode,
  failureMessage,
  onReload = reloadInline,
}: {
  failureCode?: string
  failureMessage?: string
  onReload?: () => void
}) {
  return (
    <div
      role="alert"
      data-inline-core-failure-code={failureCode}
      data-inline-core-failure-message={failureMessage}
      {...stylex.props(styles.root)}
    >
      <RoutePlaceholderView
        title="Inline couldn’t continue. Please reload the app."
        actionTitle="Reload Inline"
        onAction={onReload}
      />
    </div>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    backgroundColor: colors.content,
  },
})
