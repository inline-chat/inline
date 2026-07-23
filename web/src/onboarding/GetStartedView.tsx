import * as stylex from "@stylexjs/stylex"
import { OnboardingButton } from "./OnboardingButton"
import { Icon } from "~/ui/Icon"
import { colors } from "../styles/tokens.stylex"

export function GetStartedView({
  onPhone,
  onEmail,
}: {
  onPhone: () => void
  onEmail: () => void
}) {
  return (
    <section {...stylex.props(styles.root)}>
      <h1 {...stylex.props(styles.title)}>Get started</h1>
      <p {...stylex.props(styles.subtitle)}>Choose your sign in method</p>
      <div {...stylex.props(styles.actions)}>
        <OnboardingButton kind="secondary" onClick={onPhone}>
          <Icon name="phone" size={16} />
          <span>Continue with Phone</span>
        </OnboardingButton>
        <OnboardingButton kind="secondary" onClick={onEmail}>
          <Icon name="envelope" size={16} />
          <span>Continue with Email</span>
        </OnboardingButton>
      </div>
    </section>
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
    padding: 24,
  },
  title: {
    margin: 0,
    fontFamily: '"Red Hat Display", sans-serif',
    fontSize: 24,
    fontWeight: 750,
  },
  subtitle: {
    marginBlock: "2px 0",
    color: colors.textSecondary,
    fontSize: 16,
  },
  actions: {
    display: "flex",
    flexDirection: "column",
    gap: 8,
    marginTop: 24,
  },
})
