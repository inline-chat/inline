import * as stylex from "@stylexjs/stylex"
import { OnboardingButton } from "./OnboardingButton"
import { colors } from "../styles/tokens.stylex"
import appIcon from "../../../apple/InlineMac/Assets.xcassets/AppIcon.imageset/AppIcon-128.png?url"

export function WelcomeView({ onContinue }: { onContinue: () => void }) {
  return (
    <section {...stylex.props(styles.root)}>
      <div {...stylex.props(styles.center)}>
        <img src={appIcon} alt="" width={96} height={96} {...stylex.props(styles.icon)} />
        <h1 {...stylex.props(styles.title)}>Welcome to Inline</h1>
        <p {...stylex.props(styles.subtitle)}>A fast, tranquil, AI native work chat app</p>
      </div>

      <div {...stylex.props(styles.bottom)}>
        <OnboardingButton onClick={onContinue}>Get Started</OnboardingButton>
        <p {...stylex.props(styles.terms)}>
          By continuing, you acknowledge that you understand and agree to the{" "}
          <a href="https://inline.chat/legal/terms">Terms of Service</a> and{" "}
          <a href="https://inline.chat/legal/privacy">Privacy Policy</a>.
        </p>
      </div>

      <a href="https://inline.chat" {...stylex.props(styles.site)}>
        inline.chat
      </a>
    </section>
  )
}

const styles = stylex.create({
  root: {
    width: "100%",
    height: "100%",
    display: "grid",
    gridTemplateRows: "1fr auto",
    position: "relative",
    padding: 24,
  },
  center: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    justifyContent: "center",
    paddingTop: 50,
  },
  icon: {
    width: 96,
    height: 96,
    objectFit: "contain",
  },
  title: {
    marginBlock: "12px 0",
    fontFamily: '"Red Hat Display", sans-serif',
    fontSize: 32,
    lineHeight: 1.2,
    fontWeight: 750,
  },
  subtitle: {
    margin: 0,
    color: colors.textSecondary,
    fontSize: 20,
    textAlign: "center",
  },
  bottom: {
    display: "flex",
    flexDirection: "column",
    alignItems: "center",
    gap: 16,
  },
  terms: {
    width: 300,
    margin: 0,
    color: colors.textTertiary,
    fontSize: 11,
    lineHeight: 1.35,
    textAlign: "center",
  },
  site: {
    position: "absolute",
    bottom: 24,
    left: 24,
    color: colors.textSecondary,
    fontSize: 11,
  },
})
