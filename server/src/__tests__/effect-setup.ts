import { afterAll, afterEach } from "vitest"
import { applyTestDefaults } from "../../scripts/test-environment"
import { localOnlyFetch } from "./network"

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
