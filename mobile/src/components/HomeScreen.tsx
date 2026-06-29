import { MaterialIcons } from "@expo/vector-icons"
import { useEffect, useMemo, useState } from "react"
import { Alert, Linking, ScrollView, StyleSheet, Switch, Text, View } from "react-native"

import { clearSession, type AuthSession } from "@/auth/session"
import { NativeButton } from "@/components/NativeButton"
import { Row, Section } from "@/components/Section"
import { registerForInlinePush, type PushRegistrationState } from "@/notifications/register"
import { colors } from "@/theme/colors"

type HomeScreenProps = {
  session: AuthSession
  onSessionChanged: () => void
}

export function HomeScreen({ session, onSessionChanged }: HomeScreenProps) {
  const [pushState, setPushState] = useState<PushRegistrationState | null>(null)
  const [autoRegister, setAutoRegister] = useState(true)

  const displayName = useMemo(() => {
    const user = session.user
    const name = [user?.firstName, user?.lastName].filter(Boolean).join(" ")
    return name || user?.username || user?.email || `User ${session.userId}`
  }, [session])

  useEffect(() => {
    if (!autoRegister) return
    let active = true
    registerForInlinePush(session.token).then((state) => {
      if (active) setPushState(state)
    })
    return () => {
      active = false
    }
  }, [autoRegister, session.token])

  async function signOut() {
    await clearSession()
    onSessionChanged()
  }

  async function retryPush() {
    setPushState(null)
    setPushState(await registerForInlinePush(session.token))
  }

  async function openSettings() {
    await Linking.openSettings()
  }

  const pushText = pushStateText(pushState)
  const canOpenSettings = pushState?.status === "skipped" && pushState.action === "open_settings"

  return (
    <ScrollView contentContainerStyle={styles.content}>
      <View style={styles.top}>
        <View style={styles.avatar}>
          <MaterialIcons name="person" size={26} color={colors.accent} />
        </View>
        <View style={styles.topText}>
          <Text style={styles.title}>Inline</Text>
          <Text style={styles.subtitle}>{displayName}</Text>
        </View>
      </View>

      <Section title="Account">
        <Row label="Signed in" value={displayName} />
        <Row label="User ID" value={String(session.userId)} />
      </Section>

      <Section title="Notifications">
        <Row label="Register automatically" value="Keeps this device reachable for push">
          <Switch value={autoRegister} onValueChange={setAutoRegister} />
        </Row>
        <Row label="Push status" value={pushText}>
          <StatusDot state={pushState} />
        </Row>
        <View style={styles.sectionAction}>
          <NativeButton title="Register push token" tone="secondary" onPress={retryPush} />
        </View>
        {canOpenSettings ? (
          <View style={styles.sectionAction}>
            <NativeButton title="Open Android settings" tone="secondary" onPress={openSettings} />
          </View>
        ) : null}
      </Section>

      <Section title="Settings">
        <Row label="App purpose" value="Receive Inline Android notifications" />
        <Row label="Messages" value="Full chat UI is intentionally not in this build yet" />
      </Section>

      <NativeButton
        title="Sign out"
        tone="danger"
        onPress={() => {
          Alert.alert("Sign out?", "This removes the local session from this Android device.", [
            { text: "Cancel", style: "cancel" },
            { text: "Sign out", style: "destructive", onPress: signOut },
          ])
        }}
      />
    </ScrollView>
  )
}

function StatusDot({ state }: { state: PushRegistrationState | null }) {
  const color =
    state?.status === "registered" ? colors.success : state?.status === "failed" ? colors.danger : colors.warning
  return <View style={[styles.dot, { backgroundColor: color }]} />
}

function pushStateText(state: PushRegistrationState | null): string {
  if (!state) return "Registering..."
  if (state.status === "registered") return "Registered"
  return state.reason
}

const styles = StyleSheet.create({
  content: {
    gap: 22,
    padding: 20,
    paddingBottom: 36,
  },
  top: {
    minHeight: 72,
    flexDirection: "row",
    alignItems: "center",
    gap: 14,
  },
  avatar: {
    width: 54,
    height: 54,
    borderRadius: 27,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#eef2ff",
  },
  topText: {
    flex: 1,
    gap: 2,
  },
  title: {
    color: colors.text,
    fontSize: 28,
    fontWeight: "800",
  },
  subtitle: {
    color: colors.secondaryText,
    fontSize: 16,
  },
  sectionAction: {
    padding: 12,
    borderBottomWidth: StyleSheet.hairlineWidth,
    borderBottomColor: colors.border,
  },
  dot: {
    width: 12,
    height: 12,
    borderRadius: 6,
  },
})
