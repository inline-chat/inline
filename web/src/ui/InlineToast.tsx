import { Toast } from "@base-ui/react/toast"
import * as stylex from "@stylexjs/stylex"
import { createContext, useContext, useMemo, type ReactNode } from "react"
import { colors } from "../styles/tokens.stylex"
import { Icon } from "./Icon"

type InlineToastKind = "success" | "error"

type InlineToastValue = {
  show: (title: string, kind?: InlineToastKind) => void
}

const InlineToastContext = createContext<InlineToastValue | undefined>(undefined)

function InlineToastContent({ children }: { children: ReactNode }) {
  const manager = Toast.useToastManager()
  const value = useMemo<InlineToastValue>(
    () => ({
      show: (title, kind = "success") => {
        manager.add({
          title,
          type: kind,
          timeout: kind === "error" ? 5_000 : 2_500,
          priority: kind === "error" ? "high" : "low",
        })
      },
    }),
    [manager],
  )

  return (
    <InlineToastContext.Provider value={value}>
      {children}
      <Toast.Portal>
        <Toast.Viewport {...stylex.props(styles.viewport)}>
          {manager.toasts.map((toast) => (
            <Toast.Root
              key={toast.id}
              toast={toast}
              {...stylex.props(styles.root, toast.type === "error" && styles.error)}
            >
              <Toast.Content {...stylex.props(styles.content)}>
                <Toast.Title {...stylex.props(styles.title)} />
              </Toast.Content>
              <Toast.Close aria-label="Dismiss" {...stylex.props(styles.close)}>
                <Icon name="xmark" size={11} />
              </Toast.Close>
            </Toast.Root>
          ))}
        </Toast.Viewport>
      </Toast.Portal>
    </InlineToastContext.Provider>
  )
}

export function InlineToastProvider({ children }: { children: ReactNode }) {
  return (
    <Toast.Provider limit={3} timeout={3_000}>
      <InlineToastContent>{children}</InlineToastContent>
    </Toast.Provider>
  )
}

export function useInlineToast() {
  const value = useContext(InlineToastContext)
  if (!value) throw new Error("useInlineToast must be used inside InlineToastProvider")
  return value
}

const styles = stylex.create({
  viewport: {
    width: 340,
    maxWidth: "calc(100vw - 24px)",
    position: "fixed",
    right: 12,
    bottom: 12,
    zIndex: 300,
    display: "flex",
    flexDirection: "column",
    alignItems: "flex-end",
    gap: 7,
    outline: "none",
    pointerEvents: "none",
  },
  root: {
    minHeight: 38,
    maxWidth: 320,
    display: "flex",
    alignItems: "center",
    gap: 10,
    paddingBlock: 8,
    paddingInline: 12,
    borderWidth: 1,
    borderStyle: "solid",
    borderColor: colors.controlOutline,
    borderRadius: 10,
    backgroundColor: colors.content,
    boxShadow: `0 10px 30px ${colors.shadow}`,
    color: colors.textPrimary,
    pointerEvents: "auto",
  },
  error: {
    borderColor: "color-mix(in srgb, currentColor 18%, transparent)",
    color: colors.destructive,
  },
  content: {
    minWidth: 0,
    flex: 1,
  },
  title: {
    margin: 0,
    color: "inherit",
    fontSize: 12,
    fontWeight: 500,
    lineHeight: 1.3,
  },
  close: {
    width: 22,
    height: 22,
    display: "grid",
    placeItems: "center",
    flexShrink: 0,
    padding: 0,
    borderWidth: 0,
    borderRadius: 6,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: "inherit",
  },
})
