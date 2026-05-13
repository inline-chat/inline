import { describe, expect, test } from "vitest"

import { latestMacDmgUrl, parseMacAppcast } from "./macReleases"

const appcast = `
<rss xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" version="2.0">
  <channel>
    <item>
      <title>Inline 0.1</title>
      <pubDate>Thu, 22 Jan 2026 17:20:11 +0000</pubDate>
      <sparkle:version>101</sparkle:version>
      <sparkle:shortVersionString>0.1</sparkle:shortVersionString>
      <enclosure url="https://public-assets.inline.chat/mac/beta/101/Inline.dmg" length="1000000" />
    </item>
    <item>
      <title>Inline 0.2</title>
      <pubDate>Fri, 23 Jan 2026 16:24:59 +0000</pubDate>
      <sparkle:version>102</sparkle:version>
      <sparkle:shortVersionString>0.2</sparkle:shortVersionString>
      <enclosure url="https://public-assets.inline.chat/mac/beta/102/Inline.dmg" length="2000000" />
    </item>
    <item>
      <title>Inline 0.2</title>
      <pubDate>Fri, 23 Jan 2026 16:30:00 +0000</pubDate>
      <sparkle:version>102</sparkle:version>
      <sparkle:shortVersionString>0.2</sparkle:shortVersionString>
      <enclosure url="https://public-assets.inline.chat/mac/beta/102/Inline.dmg" length="2100000" />
    </item>
  </channel>
</rss>
`

describe("mac release appcast parsing", () => {
  test("returns previous builds newest first and marks the current appcast item", () => {
    const releases = parseMacAppcast("beta", appcast)

    expect(releases.map((release) => release.build)).toEqual(["102", "101"])
    expect(releases[0]).toMatchObject({
      latest: true,
      size: 2100000,
      url: "https://public-assets.inline.chat/mac/beta/102/Inline.dmg",
    })
    expect(releases[1]?.latest).toBe(false)
  })

  test("resolves the latest DMG URL from the last appcast item", () => {
    expect(latestMacDmgUrl(appcast)).toBe("https://public-assets.inline.chat/mac/beta/102/Inline.dmg")
  })
})
