import { createFileRoute } from "@tanstack/react-router"

import { apiCatalog, PUBLIC_LINKSET_HEADERS } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/.well-known/api-catalog")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(apiCatalog, {
          headers: PUBLIC_LINKSET_HEADERS,
        })
      },
      HEAD: async () => {
        return new Response(null, {
          headers: PUBLIC_LINKSET_HEADERS,
        })
      },
    },
  },
})
