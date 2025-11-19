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
        title: "Inline - A fast, lightweight and powerful work chat app",
        //title: "Inline Chat - A new way to chat at work built for collective thinking",
      },
      {
        name: "description",
        content: "A fast, lightweight and powerful chat app for teams that makes sharing ideas an absolute joy.",
      },
      { name: "twitter:card", content: "summary_large_image" },
      {
        name: "twitter:title",
        content: "Inline - Work chat 2.0",
      },
      {
        name: "twitter:description",
        content:
          "Inline is a fast, lightweight, scalable, and powerful work chat app designed to spark new ideas, enable maximum sharing, while allowing longest possible focus time.",
        //A fast, lightweight and powerful chat app for teams that makes sharing ideas an absolute joy.
      },
      {
        name: "twitter:image",
        content: "https://inline.chat/twitter-og.jpg",
      },
      { name: "og:image", content: "https://inline.chat/twitter-og.jpg" },
    ],
  }),
})
