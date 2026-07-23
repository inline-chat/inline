import { Dialog } from "@base-ui/react/dialog"
import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"
import { Icon } from "./Icon"
import { InlineIconButton } from "./InlineIconButton"

/** Standard Inline modal. Feature-specific media transitions keep their own
 * geometry shell, while normal product dialogs share this focus/dismissal
 * boundary. */
export function InlineModal({
  open,
  onOpenChange,
  title,
  description,
  children,
  footer,
}: {
  open: boolean
  onOpenChange: (open: boolean) => void
  title: string
  description?: string
  children: ReactNode
  footer?: ReactNode
}) {
  return (
    <Dialog.Root open={open} onOpenChange={onOpenChange}>
      <Dialog.Portal>
        <Dialog.Backdrop {...stylex.props(styles.backdrop)} />
        <Dialog.Viewport {...stylex.props(styles.viewport)}>
          <Dialog.Popup {...stylex.props(styles.popup)}>
            <header {...stylex.props(styles.header)}>
              <span {...stylex.props(styles.heading)}>
                <Dialog.Title {...stylex.props(styles.title)}>{title}</Dialog.Title>
                {description ? (
                  <Dialog.Description {...stylex.props(styles.description)}>
                    {description}
                  </Dialog.Description>
                ) : null}
              </span>
              <Dialog.Close
                render={
                  <InlineIconButton aria-label="Close" title="Close">
                    <Icon name="xmark" size={13} />
                  </InlineIconButton>
                }
              />
            </header>
            <div {...stylex.props(styles.content)}>{children}</div>
            {footer ? <footer {...stylex.props(styles.footer)}>{footer}</footer> : null}
          </Dialog.Popup>
        </Dialog.Viewport>
      </Dialog.Portal>
    </Dialog.Root>
  )
}

const styles = stylex.create({
  backdrop: {
    position: "fixed",
    inset: 0,
    zIndex: 700,
    backgroundColor: "rgba(0,0,0,.28)",
  },
  viewport: {
    position: "fixed",
    inset: 0,
    zIndex: 701,
    display: "grid",
    placeItems: "center",
    padding: 24,
  },
  popup: {
    width: "min(440px, calc(100vw - 48px))",
    maxHeight: "min(640px, calc(100vh - 48px))",
    overflow: "hidden",
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 13,
    backgroundColor: colors.content,
    boxShadow: `0 18px 60px ${colors.shadow}`,
    color: colors.textPrimary,
    outline: "none",
  },
  header: {
    minHeight: 48,
    display: "flex",
    alignItems: "center",
    gap: 12,
    paddingBlock: 9,
    paddingInline: 14,
    borderBottomWidth: 1,
    borderBottomStyle: "solid",
    borderBottomColor: colors.separator,
  },
  heading: {
    minWidth: 0,
    display: "flex",
    flexDirection: "column",
    flex: 1,
    gap: 2,
  },
  title: {
    margin: 0,
    fontSize: 14,
    fontWeight: 600,
  },
  description: {
    margin: 0,
    color: colors.textSecondary,
    fontSize: 11,
  },
  content: {
    maxHeight: "calc(100vh - 180px)",
    overflowY: "auto",
    padding: 14,
  },
  footer: {
    minHeight: 48,
    display: "flex",
    alignItems: "center",
    justifyContent: "flex-end",
    gap: 7,
    paddingBlock: 8,
    paddingInline: 14,
    borderTopWidth: 1,
    borderTopStyle: "solid",
    borderTopColor: colors.separator,
  },
})
