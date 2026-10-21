import { createMiddleware, createStart } from "@tanstack/react-start"
import { createCspNonce, withDocumentContentSecurityPolicy } from "./lib/contentSecurityPolicy"

const contentSecurityPolicyMiddleware = createMiddleware().server(async ({ next }) => {
  const cspNonce = createCspNonce()
  const result = await next({ context: { cspNonce } })
  // Server-function requests can resolve to a raw value, not a Response.
  // Only documents need the header; leave anything else untouched.
  if (!(result.response instanceof Response)) return result
  return { ...result, response: withDocumentContentSecurityPolicy(result.response, cspNonce) }
})

export const startInstance = createStart(() => ({
  requestMiddleware: [contentSecurityPolicyMiddleware],
}))
