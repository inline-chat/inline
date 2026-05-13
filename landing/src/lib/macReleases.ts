export type MacReleaseChannelId = "stable" | "beta"

export type MacRelease = {
  channel: MacReleaseChannelId
  title: string
  build: string
  version: string
  date: string
  url: string
  size: number | null
  latest: boolean
}

export type MacReleaseChannel = {
  id: MacReleaseChannelId
  title: string
  appcastUrl: string
  releases: MacRelease[]
  error?: string
}

const BASE_URL = "https://public-assets.inline.chat"

const CHANNELS: Array<{ id: MacReleaseChannelId; title: string }> = [
  { id: "stable", title: "Stable" },
  { id: "beta", title: "Beta" },
]

function appcastUrl(channel: MacReleaseChannelId) {
  return `${BASE_URL}/mac/${channel}/appcast.xml`
}

function text(item: string, tag: string): string {
  const match = item.match(new RegExp(`<${tag}[^>]*>([\\s\\S]*?)<\\/${tag}>`))
  return match ? decodeXml(match[1].trim()) : ""
}

function attr(item: string, name: string): string {
  const match = item.match(new RegExp(`\\s${name}="([^"]*)"`))
  return match ? decodeXml(match[1]) : ""
}

function decodeXml(value: string): string {
  return value
    .replace(/&quot;/g, '"')
    .replace(/&apos;/g, "'")
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">")
    .replace(/&amp;/g, "&")
}

function parseSize(value: string): number | null {
  if (!/^\d+$/.test(value)) return null
  return Number(value)
}

export function parseMacAppcast(channel: MacReleaseChannelId, xml: string): MacRelease[] {
  const items = Array.from(xml.matchAll(/<item>([\s\S]*?)<\/item>/g), (match) => match[1])
  const latest = items
    .map((item) => ({ build: text(item, "sparkle:version"), url: attr(item, "url") }))
    .filter((release) => release.url)
    .at(-1)

  const byUrl = new Map<string, MacRelease & { order: number }>()
  items.forEach((item, order) => {
    const url = attr(item, "url")
    if (!url) return

    const build = text(item, "sparkle:version")
    byUrl.set(url, {
      channel,
      title: text(item, "title") || `Inline ${build}`,
      build,
      version: text(item, "sparkle:shortVersionString"),
      date: text(item, "pubDate"),
      url,
      size: parseSize(attr(item, "length")),
      latest: latest?.url === url && latest?.build === build,
      order,
    })
  })

  return Array.from(byUrl.values())
    .sort((a, b) => b.order - a.order)
    .map(({ order: _order, ...release }) => release)
}

export function latestMacDmgUrl(xml: string): string | null {
  return parseMacAppcast("beta", xml)[0]?.url ?? null
}

export async function loadMacReleases(): Promise<MacReleaseChannel[]> {
  return Promise.all(
    CHANNELS.map(async (channel) => {
      const url = appcastUrl(channel.id)

      try {
        const response = await fetch(url, {
          headers: {
            accept: "application/xml,text/xml;q=0.9,*/*;q=0.8",
          },
        })

        if (!response.ok) {
          return {
            ...channel,
            appcastUrl: url,
            releases: [],
            error: `Appcast request failed with HTTP ${response.status}.`,
          }
        }

        const xml = await response.text()
        return {
          ...channel,
          appcastUrl: url,
          releases: parseMacAppcast(channel.id, xml),
        }
      } catch (error) {
        return {
          ...channel,
          appcastUrl: url,
          releases: [],
          error: error instanceof Error ? error.message : "Appcast request failed.",
        }
      }
    }),
  )
}
