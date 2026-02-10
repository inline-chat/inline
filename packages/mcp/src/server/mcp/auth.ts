async function sha256Hex(input: string): Promise<string> {
  const data = new TextEncoder().encode(input)
  const digest = await crypto.subtle.digest("SHA-256", data)
  const bytes = new Uint8Array(digest)
  let out = ""
  for (const b of bytes) out += b.toString(16).padStart(2, "0")
  return out
}

export type BearerTokenError =
  | { kind: "missing" }
  | { kind: "invalid_format" }

export function getBearerToken(req: Request): { ok: true; token: string } | { ok: false; error: BearerTokenError } {
  const auth = req.headers.get("authorization")
  if (!auth) return { ok: false, error: { kind: "missing" } }
  const [type, token] = auth.split(" ")
  if (!type || type.toLowerCase() !== "bearer" || !token) return { ok: false, error: { kind: "invalid_format" } }
  return { ok: true, token }
}

export async function tokenHashHex(token: string): Promise<string> {
  return await sha256Hex(token)
}

