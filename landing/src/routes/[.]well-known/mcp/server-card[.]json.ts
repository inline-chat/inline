import { createFileRoute } from "@tanstack/react-router"

import { mcpServerCard, PUBLIC_JSON_HEADERS } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/.well-known/mcp/server-card.json")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(mcpServerCard, {
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
