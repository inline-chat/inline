import { createFileRoute } from "@tanstack/react-router"
import { Landing } from "../landing"
import redesignCssUrl from "../landing/styles/redesign.css?url"
import siteChromeCssUrl from "../landing/styles/site-chrome.css?url"

function Home() {
  return <Landing />
}

export const Route = createFileRoute("/")({
  component: Home,

  head: () => ({
    links: [
      {
        rel: "preload",
        href: "/inline-macos-codex.webp",
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
