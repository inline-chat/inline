import { expect, test } from "bun:test"
import { sampleServerTrace } from "./sentrySampling"

const sample = (path: string, parentRate?: number) => sampleServerTrace({
  name: `GET ${path}`,
  attributes: { "url.path": path, "url.query": "unused=1" },
  inheritOrSampleWith: (fallback) => parentRate ?? fallback,
})

test.each([
  ["/health", 0],
  ["/healthz/", 0],
  ["/livez", 0],
  ["/readyz", 0],
  ["/_internal/grid-transcription/claim", 0.005],
  ["/oauth/introspect", 0.01],
  ["/realtime", 0.01],
  ["/bot/getUpdates", 0.02],
  ["/bot-example/getUpdates/", 0.02],
  ["/v1/rpc", 0.1],
  ["/realtime/v3", 0.25],
  ["/bot/sendMessage", 0.25],
  ["/file", 0.25],
] as const)("samples the %s route", (path, rate) => {
  expect(sample(path)).toBe(rate)
})

test("caps upstream trace rates without reviving dropped traces", () => {
  expect(sample("/health", 1)).toBe(0)
  expect(sample("/realtime", 1)).toBe(0.01)
  expect(sample("/v1/rpc", 0.05)).toBe(0.05)
  expect(sample("/file", 0)).toBe(0)
})
