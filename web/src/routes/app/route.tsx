// Layout route for the app
import { createFileRoute, Outlet } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { darkTheme } from "~/theme/themes"

import styleCssUrl from "../../styles/app.css?url"

export const Route = createFileRoute("/app")({
  component: RouteComponent,

  head: () => ({
    links: [{ rel: "stylesheet", href: styleCssUrl }],
  }),
})

function RouteComponent() {
  return (
    <div {...stylex.props(darkTheme, styles.container)}>
      <Outlet />
    </div>
  )
}

const styles = stylex.create({
  container: {
    height: "100%",
    width: "100%",
  },
})
