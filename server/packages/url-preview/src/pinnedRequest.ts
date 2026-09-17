import { request as httpRequest } from "node:http"
import { request as httpsRequest } from "node:https"
import { isIP } from "node:net"
import { Readable } from "node:stream"
import type { LookupAddress } from "./types.js"
import { stripIpv6Brackets } from "./filters.js"

/** Keep the URL hostname for Host/SNI/certificate verification; DNS cannot change the socket target. */
export function pinnedRequest(url: URL, address: LookupAddress, init: RequestInit): Promise<Response> {
  return new Promise((resolve, reject) => {
    const headers = Object.fromEntries(new Headers(init.headers))
    const hostname = stripIpv6Brackets(url.hostname)
    const request = (url.protocol === "https:" ? httpsRequest : httpRequest)(url, {
      method: "GET",
      headers: { ...headers, "accept-encoding": "identity" },
      signal: init.signal ?? undefined,
      agent: false,
      ...(url.protocol === "https:" && !isIP(hostname) ? { servername: hostname } : {}),
      lookup: (_hostname, options, callback) => {
        if (options.all) callback(null, [address])
        else callback(null, address.address, address.family)
      },
    }, (response) => {
      // This callback runs after the Promise executor; malformed upstream responses must reject it,
      // never throw into the HTTP event loop and terminate the server.
      try {
        const responseHeaders = new Headers()
        for (const [name, value] of Object.entries(response.headers)) {
          if (value !== undefined) responseHeaders.set(name, Array.isArray(value) ? value.join(", ") : value)
        }
        const encoding = responseHeaders.get("content-encoding")
        if (encoding && encoding !== "identity") throw new Error("Unsupported preview content encoding")
        const status = response.statusCode ?? 502
        if (status < 200 || status > 599) throw new Error("Unsupported preview response status")
        if ([204, 205, 304].includes(status)) {
          response.resume()
          resolve(new Response(null, { status, headers: responseHeaders }))
        } else {
          // Node and Bun declare incompatible BYOB overloads for the same standard Web Stream.
          const body = Readable.toWeb(response) as unknown as ReadableStream<Uint8Array>
          resolve(new Response(body, { status, headers: responseHeaders }))
        }
      } catch (error) {
        response.destroy()
        reject(error)
      }
    })
    request.on("error", reject)
    request.end()
  })
}
