import type { BunOptions } from "@sentry/bun"

const defaultTraceRate = 0.25

const routeTraceRates: ReadonlyMap<string, number> = new Map([
  ["/health", 0],
  ["/healthz", 0],
  ["/livez", 0],
  ["/readyz", 0],
  ["/_internal/grid-transcription/claim", 0.005],
  ["/oauth/introspect", 0.01],
  ["/realtime", 0.01],
  ["/bot/getUpdates", 0.02],
  ["/v1/rpc", 0.1],
])

export const sampleServerTrace: NonNullable<BunOptions["tracesSampler"]> = ({
  attributes,
  inheritOrSampleWith,
}) => {
  // Bun's Sentry integration supplies the pathname before the request is dispatched.
  const pathAttribute = attributes?.["url.path"]
  const path = typeof pathAttribute === "string" ? pathAttribute.replace(/\/$/, "") : ""
  const route = /^\/bot[^/]+\/getUpdates$/.test(path) ? "/bot/getUpdates" : path
  const rate = routeTraceRates.get(route) ?? defaultTraceRate

  // Honor upstream drop decisions and cap accepted parents at the local route rate.
  return Math.min(rate, inheritOrSampleWith(rate))
}
