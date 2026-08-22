import {
  HttpServerResponse,
} from "effect/unstable/http"

/**
 * Preserve Web Response semantics at retained handler boundaries.
 *
 * Effect stores cookies separately because Set-Cookie cannot be combined like
 * ordinary headers. Keep the existing raw-body behavior while transferring the
 * parsed cookie collection explicitly.
 */
export const webResponseToHttpServerResponse = (
  response: Response,
): HttpServerResponse.HttpServerResponse => {
  const headers = new Headers(response.headers)
  const cookies = HttpServerResponse.fromWeb(response).cookies
  headers.delete("set-cookie")
  const options = {
    status: response.status,
    statusText: response.statusText,
    headers: Object.fromEntries(headers),
    cookies,
  }

  return response.body === null
    ? HttpServerResponse.empty(options)
    : HttpServerResponse.raw(response.body, options)
}
