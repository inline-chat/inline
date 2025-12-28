import { createFileRoute, Link, Navigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { Fonts } from "~/theme/fonts"
import { colors } from "~/theme/tokens.stylex"
import { LargeButton } from "~/components/form/LargeButton"
import { useEffect, useState } from "react"
import { useCurrentUserId, useHasHydrated, useIsLoggedIn } from "@inline/client"
import { MainSplitView } from "~/components/mainSplitView/MainSplitView"
import { Sidebar } from "~/components/sidebar/Sidebar"

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

  let [ready, setReady] = useState(false)
  useEffect(() => {
    if (typeof window === "undefined") return
    if (hasHydrated) {
      setReady(true)
    }
  }, [hasHydrated])

  if (!ready) {
    return <div>Loading...</div>
  }

  if (typeof window !== "undefined" && !isLoggedIn) {
    return <Navigate to="/app/login/welcome" />
  }

  return (
    <MainSplitView>
      <MainSplitView.Sidebar>
        <Sidebar />
      </MainSplitView.Sidebar>
      <MainSplitView.Content>Logged in as user {currentUserId}</MainSplitView.Content>
    </MainSplitView>
  )
}
