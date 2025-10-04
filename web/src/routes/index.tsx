import { createFileRoute } from "@tanstack/react-router"
import { Landing } from "../landing"

function Home() {
  return <Landing />
}

export const Route = createFileRoute("/")({
  component: Home,

  head: () => ({
    links: [
      { rel: "preload", href: "/content-bg.jpg", as: "image" },
      {
        rel: "preload",
        href: "/content-bg@2x.jpg",
        as: "image",
        media: "(-webkit-min-device-pixel-ratio: 2), (min-resolution: 192dpi)",
      },
    ],

    meta: [
      {
        title: "Inline - A fast, feature-rich, lightweight messaging app for teams",
      },
      {
        name: "description",
        content: "We're building a native, fast, powerful chat app for teams.",
      },
      { name: "twitter:card", content: "summary_large_image" },
      {
        name: "twitter:title",
        content: "Inline - A fast, feature-rich, lightweight messaging app for teams",
      },
      {
        name: "twitter:description",
        content:
          "We're building a native, fast, powerful chat app for teams. Currently alpha stage. We've developing the apps open-source.",
      },
      {
        name: "twitter:image",
        content: "https://inline.chat/twitter-og.jpg",
      },
      { name: "og:image", content: "https://inline.chat/twitter-og.jpg" },
    ],
  }),
})
