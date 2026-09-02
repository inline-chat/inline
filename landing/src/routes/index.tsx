import { createFileRoute } from "@tanstack/react-router"
import { createServerFn } from "@tanstack/react-start"
import { getRequestHeader } from "@tanstack/react-start/server"
import { Landing } from "../landing"
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
    links: [
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
        title: "Inline - The interface for multiplayer work",
      },
      {
        name: "description",
        content: "Inline is a thread-based chat app for all work, with your teammates and agents.",
      },
      { name: "twitter:card", content: "summary_large_image" },
      {
        name: "twitter:title",
        content: "Inline - The interface for multiplayer work",
      },
      {
        name: "twitter:description",
        content: "Inline is a thread-based chat app for all work, with your teammates and agents.",
      },
      {
        name: "twitter:image",
        content: "https://inline.chat/twitter-og.jpg",
      },
      { name: "og:image", content: "https://inline.chat/twitter-og.jpg" },
    ],
  }),
})
