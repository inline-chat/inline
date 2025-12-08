import { createFileRoute, Link, Navigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { Fonts } from "~/theme/fonts"
import { colors } from "~/theme/tokens.stylex"
import { LargeButton } from "~/components/largeButton/LargeButton"
import { useState } from "react"
import { useAuthStore, useIsLoggedIn } from "~/store/auth"

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

  if (!isLoggedIn) {
    return <Navigate to="/app/login/welcome" />
  }

  return <></>
}
