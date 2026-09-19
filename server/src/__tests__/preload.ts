import { afterAll, afterEach, mock } from "bun:test"
import { applyTestDefaults } from "../../scripts/test-environment"
import { localOnlyFetch } from "./network"

// Set test environment
applyTestDefaults()

const deniedHosts = new Set<string>()
globalThis.fetch = localOnlyFetch(globalThis.fetch, (host) => deniedHosts.add(host))
const assertNoExternalRequests = () => {
  if (deniedHosts.size === 0) return
  const hosts = [...deniedHosts].join(", ")
  deniedHosts.clear()
  throw new Error(`Unexpected external fetch: ${hosts}. Mock the provider boundary explicitly.`)
}
afterEach(assertNoExternalRequests)
afterAll(assertNoExternalRequests)

// Mock external services
mock.module("../libs/resend", () => ({
  sendEmail: mock().mockResolvedValue(true),
  resend: {
    emails: { send: mock().mockResolvedValue({ data: { id: "test-email" }, error: null }) },
    contacts: {
      get: mock().mockResolvedValue({ data: null, error: { message: "not found" } }),
      create: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      update: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      segments: {
        add: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
        remove: mock().mockResolvedValue({ data: { id: "test-contact" }, error: null }),
      },
    },
    segments: { create: mock().mockResolvedValue({ data: { id: "test-segment" }, error: null }) },
    broadcasts: {
      create: mock().mockResolvedValue({ data: { id: "test-broadcast" }, error: null }),
      send: mock().mockResolvedValue({ data: { id: "test-broadcast" }, error: null }),
    },
  },
}))
