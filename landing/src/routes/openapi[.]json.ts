import { createFileRoute } from "@tanstack/react-router"

import { fetchCanonicalOpenApiHeadResponse, fetchCanonicalOpenApiResponse } from "~/lib/integrationSurfaces"

export const Route = createFileRoute("/openapi.json")({
  server: {
    handlers: {
      GET: fetchCanonicalOpenApiResponse,
      HEAD: fetchCanonicalOpenApiHeadResponse,
    },
  },
})
