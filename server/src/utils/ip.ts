import type { Server } from "bun"

export const getIp = async (request: Request, server: Server | null) => {
  return (
    request.headers.get("x-forwarded-for") ??
    request.headers.get("cf-connecting-ip") ??
    request.headers.get("x-real-ip") ??
    request.headers.get("x-forwarded") ??
    server?.requestIP(request)?.address
  )
}
