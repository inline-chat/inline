/// <reference types="vite/client" />

import stylesheet from "../styles/app.css?url"
import stylesheet2 from "../styles/stylex.css?url"
import { type ReactNode } from "react"
import { createRootRoute, HeadContent, Outlet, Scripts } from "@tanstack/react-router"

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      {
        name: "viewport",
        content: "width=device-width, initial-scale=1",
      },
      { title: "Inline" },
    ],
    links: [
      { rel: "preconnect", href: "https://fonts.googleapis.com" },
      {
        rel: "preconnect",
        href: "https://fonts.gstatic.com",
        crossOrigin: "anonymous",
      },
      // favicon
      {
        rel: "icon",
        href: "https://inline.chat/favicon-white.png",
        media: "(prefers-color-scheme: dark)",
      },
      {
        rel: "icon",
        href: "https://inline.chat/favicon-black.png",
        media: "(prefers-color-scheme: light)",
      },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Inter:ital,opsz,wght@0,14..32,100..900;1,14..32,100..900&family=Red+Hat+Display:wght@700&family=Reddit+Mono:wght@400&display=swap",
      },
      { rel: "stylesheet", href: stylesheet, nonce: "1" },
      { rel: "stylesheet", href: stylesheet2, nonce: "2" },
    ],
  }),
  component: RootComponent,
})

function RootComponent() {
  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  )
}

function RootDocument({ children }: Readonly<{ children: ReactNode }>) {
  return (
    <html>
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}

// export function ErrorBoundary({ error }: Route.ErrorBoundaryProps) {
//   let message = "Oops!"
//   let details = "An unexpected error occurred."
//   let stack: string | undefined

//   if (isRouteErrorResponse(error)) {
//     message = error.status === 404 ? "404" : "Error"
//     details = error.status === 404 ? "The requested page could not be found." : error.statusText || details
//   } else if (import.meta.env.DEV && error && error instanceof Error) {
//     details = error.message
//     stack = error.stack
//   }

//   return (
//     <main className="pt-16 p-4 container mx-auto">
//       <h1>{message}</h1>
//       <p>{details}</p>
//       {stack && (
//         <pre className="w-full p-4 overflow-x-auto">
//           <code>{stack}</code>
//         </pre>
//       )}
//     </main>
//   )
// }
