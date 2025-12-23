import { createFileRoute, Link, Navigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { Fonts } from "~/theme/fonts"
import { colors } from "~/theme/tokens.stylex"
import { LargeButton } from "~/components/form/LargeButton"
import { useState } from "react"
import { useCurrentUserId, useHasHydrated, useIsLoggedIn } from "~/store/auth"

export const Route = createFileRoute("/app/")({
  component: App,

  head: () => ({
    meta: [
      {
        title: "Inline",
      },
    ],
  }),
})

function App() {
  const isLoggedIn = useIsLoggedIn()
  const hasHydrated = useHasHydrated()
  const currentUserId = useCurrentUserId()

  if (!hasHydrated) {
    return null
  }

  if (!isLoggedIn) {
    return <Navigate to="/app/login/welcome" />
  }

  return <div>Logged in as user {currentUserId}</div>
}
