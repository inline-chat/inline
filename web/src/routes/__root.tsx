import stylesheet from "../styles/base.css?url"
import { HeadContent, Outlet, Scripts, createRootRoute } from "@tanstack/react-router"
import { useEffect, type ReactNode } from "react"
import {
  inlineRouteErrorTitle,
  RoutePlaceholderView,
} from "~/app/RoutePlaceholderView"
import { resizeObserverErrorSuppressionScript } from "~/platform/browser/BrowserResizeObserverErrors"
import { inlineAppearanceBootstrapScript } from "~/inline/preferences/InlineAppearancePreferences"
import {
  logInlineRouteError,
  retainInlineGlobalLogging,
} from "~/inline/logging/InlineLogging"
import appIcon from "../../../apple/InlineMac/Assets.xcassets/AppIcon.imageset/AppIcon-128.png?url"

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      {
        name: "viewport",
        content: "width=device-width, initial-scale=1, viewport-fit=cover",
      },
      {
        name: "theme-color",
        content: "#242426",
      },
      { title: "Inline" },
    ],
    links: [
      { rel: "icon", type: "image/png", href: appIcon },
      { rel: "stylesheet", href: stylesheet },
      ...(import.meta.env.DEV ? [{ rel: "stylesheet", href: "/virtual:stylex.css" }] : []),
    ],
  }),
  component: RootComponent,
  errorComponent: RootRouteError,
  notFoundComponent: () => (
    <RoutePlaceholderView title="This page isn’t available." />
  ),
})

function RootComponent() {
  useEffect(() => {
    const releaseLogging = retainInlineGlobalLogging()
    if (import.meta.env.DEV) void import("virtual:stylex:runtime")
    return releaseLogging
  }, [])

  return (
    <RootDocument>
      <Outlet />
    </RootDocument>
  )
}

function RootRouteError({
  error,
  reset,
}: {
  error: unknown
  reset: () => void
}) {
  useEffect(() => {
    logInlineRouteError("root", error)
  }, [error])
  return (
    <RootDocument>
      <RoutePlaceholderView
        title={inlineRouteErrorTitle(
          error,
          "Inline couldn’t open this view.",
        )}
        actionTitle="Try Again"
        onAction={reset}
      />
    </RootDocument>
  )
}

function RootDocument({ children }: { children: ReactNode }) {
  return (
    <html lang="en" suppressHydrationWarning>
      <head>
        <HeadContent />
        <script
          dangerouslySetInnerHTML={{
            __html: resizeObserverErrorSuppressionScript,
          }}
        />
        <script
          dangerouslySetInnerHTML={{
            __html: inlineAppearanceBootstrapScript,
          }}
        />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
