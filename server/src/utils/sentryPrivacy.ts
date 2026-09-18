import type { Event } from "@sentry/bun"
import { redactString, redactValue } from "./log"
import { redactCredentialPath } from "./httpPrivacy"

type SpanJSON = NonNullable<Event["spans"]>[number]

export const beforeSendSpan = (span: SpanJSON): SpanJSON => ({
  ...span,
  ...(span.description ? { description: redactString(span.description) } : {}),
  ...(span.data ? { data: redactValue(span.data) as typeof span.data } : {}),
})

/** SDK request enrichment happens after application logging; scrub that boundary too. */
export const beforeSendEvent = <T extends Event>(event: T): T => ({
  ...event,
  ...(event.request ? { request: {
    method: event.request.method,
    // Retain only a diagnostic path. Headers, cookies, query strings and bodies may contain credentials.
    url: safeRequestPath(event.request.url),
  } } : {}),
  ...(event.message ? { message: redactString(event.message) } : {}),
  ...(event.transaction ? { transaction: redactString(event.transaction) } : {}),
  ...(event.tags ? { tags: redactValue(event.tags) as Event["tags"] } : {}),
  ...(event.logentry ? { logentry: {
    ...event.logentry,
    ...(event.logentry.message ? { message: redactString(event.logentry.message) } : {}),
    ...(event.logentry.params ? { params: redactValue(event.logentry.params) as unknown[] } : {}),
  } } : {}),
  ...(event.extra ? { extra: redactValue(event.extra) as Event["extra"] } : {}),
  ...(event.contexts ? { contexts: redactValue(event.contexts) as Event["contexts"] } : {}),
  ...(event.breadcrumbs ? { breadcrumbs: event.breadcrumbs.map((item) => ({
    ...item,
    ...(item.message ? { message: redactString(item.message) } : {}),
    ...(item.data ? { data: redactValue(item.data) as typeof item.data } : {}),
  })) } : {}),
  ...(event.exception ? { exception: { ...event.exception, values: event.exception.values?.map((item) => ({
    ...item, ...(item.value ? { value: redactString(item.value) } : {}),
  })) } } : {}),
  ...(event.spans ? { spans: event.spans.map(beforeSendSpan) } : {}),
})

const safeRequestPath = (url: string | undefined): string | undefined => {
  if (!url) return undefined
  try { return redactCredentialPath(new URL(url, "http://diagnostic.invalid").pathname) }
  catch { return "<redacted>" }
}
