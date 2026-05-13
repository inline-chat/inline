import { createFileRoute } from "@tanstack/react-router"

import { DocsMarkdown } from "~/docs/DocsMarkdown"
import { loadMacReleases as loadPublicMacReleases, type MacRelease, type MacReleaseChannel } from "~/lib/macReleases"

export const Route = createFileRoute("/docs/downloads/previous")({
  loader: () => loadMacReleases(),
  component: PreviousDownloadsDocs,
  head: () => ({
    meta: [{ title: "Previous Downloads - Inline Docs" }],
  }),
})

async function loadMacReleases(): Promise<MacReleaseChannel[]> {
  if (typeof window === "undefined") {
    return loadPublicMacReleases()
  }

  const response = await fetch("/api/mac-releases", {
    headers: {
      accept: "application/json",
    },
  })

  if (!response.ok) {
    throw new Error(`Failed to load macOS releases: HTTP ${response.status}`)
  }

  return response.json()
}

function PreviousDownloadsDocs() {
  const channels = Route.useLoaderData()

  return <DocsMarkdown markdown={releaseMarkdown(channels)} className="page-content docs-content" />
}

function releaseMarkdown(channels: MacReleaseChannel[]) {
  const lines = ["# Previous Versions", "", "Older macOS DMG builds from the public Sparkle appcasts.", ""]

  for (const channel of channels) {
    lines.push(`## ${channel.title}`, "")

    if (channel.error) {
      lines.push("Could not load this appcast.", "")
      continue
    }

    const releases = channel.releases.filter((release) => !release.latest)
    if (releases.length === 0) {
      lines.push(`No previous ${channel.title.toLowerCase()} builds are listed yet.`, "")
      continue
    }

    for (const release of releases) {
      lines.push(`- [${releaseLabel(release)}](${release.url}) - ${formatDate(release.date)}, ${formatSize(release.size)}`)
    }

    lines.push("")
  }

  return lines.join("\n")
}

function releaseLabel(release: MacRelease) {
  return release.version ? `${release.version} (${release.build})` : `Build ${release.build}`
}

function formatDate(value: string) {
  const date = new Date(value)
  if (Number.isNaN(date.getTime())) return value || "Unknown"

  return new Intl.DateTimeFormat("en", {
    month: "short",
    day: "numeric",
    year: "numeric",
    timeZone: "UTC",
  }).format(date)
}

function formatSize(value: number | null) {
  if (value === null) return "Unknown"
  return `${(value / 1024 / 1024).toFixed(1)} MB`
}
