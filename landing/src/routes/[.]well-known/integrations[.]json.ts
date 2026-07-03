import { createFileRoute } from "@tanstack/react-router"

import { integrationsDeclaration, PUBLIC_JSON_HEADERS } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/.well-known/integrations.json")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(integrationsDeclaration, {
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
