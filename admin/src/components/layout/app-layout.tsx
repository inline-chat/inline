import { Link, Outlet, useNavigate } from "@tanstack/react-router"
import { useEffect } from "react"
import { useAdmin } from "@/state/admin"
import { Button } from "@/components/ui/button"
import {
  Sidebar,
  SidebarContent,
  SidebarFooter,
  SidebarHeader,
  SidebarInset,
  SidebarMenu,
  SidebarMenuButton,
  SidebarMenuItem,
  SidebarProvider,
  SidebarTrigger,
} from "@/components/ui/sidebar"

const navItems = [
  { label: "Overview", to: "/" },
  { label: "Technical", to: "/metrics/technical" },
  { label: "App Metrics", to: "/metrics/app" },
  { label: "Users", to: "/users" },
  { label: "Spaces", to: "/spaces" },
  { label: "Waitlist", to: "/waitlist" },
  { label: "Settings", to: "/settings" },
]

export const AppLayout = () => {
  const { session, status, needsSetup, signOut } = useAdmin()
  const navigate = useNavigate()

  useEffect(() => {
    if (status === "ready" && !session) {
      void navigate({ to: "/login", replace: true })
    }
  }, [navigate, session, status])

  useEffect(() => {
    if (status === "ready" && session && needsSetup) {
      void navigate({ to: "/setup", replace: true })
    }
  }, [navigate, needsSetup, session, status])

  if (!session) {
    return null
  }

  return (
    <SidebarProvider defaultOpen>
      <div className="flex h-svh w-full bg-background text-foreground overflow-hidden">
        <Sidebar className="sticky top-0 h-svh">
          <SidebarHeader className="gap-2">
            <div className="flex items-center gap-2">
              <div className="rounded-full bg-foreground px-2 py-1">
                <img src="/logotype-white.svg" alt="Inline" className="h-4 w-auto" />
              </div>
              <div className="group-data-[collapsible=icon]/sidebar:hidden">
                <div className="text-[16px] font-bold tracking-tight">Admin</div>
              </div>
            </div>
          </SidebarHeader>
          <SidebarContent>
            <SidebarMenu>
              {navItems.map((item) => (
                <SidebarMenuItem key={item.to}>
                  <SidebarMenuButton asChild>
                    <Link
                      to={item.to}
                      className="w-full justify-start"
                      activeProps={{ className: "bg-sidebar-accent text-sidebar-accent-foreground" }}
                    >
                      {item.label}
                    </Link>
                  </SidebarMenuButton>
                </SidebarMenuItem>
              ))}
            </SidebarMenu>
          </SidebarContent>
          <SidebarFooter>
            <Button variant="ghost" onClick={signOut} className="w-full justify-start text-[13px]">
              Sign out
            </Button>
          </SidebarFooter>
        </Sidebar>
        <SidebarInset className="min-h-0 overflow-y-auto">
          <SidebarTrigger className="fixed left-4 top-4 z-20 md:hidden" />
          <main className="mx-auto flex w-full max-w-6xl flex-1 flex-col gap-8 px-6 py-6 text-[13px]">
            <Outlet />
          </main>
        </SidebarInset>
      </div>
    </SidebarProvider>
  )
}
