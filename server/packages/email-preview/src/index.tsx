import { render } from "@react-email/render"
import * as React from "react"
import { templates } from "./templates"

const PORT = 3002

function getTemplate(id: string | null) {
  if (!id) return templates[0]
  return templates.find((template) => template.id === id) ?? templates[0]
}

function renderShell(selectedId: string | null) {
  const selected = getTemplate(selectedId)
  const navItems = templates
    .map((template) => {
      const isActive = template.id === selected?.id
      const className = isActive ? "nav-item nav-item-active" : "nav-item"
      return `<a class="${className}" href="/?template=${template.id}">${template.name}</a>`
    })
    .join("")

  return `<!doctype html>
<html lang="en">
  <head>
    <meta charset="utf-8" />
    <meta name="viewport" content="width=device-width, initial-scale=1" />
    <title>Inline Email Preview</title>
    <style>
      :root {
        color-scheme: light;
        font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Helvetica, Arial, sans-serif;
      }

      * {
        box-sizing: border-box;
      }

      body {
        margin: 0;
        background: #f6f7f9;
        color: #111111;
      }

      .app {
        display: grid;
        grid-template-columns: 260px 1fr;
        min-height: 100vh;
      }

      .sidebar {
        background: #ffffff;
        border-right: 1px solid #e4e6ea;
        padding: 20px 16px;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .sidebar h1 {
        margin: 0 0 8px 0;
        font-size: 16px;
        font-weight: 600;
        color: #0e0f12;
      }

      .nav {
        display: flex;
        flex-direction: column;
        gap: 6px;
      }

      .nav-item {
        padding: 10px 12px;
        border-radius: 8px;
        text-decoration: none;
        color: #1a1b1f;
        border: 1px solid transparent;
        transition: background 120ms ease, border-color 120ms ease;
      }

      .nav-item:hover {
        background: #f1f2f5;
        border-color: #e4e6ea;
      }

      .nav-item-active {
        background: #eef1ff;
        border-color: #cdd6ff;
        color: #1a2a88;
        font-weight: 600;
      }

      .content {
        padding: 24px;
        display: flex;
        flex-direction: column;
        gap: 12px;
      }

      .controls {
        display: flex;
        flex-wrap: wrap;
        gap: 12px;
        align-items: center;
        justify-content: space-between;
        background: #ffffff;
        border: 1px solid #e4e6ea;
        border-radius: 12px;
        padding: 12px 16px;
      }

      .control-group {
        display: flex;
        align-items: center;
        gap: 8px;
      }

      .control-label {
        font-size: 12px;
        text-transform: uppercase;
        letter-spacing: 0.08em;
        color: #6b6f78;
      }

      .control-button {
        border: 1px solid #d6dbe3;
        background: #ffffff;
        color: #1a1b1f;
        border-radius: 8px;
        padding: 6px 10px;
        font-size: 13px;
        cursor: pointer;
      }

      .control-button.is-active {
        background: #1a2a88;
        border-color: #1a2a88;
        color: #ffffff;
      }

      .content-header {
        font-size: 14px;
        color: #5b606a;
      }

      .frame-wrap {
        flex: 1;
        display: flex;
        justify-content: center;
        align-items: stretch;
        width: 100%;
      }

      .frame {
        width: 100%;
        max-width: 100%;
        display: flex;
      }

      iframe {
        width: 100%;
        flex: 1;
        border: 1px solid #e4e6ea;
        border-radius: 12px;
        background: #ffffff;
        min-height: 720px;
      }

      body[data-viewport="mobile"] .frame {
        max-width: 390px;
      }

      body[data-viewport="mobile"] iframe {
        min-height: 780px;
      }

      @media (max-width: 960px) {
        .app {
          grid-template-columns: 1fr;
        }

        .sidebar {
          border-right: none;
          border-bottom: 1px solid #e4e6ea;
        }
      }
    </style>
  </head>
  <body>
    <div class="app">
      <aside class="sidebar">
        <h1>Inline Email Preview</h1>
        <nav class="nav">${navItems}</nav>
      </aside>
      <main class="content">
        <div class="controls">
          <div class="control-group">
            <span class="control-label">Viewport</span>
            <button class="control-button" data-viewport="desktop" type="button">Desktop</button>
            <button class="control-button" data-viewport="mobile" type="button">Mobile</button>
          </div>
        </div>
        <div class="content-header">Previewing: ${selected?.name ?? ""}</div>
        <div class="frame-wrap">
          <div class="frame">
            <iframe title="Email preview" src="/preview/${selected?.id ?? ""}"></iframe>
          </div>
        </div>
      </main>
    </div>
    <script>
      const viewportButtons = Array.from(document.querySelectorAll('[data-viewport]'))

      function setActive(buttons, value, key) {
        buttons.forEach((button) => {
          const matches = button.getAttribute(key) === value
          button.classList.toggle('is-active', matches)
        })
      }

      function setViewport(viewport) {
        document.body.dataset.viewport = viewport
        localStorage.setItem('email-preview-viewport', viewport)
        setActive(viewportButtons, viewport, 'data-viewport')
      }

      viewportButtons.forEach((button) => {
        button.addEventListener('click', () => setViewport(button.getAttribute('data-viewport')))
      })

      setViewport(localStorage.getItem('email-preview-viewport') || 'desktop')
    </script>
  </body>
</html>`
}

async function renderTemplate(templateId: string) {
  const template = getTemplate(templateId)
  if (!template) return null
  return await render(React.createElement(template.component, template.props))
}

const server = Bun.serve({
  port: PORT,
  async fetch(request) {
    const url = new URL(request.url)

    if (url.pathname === "/") {
      return new Response(renderShell(url.searchParams.get("template")), {
        headers: { "content-type": "text/html; charset=utf-8" },
      })
    }

    if (url.pathname.startsWith("/preview/")) {
      const id = url.pathname.replace("/preview/", "")
      const html = await renderTemplate(id)

      if (!html) {
        return new Response("Template not found", { status: 404 })
      }

      return new Response(html, {
        headers: { "content-type": "text/html; charset=utf-8" },
      })
    }

    return new Response("Not found", { status: 404 })
  },
})

console.log(`Email preview server running at http://localhost:${server.port}`)
