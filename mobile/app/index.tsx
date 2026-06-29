import { useCallback, useEffect, useState } from "react"
import { ActivityIndicator, StyleSheet, View } from "react-native"
import { SafeAreaView } from "react-native-safe-area-context"

import { loadSession, type AuthSession } from "@/auth/session"
import { HomeScreen } from "@/components/HomeScreen"
import { LoginScreen } from "@/components/LoginScreen"
import { clearSentryUser, identifySentryUser, markAppLoaded } from "@/observability/sentry"
import { colors } from "@/theme/colors"

export default function Index() {
  const [loading, setLoading] = useState(true)
  const [session, setSession] = useState<AuthSession | null>(null)

  const reload = useCallback(async () => {
    setLoading(true)
    setSession(await loadSession())
    setLoading(false)
  }, [])

  useEffect(() => {
    let active = true
    loadSession().then((nextSession) => {
      if (!active) return
      setSession(nextSession)
      setLoading(false)
    })

    return () => {
      active = false
    }
  }, [])

  useEffect(() => {
    if (loading) return
    if (session) {
      identifySentryUser(session)
    } else {
      clearSentryUser()
    }
    markAppLoaded()
  }, [loading, session])

  if (loading) {
    return (
      <SafeAreaView style={styles.screen}>
        <View style={styles.center}>
          <ActivityIndicator color={colors.accent} />
        </View>
      </SafeAreaView>
    )
  }

  return (
    <SafeAreaView style={styles.screen}>
      {session ? <HomeScreen session={session} onSessionChanged={reload} /> : <LoginScreen onLogin={reload} />}
    </SafeAreaView>
  )
}

const styles = StyleSheet.create({
  screen: {
    flex: 1,
    backgroundColor: colors.background,
  },
  center: {
    flex: 1,
    alignItems: "center",
    justifyContent: "center",
  },
})
