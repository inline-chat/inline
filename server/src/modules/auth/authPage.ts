/**
 * One visual shell for every browser page in sign-in and app-connection flows
 * (hosted login, OAuth consent, provider hand-off). Pages pass escaped body
 * HTML; everything here is static markup with no scripts.
 */

export const escapeHtml = (value: string): string => value.replace(/[&<>"']/g, (character) => ({
  "&": "&amp;",
  "<": "&lt;",
  ">": "&gt;",
  '"': "&quot;",
  "'": "&#39;",
})[character] ?? character)

/** Who is asking. Shown above the heading so every step says what it's for. */
export type AuthPageContext =
  | { kind: "cli"; label: string; detail?: string }
  | { kind: "verified-app"; label: string; detail?: string }
  | { kind: "unverified-app"; label: string; detail?: string }

const icons = {
  cli: `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M5 7l5 5-5 5M12 18h7" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  "verified-app": `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 3l7 3v5c0 4.5-3 8.3-7 10-4-1.7-7-5.5-7-10V6l7-3z M9 12l2 2 4-4" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
  "unverified-app": `<svg viewBox="0 0 24 24" aria-hidden="true"><path d="M12 4l9 16H3l9-16z M12 10v4 M12 17.5v.01" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"/></svg>`,
} as const

const contextChip = (context: AuthPageContext): string => `<div class="context ${context.kind}">${icons[context.kind]}<span class="context-label">${escapeHtml(context.label)}</span>${context.detail ? `<span class="context-detail">${escapeHtml(context.detail)}</span>` : ""}</div>`

const authPageStyles = `
:root { color-scheme: light dark; font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; --fg: #171717; --muted: #6b6b66; --faint: #8a8a84; --bg: #f7f7f5; --card: #fff; --line: #e3e3df; --field: #cececa; --soft: #f3f3f0; --accent: #171717; --on-accent: #fff; --warn-bg: #fff7e8; --warn-line: #f0d8a8; --warn-fg: #7a4d05; --ok-bg: #eef7f0; --ok-line: #cfe6d5; --ok-fg: #1f6a37; --err-bg: #fff6f5; --err-line: #edc9c5; --err-fg: #9d2d23; }
* { box-sizing: border-box; }
body { margin: 0; min-height: 100vh; display: grid; place-items: center; padding: 28px 20px; color: var(--fg); background: var(--bg); }
.shell { width: 100%; max-width: 420px; }
.brand { display: flex; align-items: center; justify-content: center; gap: 9px; margin-bottom: 20px; font-size: 16px; font-weight: 650; letter-spacing: -0.02em; }
.brand svg { width: 26px; height: 26px; }
.card { border: 1px solid var(--line); border-radius: 18px; padding: 28px; background: var(--card); }
.context { display: inline-flex; align-items: center; gap: 7px; max-width: 100%; margin-bottom: 14px; padding: 5px 10px; border: 1px solid var(--line); border-radius: 999px; background: var(--soft); color: var(--muted); font-size: 12px; font-weight: 550; }
.context svg { flex: none; width: 14px; height: 14px; }
.context-label { color: var(--fg); overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.context-detail { overflow: hidden; text-overflow: ellipsis; white-space: nowrap; }
.context-detail::before { content: "·"; margin-right: 7px; }
.context.verified-app { border-color: var(--ok-line); background: var(--ok-bg); color: var(--ok-fg); }
.context.unverified-app { border-color: var(--warn-line); background: var(--warn-bg); color: var(--warn-fg); }
.context.unverified-app .context-label, .context.verified-app .context-label { color: inherit; }
h1 { margin: 0; font-size: 23px; line-height: 1.25; letter-spacing: -0.03em; }
.intro { margin: 8px 0 22px; color: var(--muted); font-size: 14px; line-height: 1.55; }
.intro strong, .notice strong { color: var(--fg); font-weight: 600; }
label { display: block; margin-top: 16px; font-size: 13px; font-weight: 600; }
input[type="text"], input[type="email"], input[type="tel"], input[inputmode="numeric"] { width: 100%; min-height: 46px; padding: 11px 13px; margin-top: 7px; border-radius: 10px; border: 1px solid var(--field); background: var(--card); color: var(--fg); font: inherit; font-size: 15px; outline: none; }
input:focus-visible { border-color: var(--fg); box-shadow: 0 0 0 3px rgba(120, 120, 115, 0.22); }
input[inputmode="numeric"] { letter-spacing: 0.3em; font-variant-numeric: tabular-nums; font-size: 18px; text-align: center; }
button, .button { display: flex; align-items: center; justify-content: center; width: 100%; min-height: 46px; margin-top: 20px; padding: 11px 16px; border-radius: 11px; border: 1px solid var(--accent); background: var(--accent); color: var(--on-accent); font: inherit; font-size: 14px; font-weight: 600; text-decoration: none; cursor: pointer; }
button:hover, .button:hover { opacity: 0.88; }
button.secondary, .button.secondary { border-color: var(--field); background: transparent; color: var(--fg); }
button:focus-visible, .button:focus-visible, a:focus-visible, summary:focus-visible { outline: 3px solid #7aa7ff; outline-offset: 2px; }
.button-row { display: grid; grid-template-columns: 1fr 1fr; gap: 10px; margin-top: 20px; }
.button-row button, .button-row .button { margin-top: 0; }
.methods { display: grid; gap: 9px; }
.methods .button { margin-top: 0; border-color: var(--field); background: transparent; color: var(--fg); }
.notice { margin: 0 0 18px; padding: 12px 14px; border: 1px solid var(--line); border-radius: 11px; background: var(--soft); color: var(--muted); font-size: 13px; line-height: 1.5; }
.notice.warning { border-color: var(--warn-line); background: var(--warn-bg); color: var(--warn-fg); }
.notice.warning strong { color: inherit; }
.error { margin: 0 0 16px; padding: 12px 14px; border: 1px solid var(--err-line); border-radius: 10px; background: var(--err-bg); color: var(--err-fg); font-size: 14px; line-height: 1.45; }
.facts { display: grid; gap: 7px; margin: 0 0 4px; padding: 12px 14px; border-radius: 11px; background: var(--soft); font-size: 13px; }
.facts div { display: flex; justify-content: space-between; gap: 12px; }
.facts dt { color: var(--muted); }
.facts dd { margin: 0; text-align: right; overflow-wrap: anywhere; }
.facts dd.warn { color: var(--warn-fg); font-weight: 600; }
.section-label { margin: 18px 0 8px; color: var(--muted); font-size: 12px; font-weight: 600; }
.permissions { display: grid; gap: 8px; margin: 0; padding: 0; list-style: none; font-size: 14px; }
.permissions li { display: flex; gap: 9px; align-items: flex-start; line-height: 1.4; }
.permissions li::before { content: ""; flex: none; width: 6px; height: 6px; margin-top: 7px; border-radius: 50%; background: var(--faint); }
.choices { max-height: 280px; overflow-y: auto; border: 1px solid var(--line); border-radius: 11px; }
.choices label { display: flex; align-items: center; gap: 11px; min-height: 42px; margin: 0; padding: 0 12px; border-bottom: 1px solid var(--line); font-size: 14px; font-weight: 500; cursor: pointer; }
.choices label:last-child { border-bottom: 0; }
.choices input { width: 17px; height: 17px; margin: 0; accent-color: var(--accent); }
details { margin-top: 14px; font-size: 13px; }
summary { color: var(--muted); cursor: pointer; }
.back { display: block; margin-top: 18px; color: var(--muted); font-size: 13px; text-align: center; text-underline-offset: 3px; }
.muted { margin: 12px 0 0; color: var(--faint); font-size: 12px; line-height: 1.5; }
.status { text-align: center; }
.status .intro { margin-bottom: 0; }
.downloads { margin-top: 22px; padding-top: 16px; border-top: 1px solid var(--line); color: var(--muted); font-size: 13px; line-height: 1.5; }
.downloads a { color: var(--fg); text-underline-offset: 3px; }
h1 + .error, h1 + .notice, h1 + .facts { margin-top: 14px; }
.trust { margin: 16px 4px 0; color: var(--faint); font-size: 11px; line-height: 1.5; text-align: center; }
@media (max-width: 520px) { body { align-items: start; padding: 24px 14px; } .card { padding: 22px 18px; border-radius: 16px; } }
@media (prefers-color-scheme: dark) {
  :root { --fg: #f3f3f0; --muted: #a7a8a1; --faint: #81827b; --bg: #111210; --card: #1b1c19; --line: #33342f; --field: #464742; --soft: #22231f; --accent: #f1f1ed; --on-accent: #181916; --warn-bg: #2c2312; --warn-line: #5c4720; --warn-fg: #f1c66f; --ok-bg: #16261b; --ok-line: #2b4a33; --ok-fg: #8fd3a2; --err-bg: #2d1d1b; --err-line: #663e39; --err-fg: #f1aaa2; }
}
`

