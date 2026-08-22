import { useNavigate } from "@tanstack/react-router"
import { PublicBetaLanding } from "."
import { rememberLocale } from "./localePreference"
import { locales, type Locale } from "./preferences"

export function LandingRoute({ locale }: { locale: Locale }) {
  const navigate = useNavigate()

  return (
    <PublicBetaLanding
      locale={locale}
      onLocaleChange={(nextLocale) => {
        rememberLocale(nextLocale)

        if (nextLocale === "en") {
          void navigate({ to: "/beta" })
          return
        }

        const pathSegment = locales.find(({ code }) => code === nextLocale)?.pathSegment
        if (pathSegment) void navigate({ to: "/beta/$locale", params: { locale: pathSegment } })
      }}
    />
  )
}
