import * as stylex from "@stylexjs/stylex"
import { colors } from "~/theme/tokens.stylex"
import { FileRouteTypes } from "~/routeTree.gen"
import { Link } from "@tanstack/react-router"

type LargeButtonProps =
  | ({ to: React.ComponentProps<typeof Link>["to"] } & Omit<React.ComponentProps<typeof Link>, "to">) // link variant
  | React.ButtonHTMLAttributes<HTMLButtonElement> // button variant

export const LargeButton = (props: LargeButtonProps) => {
  if ("to" in props) {
    return <Link {...props} {...stylex.props(styles.largeButton)} />
  }

  return <button {...stylex.props(styles.largeButton)} {...props} />
}

const styles = stylex.create({
  largeButton: {
    backgroundColor: colors.accent,
    color: colors.primaryText,
    height: 40,
    lineHeight: "40px",
    borderRadius: 14,
    paddingLeft: 32,
    paddingRight: 32,
    fontSize: 18,
    fontWeight: 500,
    cursor: "pointer",

    ":hover": {
      backgroundColor: colors.accent,
      opacity: 0.9,
    },
    ":active": {
      backgroundColor: colors.accent,
      opacity: 1,
    },
  },
})