const authPageBrand = `<div class="brand" aria-label="Inline"><svg viewBox="0 0 54 54" fill="none" aria-hidden="true"><rect x="5" y="5" width="44" height="44" rx="16" stroke="currentColor" stroke-width="10"/><rect x="17" y="17" width="10" height="20" rx="4" fill="currentColor"/></svg><span>Inline</span></div>`

export const authPageDocument = (input: {
  title: string
  body: string
  heading?: string | null
  context?: AuthPageContext
  trust?: string
}): string => `<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8" />
<meta name="viewport" content="width=device-width, initial-scale=1" />
<meta name="color-scheme" content="light dark" />
<meta name="referrer" content="no-referrer" />
<title>${escapeHtml(input.title)} · Inline</title>
<style>${authPageStyles}</style>
</head>
<body>
<main class="shell">
${authPageBrand}
<div class="card">
${input.context ? contextChip(input.context) : ""}
${input.heading === null ? "" : `<h1>${escapeHtml(input.heading ?? input.title)}</h1>`}
${input.body}
</div>
<div class="trust">${escapeHtml(input.trust ?? "Inline never asks you to share codes with anyone. Only continue if you started this sign-in, or asked an agent to.")}</div>
</main>
</body>
</html>`

/**
 * Static pages: no scripts, nothing framed. `form-action` is omitted on
 * purpose — consent redirects to the client after a form POST.
 */
export const authPageHeaders = {
  "content-type": "text/html; charset=utf-8",
  "cache-control": "no-store",
  "content-security-policy": "default-src 'none'; style-src 'unsafe-inline'; img-src data:; base-uri 'none'; frame-ancestors 'none'",
  "referrer-policy": "no-referrer",
  "x-content-type-options": "nosniff",
} as const

export const authPageResponse = (
  status: number,
  input: Parameters<typeof authPageDocument>[0],
  headers: Record<string, string> = {},
): Response => new Response(authPageDocument(input), { status, headers: { ...authPageHeaders, ...headers } })
