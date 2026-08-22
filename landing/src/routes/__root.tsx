/// <reference types="vite/client" />

import stylesheet from "../styles/tailwind.css?url"
import stylesheet2 from "../styles/stylex.css?url"
import fontsStylesheet from "../styles/fonts.css?url"
import { type ReactNode, useState } from "react"
import { createRootRoute, HeadContent, Outlet, Scripts, useRouterState } from "@tanstack/react-router"
import {
  AuthStore,
  Db,
  InlineClientProvider,
  RealtimeClient,
  useInlineClientProvider,
} from "@inline/client"
import { ClientRuntime } from "~/components/ClientRuntime"
import { useImagePreload } from "~/lib/imageCache"
import {
  directionForLocale,
  localeForLandingPath,
  type Locale,
} from "~/landing/public-beta/preferences"

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
      { rel: "stylesheet", href: fontsStylesheet },
      { rel: "stylesheet", href: stylesheet, nonce: "1" },
      { rel: "stylesheet", href: stylesheet2, nonce: "2" },
    ],
  }),
  component: RootComponent,
})

function RootComponent() {
  const pathname = useRouterState({ select: (state) => state.location.pathname })
  const isAppRoute = pathname === "/app" || pathname.startsWith("/app/")
  const landingLocale = localeForLandingPath(pathname)

  return (
    <RootDocument locale={landingLocale ?? "en"}>
      {isAppRoute ? <AppRoot /> : <Outlet />}
    </RootDocument>
  )
}

function AppRoot() {
  const [client] = useState(() => {
    const auth = new AuthStore()
    const db = new Db()
    return {
      auth,
      db,
      realtime: new RealtimeClient({ auth, db }),
    }
  })
  const { hasDbHydrated } = useInlineClientProvider({ value: client })
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

function RootDocument({ children, locale }: Readonly<{ children: ReactNode; locale: Locale }>) {
  return (
    <html lang={locale} dir={directionForLocale(locale)}>
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
