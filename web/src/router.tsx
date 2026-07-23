import { createRouter } from "@tanstack/react-router"
import { routeTree } from "./routeTree.gen"

export function getRouter() {
  const router = createRouter({
    routeTree,
    scrollRestoration: false,
    defaultPreload: false,
  })
  if (import.meta.env.DEV && typeof window !== "undefined") {
    Object.defineProperty(window, "__inlineRouter", {
      configurable: true,
      value: router,
    })
  }
  return router
}

declare global {
  interface Window {
    __inlineRouter?: ReturnType<typeof createRouter>
  }
}

declare module "@tanstack/react-router" {
  interface Register {
    router: ReturnType<typeof getRouter>
  }
}
