import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { gitCommitHash, relativeBuildDate, version } from "@in/server/buildEnv"
import { html } from "@elysiajs/html"

export const root = new Elysia({ scoped: true })
  .use(setup)
  // NOTE(@mo): This plugin breaks the error handling ref: https://github.com/elysiajs/elysia/issues/747
  // I used scoped: true to fix it for now
  .use(html())
  // DO NOT MODIFY THIS INITIAL PART OF MESSAGE
  // THIS IS MATCHED IN UPTIME MONITOR
  .get("/", () => {
    let title = `🚧 inline server is running`
    let subtitle = `v${version} • deployed ${relativeBuildDate()} • ${gitCommitHash}`

    let html = `
      <html>
        <head>
          <title>~/dev/inline</title>
          <link href="https://inline.chat/favicon-white.png" rel="icon" media="(prefers-color-scheme: dark)" />
          <link href="https://inline.chat/favicon-black.png" rel="icon" media="(prefers-color-scheme: light)" />
          <style>
          html {
              padding: 0;
              margin: 0;
              height: 100%;
              background-color: #111;
              background-image: linear-gradient(180deg, #111, #333);
            }
            body {
              font-family: monospace;
              font-size: 16px;
              line-height: 1.5;
              
              color: #eee;
              padding: 20px;
              height: 100%;
            }
            h1, h2 {
              margin: 0;
              font-size: 16px;
            }
            p {
              margin: 0;
              margin-top: 4px;
              color: #ccc;
            }
            a {
              display: inline-block;
              color: #ccc;
              text-decoration: none;
              border-radius: 4px;
              margin-right: 2px;
            }
            footer {
              border-top: 1px solid #555;
              padding-top: 20px;
              font-size: 16px;
              max-width: 500px;
            }
          </style>
        </head>
        <body>
          <h1>${title}</h1>
          <p>${subtitle}</p>
          <footer style="margin-top: 20px;">
          <a href="https://inline.chat">inline.chat</a>
          <a><span>•</span></a>
          <a href="https://status.inline.chat">is inline down?</a>
          <a><span>•</span></a>
          <a href="mailto:hi@inline.chat">hi@inline.chat</a>
          </footer>
        </body>
      </html>
    `
    return html
  })
