import { createFileRoute } from "@tanstack/react-router"

import { retiredWebClientRedirect } from "~/lib/retiredWebClient"

// The retired web client lived here; send old links home and clear its storage.
export const Route = createFileRoute("/app/$")({
  server: {
    handlers: {
      GET: () => retiredWebClientRedirect(),
      HEAD: () => retiredWebClientRedirect(),
    },
  },
})
