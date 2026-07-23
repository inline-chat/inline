import { useState } from "react"
import { useNavigate } from "@tanstack/react-router"
import type { SendEmailCodeResult, SendSmsCodeResult } from "~/inline/auth/auth-api"
import { CodeView } from "./CodeView"
import { EmailView } from "./EmailView"
import { GetStartedView } from "./GetStartedView"
import { InviteCodeView } from "./InviteCodeView"
import { OnboardingFrame } from "./OnboardingFrame"
import { PhoneView } from "./PhoneView"
import { ProfileView } from "./ProfileView"
import { WelcomeView } from "./WelcomeView"

type OnboardingRoute =
  | "welcome"
  | "getStarted"
  | "phone"
  | "email"
  | "inviteCode"
  | "code"
  | "profile"

type OnboardingState = {
  identity?:
    | { kind: "email"; email: string; challengeToken?: string }
    | { kind: "phone"; phoneNumber: string; formattedPhoneNumber: string }
  inviteCode?: string
  existingUser?: boolean
}

export function OnboardingView() {
  const navigate = useNavigate()
  const [path, setPath] = useState<OnboardingRoute[]>(["welcome"])
  const [state, setState] = useState<OnboardingState>({})
  const route = path.at(-1) ?? "welcome"
  const push = (next: OnboardingRoute) => setPath((current) => [...current, next])

  const codeSent = (email: string, result: SendEmailCodeResult) => {
    setState((current) => ({
      ...current,
      identity: { kind: "email", email, challengeToken: result.challengeToken },
      existingUser: result.existingUser,
    }))
    push(result.needsInviteCode ? "inviteCode" : "code")
  }

  const smsCodeSent = (result: SendSmsCodeResult) => {
    setState((current) => ({
      ...current,
      identity: {
        kind: "phone",
        phoneNumber: result.phoneNumber,
        formattedPhoneNumber: result.formattedPhoneNumber,
      },
      existingUser: result.existingUser,
    }))
    push(result.needsInviteCode ? "inviteCode" : "code")
  }

  return (
    <OnboardingFrame
      canGoBack={path.length > 1 && route !== "profile"}
      onBack={() => setPath((current) => current.slice(0, -1))}
    >
      {route === "welcome" ? <WelcomeView onContinue={() => push("getStarted")} /> : null}
      {route === "getStarted" ? (
        <GetStartedView onPhone={() => push("phone")} onEmail={() => push("email")} />
      ) : null}
      {route === "phone" ? (
        <PhoneView
          initialPhoneNumber={state.identity?.kind === "phone" ? state.identity.phoneNumber : ""}
          onSent={smsCodeSent}
        />
      ) : null}
      {route === "email" ? (
        <EmailView
          initialEmail={state.identity?.kind === "email" ? state.identity.email : ""}
          onSent={codeSent}
        />
      ) : null}
      {route === "inviteCode" ? (
        <InviteCodeView
          onValid={(inviteCode) => {
            setState((current) => ({ ...current, inviteCode }))
            push("code")
          }}
        />
      ) : null}
      {route === "code" && state.identity ? (
        <CodeView
          identity={state.identity}
          inviteCode={state.inviteCode}
          existingUser={state.existingUser}
          onVerified={(result) => {
            if (!result.user.firstName || result.user.pendingSetup) {
              push("profile")
            } else {
              void navigate({ to: "/chats", replace: true })
            }
          }}
        />
      ) : null}
      {route === "profile" ? (
        <ProfileView onComplete={() => void navigate({ to: "/chats", replace: true })} />
      ) : null}
    </OnboardingFrame>
  )
}
