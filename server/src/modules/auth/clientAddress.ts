import type {
  HttpRequestContextShape,
} from "../../core/http/requestContext"

/**
 * @deprecated Consume `HttpRequestContext.clientIp` directly.
 */
export const resolveTrustedClientIp = (
  context: Pick<HttpRequestContextShape, "clientIp">,
): string => context.clientIp
