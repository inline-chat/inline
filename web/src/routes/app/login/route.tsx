import { createFileRoute, Link, Outlet, useNavigate, useRouter } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useIsLoggedIn } from "~/store/auth"

export const Route = createFileRoute("/app/login")({
  component: RouteComponent,
})

function RouteComponent() {
  return (
    <>
      <div {...stylex.props(styles.content)}>
        <Outlet />
      </div>
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
})
