import { createRouter } from "@tanstack/react-router"
import { getGlobalStartContext } from "@tanstack/react-start"
import { routeTree } from "./routeTree.gen"
import { installDefaultTrustedTypesPolicy } from "./lib/trustedTypes"

installDefaultTrustedTypesPolicy()

// Server only; the client reads the nonce back from the csp-nonce meta tag.
const requestCspNonce = (): string | undefined => {
  try {
    return getGlobalStartContext()?.cspNonce
  } catch {
    return undefined
  }
}

export function getRouter() {
  const router = createRouter({
    routeTree,
    scrollRestoration: true,
    ssr: { nonce: requestCspNonce() },
  })

  return router
}
