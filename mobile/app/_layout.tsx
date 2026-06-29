import { useEffect } from "react"
import { Stack } from "expo-router"
import { StatusBar } from "expo-status-bar"

import { installNotificationListeners } from "@/notifications/events"
import { initSentry, wrapWithSentry } from "@/observability/sentry"

initSentry()

function RootLayout() {
  useEffect(() => {
    return installNotificationListeners()
  }, [])

  return (
    <>
      <Stack
        screenOptions={{
          headerShown: false,
          animation: "fade",
        }}
      />
      <StatusBar style="auto" />
    </>
  )
}

export default wrapWithSentry(RootLayout)
