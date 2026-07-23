import { createFileRoute } from "@tanstack/react-router"
import { SettingsView } from "~/settings/SettingsView"

export const Route = createFileRoute("/_app/settings")({
  component: SettingsView,
  head: () => ({
    meta: [{ title: "Settings · Inline" }],
  }),
})
