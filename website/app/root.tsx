import {
  Links,
  Meta,
  Outlet,
  Scripts,
  ScrollRestoration,
} from "@remix-run/react"
import "./tailwind.css"
import "./style.css"

export function Layout({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <meta charSet="utf-8" />
        <meta name="viewport" content="width=device-width, initial-scale=1" />
        <link
          href="favicon-black.png"
          rel="icon"
          media="(prefers-color-scheme: light)"
        />
        <link
          href="favicon-white.png"
          rel="icon"
          media="(prefers-color-scheme: dark)"
        />
        <link
          href="https://fonts.googleapis.com/css2?family=Red+Hat+Display:wght@700&family=Reddit+Mono:wght@400&display=swap"
          rel="stylesheet"
        />
        <Meta />
        <Links />
      </head>
      <body>
        {children}
        <ScrollRestoration />
        <Scripts />
      </body>
    </html>
  )
}

export default function App() {
  return <Outlet />
}
