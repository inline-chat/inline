import { createFileRoute, notFound } from "@tanstack/react-router"
import { LandingRoute } from "../../landing/public-beta/LandingRoute"
import { localeFromPathSegment } from "../../landing/public-beta/preferences"
import { landingHead } from "../../landing/public-beta/seo"

export const Route = createFileRoute("/beta/$locale")({
  loader: ({ params }) => {
    const locale = localeFromPathSegment(params.locale)
    if (!locale) throw notFound()
    return locale
  },
  head: ({ loaderData }) => (loaderData ? landingHead(loaderData) : {}),
  component: LocalizedHome,
})

function LocalizedHome() {
  const locale = Route.useLoaderData()
  return <LandingRoute locale={locale} />
}
