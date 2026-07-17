import { Option, Schema } from "effect"
import { nanoid } from "nanoid/non-secure"

export const REQUEST_ID_HEADER = "x-request-id"
export const MAX_REQUEST_ID_LENGTH = 128

const requestIdPattern = /^[a-zA-Z0-9._-]+$/

/**
 * A request correlation ID accepted from the public HTTP boundary.
 *
 * Decoding trims surrounding whitespace to preserve the current server's
 * behavior before enforcing its safe character and length constraints.
 */
export const RequestId = Schema.Trim.check(
  Schema.isMinLength(1),
  Schema.isMaxLength(MAX_REQUEST_ID_LENGTH),
  Schema.isPattern(requestIdPattern),
).pipe(Schema.brand("RequestId"))

export type RequestId = typeof RequestId.Type

const decodeRequestId = Schema.decodeUnknownOption(RequestId)

export const parseRequestId = (input: unknown): Option.Option<RequestId> => decodeRequestId(input)

/**
 * Generates the same Nano ID form used by the current Elysia setup and validates
 * the trusted generator result before branding it.
 */
export const generateRequestId = (generate: () => string = nanoid): RequestId => RequestId.make(generate())

export const resolveRequestId = (
  headerValue: string | null | undefined,
  generate: () => RequestId = generateRequestId,
): RequestId => Option.getOrElse(parseRequestId(headerValue), generate)
