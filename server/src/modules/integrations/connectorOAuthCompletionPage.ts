export type ConnectorOAuthCompletionProvider = "linear" | "notion"

interface ConnectorOAuthCompletionPageInput {
  readonly provider: ConnectorOAuthCompletionProvider
  readonly appUrl: string
  readonly succeeded: boolean
}

export function renderConnectorOAuthCompletionPage(
  input: ConnectorOAuthCompletionPageInput,
): string {
  const providerName = input.provider === "notion" ? "Notion" : "Linear"
  const title = input.succeeded
    ? `${providerName} connected`
    : `Couldn’t connect ${providerName}`
  const description = input.succeeded
    ? "You can close this tab and continue in Inline."
    : "Return to Inline to review the error and try again."
  const appUrl = escapeHtml(input.appUrl)

  return `<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8" />
  <meta name="viewport" content="width=device-width, initial-scale=1" />
  <meta name="robots" content="noindex, nofollow, noarchive" />
  <meta name="referrer" content="no-referrer" />
  <meta http-equiv="refresh" content="0;url=${appUrl}" />
  <title>${title} · Inline</title>
  <style>
    :root { color-scheme: light dark; font-family: Inter, ui-sans-serif, -apple-system, BlinkMacSystemFont, "Segoe UI", sans-serif; }
    * { box-sizing: border-box; }
    body { min-height: 100vh; margin: 0; display: grid; place-items: center; padding: 32px 20px; color: #171717; background: #f7f7f5; }
    main { width: 100%; max-width: 380px; text-align: center; }
    .brand { display: inline-flex; align-items: center; gap: 9px; margin-bottom: 26px; font-size: 17px; font-weight: 700; letter-spacing: -0.02em; }
    .brand svg { width: 28px; height: 28px; }
    h1 { margin: 0; font-size: 27px; line-height: 1.2; letter-spacing: -0.035em; }
    p { margin: 10px 0 24px; color: #666661; font-size: 15px; line-height: 1.5; }
    a { display: inline-flex; min-height: 44px; align-items: center; justify-content: center; padding: 10px 18px; border: 1px solid #171717; border-radius: 11px; color: #fff; background: #171717; font-size: 14px; font-weight: 650; text-decoration: none; }
    a:hover { background: #30302d; }
    a:focus-visible { outline: 3px solid rgba(23, 23, 23, 0.24); outline-offset: 3px; }
    @media (prefers-color-scheme: dark) {
      body { color: #f3f3f0; background: #111210; }
      p { color: #a7a8a1; }
      a { border-color: #f1f1ed; color: #181916; background: #f1f1ed; }
      a:hover { background: #dcdcd7; }
      a:focus-visible { outline-color: rgba(241, 241, 237, 0.32); }
    }
  </style>
</head>
<body>
  <main>
    <div class="brand">
      <svg viewBox="0 0 51 51" aria-hidden="true"><path fill="currentColor" d="M31.875 0C42.437 0 51 8.563 51 19.125v12.75C51 42.437 42.437 51 31.875 51h-12.75C8.563 51 0 42.437 0 31.875v-12.75C0 8.563 8.563 0 19.125 0h12.75ZM19.125 9.563a9.562 9.562 0 0 0-9.562 9.562v12.75a9.562 9.562 0 0 0 9.562 9.562h12.75a9.562 9.562 0 0 0 9.562-9.562v-12.75a9.562 9.562 0 0 0-9.562-9.562h-12.75Zm3.607 6.449c1.856 0 3.361 1.416 3.361 3.163v12.651c0 1.747-1.505 3.162-3.361 3.162h-3.36c-1.856 0-3.36-1.415-3.36-3.162V19.175c0-1.747 1.504-3.163 3.36-3.163h3.36Z"/></svg>
      <span>Inline</span>
    </div>
    <h1>${title}</h1>
    <p>${description}</p>
    <a id="open-inline" href="${appUrl}">Open Inline</a>
  </main>
</body>
</html>`
}

function escapeHtml(input: string): string {
  return input.replace(/[&<>"']/g, (character) => {
    switch (character) {
      case "&": return "&amp;"
      case "<": return "&lt;"
      case ">": return "&gt;"
      case "\"": return "&quot;"
      case "'": return "&#39;"
      default: return character
    }
  })
}
