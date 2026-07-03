import { createFileRoute } from "@tanstack/react-router"

import { oauthProtectedResource, PUBLIC_JSON_HEADERS } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/.well-known/oauth-protected-resource")({
  server: {
    handlers: {
      GET: async () => {
        return Response.json(oauthProtectedResource, {
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
