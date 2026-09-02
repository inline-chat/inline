import { PublicBetaLanding } from "."
import type { Locale } from "./preferences"

export function LandingRoute({ locale }: { locale: Locale }) {
  return <PublicBetaLanding locale={locale} />
}
