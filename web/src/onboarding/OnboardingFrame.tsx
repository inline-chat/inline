import * as stylex from "@stylexjs/stylex"
import type { ReactNode } from "react"
import { Icon } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"

export function OnboardingFrame({
  children,
  canGoBack,
  onBack,
}: {
  children: ReactNode
  canGoBack: boolean
  onBack: () => void
}) {
  return (
    <main {...stylex.props(styles.root)}>
      <div data-inline-onboarding-topbar {...stylex.props(styles.topbar)}>
        {canGoBack ? (
          <button type="button" aria-label="Back" onClick={onBack} {...stylex.props(styles.back)}>
            <Icon name="back" size={18} />
          </button>
        ) : null}
      </div>
      {children}
    </main>
  )
}

export function OnboardingForm({
  icon,
  title,
  description,
  children,
}: {
  icon: Parameters<typeof Icon>[0]["name"]
  title: string
  description?: string
  children: ReactNode
}) {
  return (
    <section {...stylex.props(styles.form)}>
      <Icon name={icon} size={34} />
      <h1 {...stylex.props(styles.formTitle)}>{title}</h1>
      {description ? <p {...stylex.props(styles.description)}>{description}</p> : null}
      {children}
    </section>
  )
}

export function FormError({ message }: { message?: string }) {
  return message ? (
    <p role="alert" {...stylex.props(styles.error)}>
      {message}
    </p>
  ) : null
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    position: "relative",
    overflow: "hidden",
    backgroundColor: colors.window,
    backgroundImage:
      "linear-gradient(145deg, light-dark(rgba(255,255,255,.72), rgba(255,255,255,.035)), transparent 58%)",
    color: colors.textPrimary,
  },
  topbar: {
    height: 46,
    position: "absolute",
    insetInline: 0,
    top: 0,
    display: "flex",
    alignItems: "center",
    paddingInline: 12,
    WebkitAppRegion: "drag",
  },
  back: {
    width: 28,
    height: 28,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderRadius: 7,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    WebkitAppRegion: "no-drag",
  },
  form: {
    width: "100%",
    height: "100%",
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    padding: 24,
  },
  formTitle: {
    marginBlock: "8px 0",
    fontSize: 21,
    lineHeight: 1.25,
    fontWeight: 600,
  },
  description: {
    width: 320,
    marginBlock: "4px 0",
    color: colors.textSecondary,
    fontSize: 13,
    lineHeight: 1.35,
    textAlign: "center",
  },
  error: {
    width: 260,
    marginBlock: "0 8px",
    color: colors.destructive,
    fontSize: 13,
    lineHeight: 1.35,
    textAlign: "center",
  },
})
