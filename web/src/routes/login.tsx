import { createFileRoute } from "@tanstack/react-router"
import { OnboardingView } from "~/onboarding/OnboardingView"

export const Route = createFileRoute("/login")({
  component: OnboardingView,
  head: () => ({
    meta: [{ title: "Welcome to Inline" }],
  }),
})
