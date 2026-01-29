import { createFileRoute, redirect } from "@tanstack/react-router"

const APPCAST_URL = "https://public-assets.inline.chat/mac/beta/appcast.xml"

function parseLatestDmgUrl(xml: string): string | null {
  const itemRegex = /<item>([\s\S]*?)<\/item>/g
  let bestUrl: string | null = null
  let bestVersion: bigint | null = null
  let lastUrl: string | null = null

  for (const match of xml.matchAll(itemRegex)) {
    const item = match[1]
    const urlMatch = item.match(/<enclosure[^>]*\surl="([^"]+)"/)
    if (!urlMatch) {
      continue
    }

    const url = urlMatch[1]
    lastUrl = url

    const versionMatch = item.match(/<sparkle:version>([^<]+)<\/sparkle:version>/)
    if (!versionMatch) {
      if (!bestUrl) {
        bestUrl = url
      }
      continue
    }

    const versionText = versionMatch[1].trim()
    if (/^\d+$/.test(versionText)) {
      const version = BigInt(versionText)
      if (bestVersion === null || version > bestVersion) {
        bestVersion = version
        bestUrl = url
      }
    } else if (!bestUrl) {
      bestUrl = url
    }
  }

  return bestUrl ?? lastUrl
}

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
    const dmgUrl = parseLatestDmgUrl(xml)
    throw redirect({ href: dmgUrl ?? APPCAST_URL })
  },
})
