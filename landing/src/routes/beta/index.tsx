import { createFileRoute, redirect } from "@tanstack/react-router"
import { LandingRoute } from "../../landing/public-beta/LandingRoute"
import { getRememberedLocale } from "../../landing/public-beta/localePreference"
import { locales } from "../../landing/public-beta/preferences"
import { landingHead } from "../../landing/public-beta/seo"

function BetaHome() {
  return <LandingRoute locale="en" />
}

export const Route = createFileRoute("/beta/")({
  loader: async () => {
    const locale = await getRememberedLocale()
    if (!locale || locale === "en") return

    const pathSegment = locales.find(({ code }) => code === locale)?.pathSegment
    if (pathSegment) throw redirect({ to: "/beta/$locale", params: { locale: pathSegment } })
  },
  component: BetaHome,
  head: () => landingHead("en"),
})
