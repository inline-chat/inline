import { Data } from "effect"

export class LegacyElysiaJsonParseError extends Data.TaggedError(
  "LegacyElysiaJsonParseError",
)<{
  readonly cause: unknown
}> {}

const appendParam = (
  result: Record<string, unknown>,
  key: string,
  value: FormDataEntryValue | string,
): void => {
  const existing = result[key]
  if (existing === undefined) {
    result[key] = value
  } else if (Array.isArray(existing)) {
    existing.push(value)
  } else {
    result[key] = [existing, value]
  }
}

const paramsToRecord = (
  params: URLSearchParams,
): Record<string, unknown> => {
  const result: Record<string, unknown> = {}
  for (const [key, value] of params) {
    appendParam(result, key, value)
  }
  return result
}

const formDataToRecord = (
  formData: FormData,
): Record<string, unknown> => {
  const result: Record<string, unknown> = {}
  for (const [key, value] of formData) {
    appendParam(result, key, value)
  }
  return result
}

const mediaType = (request: Request): string | undefined => {
  const value = request.headers
    .get("content-type")
    ?.split(";", 1)[0]
    ?.trim()
    .toLowerCase()
  return value === "" ? undefined : value
}

/**
 * Mirrors the body values Elysia 1.4 supplies to retained route handlers.
 *
 * This intentionally does not default an absent content type to JSON. That
 * difference can otherwise run stateful login work that the legacy transport
 * rejects before invoking its handler.
 */
export const parseLegacyElysiaBody = async (
  request: Request,
): Promise<unknown> => {
  const contentType = mediaType(request)

  if (contentType === "application/json") {
    const text = await request.text()
    if (text === "") {
      return undefined
    }
    try {
      return JSON.parse(text)
    } catch (cause) {
      throw new LegacyElysiaJsonParseError({ cause })
    }
  }

  if (contentType === "application/x-www-form-urlencoded") {
    return paramsToRecord(
      new URLSearchParams(await request.text()),
    )
  }

  if (contentType === "multipart/form-data") {
    return formDataToRecord(await request.formData())
  }

  if (contentType === "text/plain") {
    return await request.text()
  }

  if (contentType === "application/octet-stream") {
    return await request.arrayBuffer()
  }

  return undefined
}
