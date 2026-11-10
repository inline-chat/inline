# Message widgets

Bots can show one sandboxed HTML widget inside a message: a chart, diagram, mockup, comparison grid or small picker that Markdown can't show. Only bot senders get widgets: the Inline local-agent bridge, OpenClaw, Hermes and Bot API bots. Messages sent as a person (MCP, the CLI with a user login) keep the HTML as plain text, so don't send widgets that way.

Prefer Markdown, tables and the built-in blocks when they are enough. Use a widget when the visual is the point.

## Syntax

Write an Agent Flavored Markdown HTML preview on its own lines, with blank lines around it. Keep the explanation outside it:

````markdown
Revenue grew 18% this quarter.

<iframe title="Q3 revenue by month" id="revenue" height="320">
<div class="card">
  <div class="row"><strong>Q3 revenue</strong><span class="badge">+18%</span></div>
  <svg viewBox="0 0 600 220" width="100%" role="img" aria-label="Revenue by month">…</svg>
</div>
</iframe>

The dip in August was the pricing change.
````

- `title` is required: it heads the widget and is the plain-text fallback for notifications, search and older clients.
- `id` keeps viewers' widget state across edits. Use letters, digits, `_ . : -`.
- `height` is the content height in CSS pixels at about 640px wide (80–2000). The app measures the real height, but a good hint avoids a jump. Taller than 720px shows a fade and Show all.
- One widget per message. Write an HTML fragment (or a full document) of at most 256 KiB. The first `</iframe>` ends it.
- Inside a code fence, `<iframe>` stays code. Use that to show widget source.

## Sandbox

- No network: `fetch`, XHR, WebSocket and remote images are blocked. Put data in the HTML and images in `data:` URIs.
- Scripts can be inline or come from `cdn.jsdelivr.net`, `cdnjs.cloudflare.com`, `unpkg.com` or `esm.sh`. Fonts can come from Google Fonts.
- Not allowed: `vh` units (they loop with auto height), nested `iframe`/`object`/`embed`, password inputs. Ask for secrets with a form, not a widget.
- Lay out for 320–640px wide. Avoid `position: fixed` and inner scrolling.

## Look

Widgets follow the app's light or dark theme through CSS variables: `--background`, `--foreground`, `--muted`, `--muted-foreground`, `--card`, `--border`, `--primary`, `--primary-foreground`, `--accent`, `--success`, `--warning`, `--destructive`, `--radius`, `--font-sans`, `--font-mono`.

Built-in classes: `.card`, `.grid`, `.row`, `.badge`, `.btn`, `.btn-primary`, `.btn-ghost`, `.table`, `.muted`, `.small`, `.tabular-nums`. Use them instead of hard-coded colors so the widget matches the app.

## Buttons and state

The `inline` object talks to the app. Actions only run after the viewer clicks.

| Call | Effect |
| --- | --- |
| `inline.copy(text)` | Copies text and shows "Copied" |
| `inline.sendPrompt(text)` | Puts text in the viewer's composer as a reply to the widget; in a 1:1 DM with the bot it sends right away |
| `inline.action(name, payload)` | Sends the bot a `message_action` update with `widget_call: {name, payload}`; `action.action_id` is the widget's `id`. Payload is JSON, at most 4 KiB |
| `inline.openLink(url)` | Opens an http(s) link |
| `inline.setState(value)` / `inline.state` | Keeps per-viewer state (at most 16 KiB) while scrolling and after relaunch; never shared |

Treat `widget_call` like any user input: the viewer's app supplies it. Use `sendPrompt` for "ask a follow-up", `action` for choices the bot should act on, and `copy` for commands or snippets.

## Errors

A malformed widget fails the whole send with a reason such as "Widget HTML has `vh` units…" or "Widget is missing its closing </iframe>". Fix it and send again; don't resend the same HTML.
