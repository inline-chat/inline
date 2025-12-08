import { createFileRoute } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { LargeButton } from "~/components/largeButton/LargeButton"
import { LargeTextField } from "~/components/largeTextField/LargeTextField"

export const Route = createFileRoute("/app/login/email")({
  component: RouteComponent,
})

function RouteComponent() {
  return (
    <>
      <div {...stylex.props(styles.subheading)}>Continue via Email</div>

      <LargeTextField placeholder="Enter your email" />

      <LargeButton to="/app/login/code">Continue</LargeButton>
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
