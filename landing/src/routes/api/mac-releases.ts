import { createFileRoute } from "@tanstack/react-router"

import { loadMacReleases } from "~/lib/macReleases"

export const Route = createFileRoute("/api/mac-releases")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(await loadMacReleases(), {
          headers: {
            "cache-control": "public, max-age=300",
          },
        })
      },
    },
  },
})
