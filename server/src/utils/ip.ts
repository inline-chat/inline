import type { Server } from "bun"

export const getIp = (request: Request, server?: Server<unknown> | null): string | undefined => {
  return (
    headerValue(request, "cf-connecting-ip") ??
    headerValue(request, "x-real-ip") ??
    firstForwardedFor(request) ??
    headerValue(request, "x-forwarded") ??
    server?.requestIP(request)?.address
  )
}

const headerValue = (request: Request, name: string): string | undefined => {
  const value = request.headers.get(name)?.trim()
  return value || undefined
}

const firstForwardedFor = (request: Request): string | undefined => {
  const forwardedFor = request.headers.get("x-forwarded-for")
  const first = forwardedFor?.split(",", 1)[0]?.trim()
  return first || undefined
}
