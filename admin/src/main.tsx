import { StrictMode, useEffect } from "react"
import { createRoot } from "react-dom/client"
import { RouterProvider } from "@tanstack/react-router"
import { getRouter } from "@/router"
import { AdminProvider, useAdmin } from "@/state/admin"
import "@/index.css"

const router = getRouter()

const Bootstrap = () => {
  const { refresh, status } = useAdmin()

  useEffect(() => {
    void refresh()
  }, [refresh])

  if (status === "loading") {
    return <div className="grid min-h-screen place-items-center text-sm text-muted-foreground">Loading...</div>
  }

  return <RouterProvider router={router} />
}

const root = document.getElementById("root")
if (root) {
  createRoot(root).render(
    <StrictMode>
      <AdminProvider>
        <Bootstrap />
      </AdminProvider>
    </StrictMode>,
  )
}
