import { createFileRoute } from "@tanstack/react-router"

import { appleAppSiteAssociation } from "~/lib/chatShortcut"
import { PUBLIC_JSON_HEADERS } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/.well-known/apple-app-site-association")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(appleAppSiteAssociation, {
          headers: PUBLIC_JSON_HEADERS,
        })
      },
      HEAD: async () => {
        return new Response(null, {
          headers: PUBLIC_JSON_HEADERS,
        })
      },
    },
  },
})
