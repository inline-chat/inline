// Trusted Types policies allowed by the document CSP (`trusted-types` in
// contentSecurityPolicy.ts). Browsers without Trusted Types fall back to strings.

import { TRUSTED_TYPES_HIGHLIGHT_POLICY } from "./contentSecurityPolicy"

type PolicyOptions = {
  createHTML?: (input: string) => string | null
  createScript?: (input: string) => string | null
  createScriptURL?: (input: string) => string | null
}

type Policy = {
  createHTML(input: string): TrustedHTML
}

type PolicyFactory = {
  createPolicy(name: string, options: PolicyOptions): Policy
  defaultPolicy: unknown
}

const policyFactory = (): PolicyFactory | undefined =>
  typeof window === "undefined"
    ? undefined
    : (window as Window & { trustedTypes?: PolicyFactory }).trustedTypes

const isJson = (input: string): boolean => {
  try {
    JSON.parse(input)
    return true
  } catch {
    return false
  }
}

const isSameOriginUrl = (input: string): boolean => {
  try {
    return new URL(input, window.location.href).origin === window.location.origin
  } catch {
    return false
  }
}

// React DOM creates every <script> element through this inert markup.
const REACT_SCRIPT_ELEMENT_HTML = "<script></script>"

// Covers sinks owned by libraries: React creates script elements via
// innerHTML, TanStack Router re-renders head scripts on client navigation
// (JSON-LD only here), and same-origin script URLs are already allowed by
// script-src. Any other markup must go through a named policy; text without
// "<" cannot create elements.
export function installDefaultTrustedTypesPolicy(): void {
  const factory = policyFactory()
  if (!factory || factory.defaultPolicy) return
  factory.createPolicy("default", {
    createHTML: (input) => (input === REACT_SCRIPT_ELEMENT_HTML || !input.includes("<") ? input : null),
    createScript: (input) => (isJson(input) ? input : null),
    createScriptURL: (input) => (isSameOriginUrl(input) ? input : null),
  })
}

let highlightPolicy: Policy | null | undefined

// highlight.js escapes the source text and only emits <span class> markup.
export function trustedHighlightHTML(html: string): string | TrustedHTML {
  if (highlightPolicy === undefined) {
    highlightPolicy = policyFactory()?.createPolicy(TRUSTED_TYPES_HIGHLIGHT_POLICY, {
      createHTML: (input) => input,
    }) ?? null
  }
  return highlightPolicy ? highlightPolicy.createHTML(html) : html
}
