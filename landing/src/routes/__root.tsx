/// <reference types="vite/client" />

import stylesheet from "../styles/tailwind.css?url"
import stylesheet2 from "../styles/stylex.css?url"
import { type ReactNode } from "react"
import { createRootRoute, HeadContent, Outlet, Scripts, useRouterState } from "@tanstack/react-router"
import { InlineClientProvider, useInlineClientProvider } from "@inline/client"
import { ClientRuntime } from "~/components/ClientRuntime"
import { useImagePreload } from "~/lib/imageCache"

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      {
        name: "viewport",
        content: "width=device-width, initial-scale=1",
      },
      { title: "Inline Chat" },
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
        href: "/favicon-white.png?v=2",
        media: "(prefers-color-scheme: dark)",
      },
      {
        rel: "icon",
        href: "/favicon-black.png?v=2",
        // href: "/favicon-colored.png?v=2",
        //href: "/favicon-colored-outline.png?v=2",
        media: "(prefers-color-scheme: light)",
      },
      {
        rel: "stylesheet",
        href: "https://fonts.googleapis.com/css2?family=Days+One&family=Inter:ital,opsz,wght@0,14..32,100..900;1,14..32,100..900&family=Red+Hat+Display:wght@700&family=Reddit+Mono:wght@400&display=swap",
      },
      { rel: "stylesheet", href: stylesheet, nonce: "1" },
      { rel: "stylesheet", href: stylesheet2, nonce: "2" },
    ],
  }),
  component: RootComponent,
})

function RootComponent() {
  const pathname = useRouterState({ select: (state) => state.location.pathname })
  const isAppRoute = pathname === "/app" || pathname.startsWith("/app/")

  return (
    <RootDocument>
      {isAppRoute ? <AppRoot /> : <Outlet />}
    </RootDocument>
  )
}

function AppRoot() {
  const { value: client, hasDbHydrated } = useInlineClientProvider()
  const hasImagesPreloaded = useImagePreload(client.db, hasDbHydrated)
  console.log("hasDbHydrated", hasDbHydrated)
  console.log("hasImagesPreloaded", hasImagesPreloaded)

  if (!hasDbHydrated || !hasImagesPreloaded) {
    return <div>Loading...</div>
  }

  return (
    <InlineClientProvider value={client}>
      <ClientRuntime />
      <Outlet />
    </InlineClientProvider>
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
