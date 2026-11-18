/**
 * Script URLs under Trusted Types.
 *
 * The production policy has `require-trusted-types-for 'script'`, which makes
 * `navigator.serviceWorker.register`, `new Worker` and `new SharedWorker`
 * Trusted Types sinks: in an enforcing browser a plain string throws. This
 * module owns one named policy that only mints same-origin `http:` and
 * `https:` URLs without credentials. A same-origin `blob:` URL is refused too:
 * its origin is the page's, but its bytes are whatever a script put in the
 * blob. `script-src 'self'` and `worker-src 'self'` already allow nothing
 * else, so the policy adds no reach.
 *
 * The content policy lists the policy's name and no `default` policy:
 * `trusted-types inline-script-url` (`vite.config.ts`). Where the name is not
 * listed, `createPolicy` throws, this module falls back to the plain string,
 * and an enforcing browser refuses the registration, which
 * `registerServiceWorker` reports as an error.
 */

import type { ScriptUrl } from "./types"

export const SCRIPT_URL_POLICY_NAME = "inline-script-url"

interface ScriptUrlPolicy {
  createScriptURL(input: string): ScriptUrl
}

export interface TrustedTypesLike {
  createPolicy(name: string, rules: { createScriptURL(input: string): string }): ScriptUrlPolicy
}

export interface ScriptUrlEnv {
  readonly trustedTypes: TrustedTypesLike | undefined
  /** The document's URL, to resolve relative input and compare origins. */
  readonly baseUrl: string
}

export class UntrustedScriptUrlError extends Error {
  override readonly name = "UntrustedScriptUrlError"
}

/**
 * The policy's rule: an `http:` or `https:` URL of the page's own origin,
 * without a user name or password, returned absolute. Relative input resolves
 * against the page (so `//host` and `\\host` name another origin and fail).
 */
export const sameOriginScriptUrl = (input: string, baseUrl: string): string => {
  const base = new URL(baseUrl)
  const url = new URL(input, base)
  if (url.protocol !== "https:" && url.protocol !== "http:") {
    throw new UntrustedScriptUrlError(`Script URL scheme is not allowed: ${url.protocol}`)
  }
  if (url.origin !== base.origin) throw new UntrustedScriptUrlError(`Script URL is not same-origin: ${url.origin}`)
  if (url.username !== "" || url.password !== "") throw new UntrustedScriptUrlError("Script URL carries credentials")
  return url.href
}

const policies = new WeakMap<TrustedTypesLike, ScriptUrlPolicy | null>()

const policyFor = (env: ScriptUrlEnv): ScriptUrlPolicy | null => {
  const factory = env.trustedTypes
  if (!factory) return null
  // A policy name can be created once per document unless the CSP says
  // 'allow-duplicates', so it is created once and shared.
  if (policies.has(factory)) return policies.get(factory) ?? null
  let policy: ScriptUrlPolicy | null = null
  try {
    policy = factory.createPolicy(SCRIPT_URL_POLICY_NAME, {
      createScriptURL: (input) => sameOriginScriptUrl(input, env.baseUrl),
    })
  } catch {
    // The CSP does not list the policy name. Fall back to the string.
  }
  policies.set(factory, policy)
  return policy
}

const globalEnv = (): ScriptUrlEnv => ({
  trustedTypes: (globalThis as { trustedTypes?: TrustedTypesLike }).trustedTypes,
  baseUrl: globalThis.location.href,
})

/**
 * A `TrustedScriptURL` for a same-origin script where Trusted Types exist,
 * else the checked string. Throws for a cross-origin URL either way.
 *
 * Use it for every script URL sink: the service worker here, and the core's
 * `new Worker(...)` (`src/core/connect.ts`), which is the same kind of sink.
 */
export const trustedScriptUrl = (input: string, env: ScriptUrlEnv = globalEnv()): ScriptUrl => {
  const checked = sameOriginScriptUrl(input, env.baseUrl)
  const policy = policyFor(env)
  return policy ? policy.createScriptURL(checked) : checked
}
