import { createMiddleware, createStart } from "@tanstack/react-start"
import { createCspNonce, withDocumentContentSecurityPolicy } from "./lib/contentSecurityPolicy"

const contentSecurityPolicyMiddleware = createMiddleware().server(async ({ next }) => {
  const cspNonce = createCspNonce()
  const result = await next({ context: { cspNonce } })
  return { ...result, response: withDocumentContentSecurityPolicy(result.response, cspNonce) }
})

export const startInstance = createStart(() => ({
  requestMiddleware: [contentSecurityPolicyMiddleware],
}))
