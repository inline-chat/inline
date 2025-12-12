import { createFileRoute } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { LargeButton } from "~/components/largeButton/LargeButton"

export const Route = createFileRoute("/app/login/welcome")({
  component: RouteComponent,
})

function RouteComponent() {
  return (
    <>
      <div {...stylex.props(styles.logo)}>
        <img src="/logotype-white.svg" alt="Inline" width="100%" />
      </div>

      <div {...stylex.props(styles.subheading)}>
        Welcome to Inline — the next-gen work chat app designed for high-performance teams.
      </div>

      <LargeButton to="/app/login/email">Continue</LargeButton>
    </>
  )
}

const styles = stylex.create({
  topBar: {
    appRegion: "drag",
    height: 42,
    width: "100%",
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    zIndex: 100,
  },

  content: {
    height: "100%",

    display: "flex",

    flexDirection: "column",
    justifyContent: "center",
    alignItems: "center",
  },

  logo: {
    margin: "0 auto",
    textAlign: "center",
    width: 120,
    filter: "invert(1)",
  },

  subheading: {
    fontSize: 24,
    maxWidth: 500,
    margin: "0 auto",

    opacity: 0.8,
    textAlign: "center",
    fontWeight: 500,

    marginTop: 38,
    marginBottom: 38,
  },
})
