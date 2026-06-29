import { MaterialIcons } from "@expo/vector-icons"
import { useState } from "react"
import { Alert, KeyboardAvoidingView, Platform, StyleSheet, Text, TextInput, View } from "react-native"

import { sendEmailCode, verifyEmailCode } from "@/api/auth"
import { saveSession } from "@/auth/session"
import { NativeButton } from "@/components/NativeButton"
import { colors } from "@/theme/colors"

type LoginScreenProps = {
  onLogin: () => void
}

export function LoginScreen({ onLogin }: LoginScreenProps) {
  const [email, setEmail] = useState("")
  const [code, setCode] = useState("")
  const [challengeToken, setChallengeToken] = useState<string | undefined>()
  const [needsInviteCode, setNeedsInviteCode] = useState(false)
  const [inviteCode, setInviteCode] = useState("")
  const [busy, setBusy] = useState(false)
  const [stage, setStage] = useState<"email" | "code">("email")

  const normalizedEmail = email.trim().toLowerCase()
  const emailValid = /^[^\s@]+@[^\s@]+\.[^\s@]+$/.test(normalizedEmail)
  const codeValid = code.trim().length >= 6

  async function submitEmail() {
    if (!emailValid || busy) return

    setBusy(true)
    try {
      const result = await sendEmailCode(normalizedEmail)
      setChallengeToken(result.challengeToken)
      setNeedsInviteCode(result.needsInviteCode)
      setStage("code")
    } catch (error) {
      Alert.alert("Could not send code", error instanceof Error ? error.message : "Try again.")
    } finally {
      setBusy(false)
    }
  }

  async function submitCode() {
    if (!codeValid || busy) return

    setBusy(true)
    try {
      const result = await verifyEmailCode({
        email: normalizedEmail,
        code: code.trim(),
        challengeToken,
        inviteCode: needsInviteCode ? inviteCode.trim() : undefined,
      })
      await saveSession({
        token: result.token,
        userId: result.userId,
        user: result.user,
      })
      onLogin()
    } catch (error) {
      Alert.alert("Could not sign in", error instanceof Error ? error.message : "Check the code and try again.")
    } finally {
      setBusy(false)
    }
  }

  return (
    <KeyboardAvoidingView behavior={Platform.select({ ios: "padding", android: undefined })} style={styles.wrap}>
      <View style={styles.header}>
        <View style={styles.icon}>
          <MaterialIcons name="alternate-email" size={26} color={colors.accent} />
        </View>
        <Text style={styles.title}>{stage === "email" ? "Sign in to Inline" : "Enter your code"}</Text>
        <Text style={styles.subtitle}>
          {stage === "email" ? "Use your Inline email to enable Android notifications." : `Sent to ${normalizedEmail}`}
        </Text>
      </View>

      <View style={styles.form}>
        {stage === "email" ? (
          <TextInput
            autoCapitalize="none"
            autoComplete="email"
            autoCorrect={false}
            editable={!busy}
            inputMode="email"
            keyboardType="email-address"
            onChangeText={setEmail}
            onSubmitEditing={submitEmail}
            placeholder="Email"
            returnKeyType="send"
            style={styles.input}
            textContentType="emailAddress"
            value={email}
          />
        ) : (
          <>
            <TextInput
              autoCapitalize="none"
              autoCorrect={false}
              editable={!busy}
              inputMode="numeric"
              keyboardType="number-pad"
              maxLength={8}
              onChangeText={setCode}
              onSubmitEditing={submitCode}
              placeholder="Code"
              returnKeyType="done"
              style={[styles.input, styles.codeInput]}
              value={code}
            />
            {needsInviteCode ? (
              <TextInput
                autoCapitalize="characters"
                autoCorrect={false}
                editable={!busy}
                onChangeText={setInviteCode}
                placeholder="Invite code"
                style={styles.input}
                value={inviteCode}
              />
            ) : null}
          </>
        )}
      </View>

      <View style={styles.actions}>
        {stage === "code" ? (
          <NativeButton title="Use another email" tone="secondary" disabled={busy} onPress={() => setStage("email")} />
        ) : null}
        <NativeButton
          title={stage === "email" ? (busy ? "Sending..." : "Continue") : busy ? "Signing in..." : "Sign in"}
          disabled={busy || (stage === "email" ? !emailValid : !codeValid)}
          onPress={stage === "email" ? submitEmail : submitCode}
        />
      </View>
    </KeyboardAvoidingView>
  )
}

const styles = StyleSheet.create({
  wrap: {
    flex: 1,
    justifyContent: "center",
    padding: 24,
    gap: 28,
  },
  header: {
    alignItems: "center",
    gap: 10,
  },
  icon: {
    width: 56,
    height: 56,
    borderRadius: 28,
    alignItems: "center",
    justifyContent: "center",
    backgroundColor: "#eef2ff",
  },
  title: {
    color: colors.text,
    fontSize: 24,
    fontWeight: "700",
  },
  subtitle: {
    color: colors.secondaryText,
    fontSize: 15,
    lineHeight: 21,
    textAlign: "center",
  },
  form: {
    gap: 12,
  },
  input: {
    minHeight: 54,
    borderRadius: 8,
    borderWidth: StyleSheet.hairlineWidth,
    borderColor: colors.border,
    backgroundColor: colors.surface,
    color: colors.text,
    fontSize: 17,
    paddingHorizontal: 14,
  },
  codeInput: {
    textAlign: "center",
    fontSize: 22,
    fontWeight: "700",
    letterSpacing: 0,
  },
  actions: {
    gap: 10,
  },
})
