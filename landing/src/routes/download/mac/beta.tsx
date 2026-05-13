import { createFileRoute, redirect } from "@tanstack/react-router"

import { latestMacDmgUrl } from "~/lib/macReleases"

const APPCAST_URL = "https://public-assets.inline.chat/mac/beta/appcast.xml"

export const Route = createFileRoute("/download/mac/beta")({
  loader: async () => {
    const response = await fetch(APPCAST_URL, {
      headers: {
        accept: "application/xml,text/xml;q=0.9,*/*;q=0.8",
      },
    })

    if (!response.ok) {
      throw redirect({ href: APPCAST_URL })
    }

    const xml = await response.text()
    const dmgUrl = latestMacDmgUrl(xml)
    throw redirect({ href: dmgUrl ?? APPCAST_URL })
  },
})
