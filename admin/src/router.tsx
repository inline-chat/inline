import { createRouter } from "@tanstack/react-router"
import { routeTree } from "./routeTree.gen"

export const getRouter = () => {
  const router = createRouter({
    routeTree,
    scrollRestoration: true,
  })

  return router
}
