import { useCallback, useEffect, useRef, useState } from "react"
import { ActivityIndicator, Alert, StyleSheet, Text, View } from "react-native"
import { SafeAreaView } from "react-native-safe-area-context"

import { clearSession, loadSession, type AuthSession } from "@/auth/session"
import { HomeScreen } from "@/components/HomeScreen"
import { LoginScreen } from "@/components/LoginScreen"
import { NativeButton } from "@/components/NativeButton"
import { clearSentryUser, identifySentryUser, markAppLoaded } from "@/observability/sentry"
import { colors } from "@/theme/colors"

export default function Index() {
  const [loading, setLoading] = useState(true)
  const [session, setSession] = useState<AuthSession | null>(null)
  const [loadFailed, setLoadFailed] = useState(false)
  const loadGeneration = useRef(0)

  const reload = useCallback(async () => {
    const generation = ++loadGeneration.current
    setLoading(true)
    setLoadFailed(false)
    try {
      const nextSession = await loadSession()
      if (generation === loadGeneration.current) setSession(nextSession)
    } catch {
      if (generation === loadGeneration.current) setLoadFailed(true)
    } finally {
      if (generation === loadGeneration.current) setLoading(false)
    }
  }, [])

  const recoverSession = () => {
    Alert.alert("Clear saved session?", "This removes the saved account from this device. You will need to sign in again.", [
      { text: "Cancel", style: "cancel" },
      { text: "Clear saved session", style: "destructive", onPress: async () => {
        const generation = ++loadGeneration.current
        setLoading(true)
        try {
          await clearSession()
          if (generation !== loadGeneration.current) return
          setSession(null)
          setLoadFailed(false)
        } catch {
          Alert.alert("Could not clear session", "Secure storage is unavailable. Please try again.")
        } finally {
          if (generation === loadGeneration.current) setLoading(false)
        }
      } },
    ])
  }

  useEffect(() => {
    let active = true
    const generation = ++loadGeneration.current
    loadSession().then(
      (nextSession) => {
        if (!active || generation !== loadGeneration.current) return
        setSession(nextSession)
        setLoading(false)
      },
      () => {
        if (!active || generation !== loadGeneration.current) return
        setLoadFailed(true)
        setLoading(false)
      },
    )

    return () => {
      active = false
      loadGeneration.current++
    }
  }, [])

  useEffect(() => {
    if (loadFailed) {
      clearSentryUser()
      return
    }
    if (loading) return
    if (session) {
      identifySentryUser(session)
    } else {
      clearSentryUser()
    }
    markAppLoaded()
  }, [loading, loadFailed, session])

  if (loading) {
    return (
      <SafeAreaView style={styles.screen}>
        <View style={styles.center}>
          <ActivityIndicator color={colors.accent} />
        </View>
      </SafeAreaView>
    )
  }

  if (loadFailed) {
    return (
      <SafeAreaView style={styles.screen}>
        <View style={styles.center}>
          <Text>Could not load your saved session. Please try again.</Text>
          <NativeButton title="Try again" onPress={() => void reload()} />
          <NativeButton title="Clear saved session" tone="danger" onPress={recoverSession} />
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
