import { mkdir } from "node:fs/promises"
import { fileURLToPath } from "node:url"

const root = fileURLToPath(new URL("../", import.meta.url))
const output = await Bun.build({
  entrypoints: [`${root}src/main.tsx`],
  target: "browser",
  minify: true,
  define: { "process.env.NODE_ENV": '"production"' },
})
if (!output.success) throw new AggregateError(output.logs, "Inline thread UI failed to build")
const script = await output.outputs[0]!.text()
const css = await Bun.file(`${root}src/styles.css`).text()
const html = `<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width, initial-scale=1"><meta name="referrer" content="no-referrer"><title>Inline thread</title><style>${css}</style></head>
<body><div id="root"></div><script type="module">${script.replace(/<\/script/gi, "<\\/script")}</script></body></html>`

await mkdir(`${root}dist`, { recursive: true })
const constants = {
  THREAD_RESOURCE_URI: "ui://inline/thread-v1.html",
  THREAD_RESOURCE_MIME_TYPE: "text/html;profile=mcp-app",
  THREAD_RESOURCE_HTML: html,
}
await Bun.write(`${root}dist/index.js`, Object.entries(constants)
  .map(([name, value]) => `export const ${name} = ${JSON.stringify(value)};`).join("\n") + "\n")
await Bun.write(`${root}dist/index.d.ts`, Object.keys(constants)
  .map((name) => `export declare const ${name}: string;`).join("\n") + "\n")
await Bun.write(`${root}dist/thread.html`, html)
console.log(`Built Inline thread UI (${Math.ceil(Buffer.byteLength(html) / 1024)} KiB, self-contained)`)
