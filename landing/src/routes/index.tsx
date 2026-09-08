import { createFileRoute } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { getRequestHeader } from "@tanstack/react-start/server"
import { Landing } from "../landing"
import { LANDING_METADATA } from "../landing/metadata"
import redesignCssUrl from "../landing/styles/redesign.css?url"
import siteChromeCssUrl from "../landing/styles/site-chrome.css?url"

const getIsIOSRequest = createServerFn({ method: "GET" }).handler(() => {
  const userAgent = getRequestHeader("user-agent") ?? ""
  const isIOSDevice = /\b(?:iPad|iPhone|iPod)\b/i.test(userAgent)
  const isIPadUsingDesktopUserAgent = /\bMacintosh\b/i.test(userAgent) && /\bMobile\//i.test(userAgent)
  return isIOSDevice || isIPadUsingDesktopUserAgent
})

function Home() {
  const isIOS = Route.useLoaderData()
  return <Landing isIOS={isIOS} />
}

export const Route = createFileRoute("/")({
  component: Home,
  loader: () => getIsIOSRequest(),

  head: () => ({
    scripts: [
      { type: "application/ld+json", children: JSON.stringify(LANDING_METADATA.website) },
    ],
    links: [
      { rel: "canonical", href: LANDING_METADATA.url },
      {
        rel: "preload",
        href: "/inline-macos-message-style.webp",
        as: "image",
      },
      { rel: "stylesheet", href: redesignCssUrl },
      { rel: "stylesheet", href: siteChromeCssUrl },
    ],

    meta: [
      {
        title: LANDING_METADATA.title,
      },
      {
        name: "description",
        content: LANDING_METADATA.description,
      },
      { name: "twitter:card", content: LANDING_METADATA.twitter.card },
      {
        name: "twitter:title",
        content: LANDING_METADATA.twitter.title,
      },
      {
        name: "twitter:description",
        content: LANDING_METADATA.twitter.description,
      },
      {
        name: "twitter:image",
        content: LANDING_METADATA.twitter.image,
      },
      { property: "og:site_name", content: LANDING_METADATA.siteName },
      { property: "og:type", content: "website" },
      { property: "og:url", content: LANDING_METADATA.url },
      { property: "og:title", content: LANDING_METADATA.openGraph.title },
      { property: "og:description", content: LANDING_METADATA.openGraph.description },
      { property: "og:image", content: LANDING_METADATA.openGraph.image },
    ],
  }),
})
