import * as React from "react"
import { Slot } from "@radix-ui/react-slot"
import { cva, type VariantProps } from "class-variance-authority"
import { cn } from "@/lib/utils"

const SIDEBAR_COOKIE_NAME = "sidebar:state"
const SIDEBAR_COOKIE_MAX_AGE = 60 * 60 * 24 * 7

type SidebarContextValue = {
  open: boolean
  setOpen: (open: boolean) => void
  openMobile: boolean
  setOpenMobile: (open: boolean) => void
  isMobile: boolean
  toggleSidebar: () => void
}

const SidebarContext = React.createContext<SidebarContextValue | null>(null)

const useMediaQuery = (query: string) => {
  const [matches, setMatches] = React.useState(false)

  React.useEffect(() => {
    const media = window.matchMedia(query)
    const listener = () => setMatches(media.matches)
    listener()
    media.addEventListener("change", listener)
    return () => media.removeEventListener("change", listener)
  }, [query])

  return matches
}

export const SidebarProvider = ({
  defaultOpen = true,
  children,
}: {
  defaultOpen?: boolean
  children: React.ReactNode
}) => {
  const isMobile = useMediaQuery("(max-width: 768px)")
  const [open, setOpen] = React.useState(defaultOpen)
  const [openMobile, setOpenMobile] = React.useState(false)

  const toggleSidebar = React.useCallback(() => {
    if (isMobile) {
      setOpenMobile((prev) => !prev)
      return
    }
    setOpen((prev) => !prev)
  }, [isMobile])

  React.useEffect(() => {
    if (typeof document === "undefined") return
    const value = open ? "1" : "0"
    document.cookie = `${SIDEBAR_COOKIE_NAME}=${value}; path=/; max-age=${SIDEBAR_COOKIE_MAX_AGE}`
  }, [open])

  const value = React.useMemo<SidebarContextValue>(
    () => ({
      open,
      setOpen,
      openMobile,
      setOpenMobile,
      isMobile,
      toggleSidebar,
    }),
    [open, openMobile, isMobile, toggleSidebar],
  )

  return <SidebarContext.Provider value={value}>{children}</SidebarContext.Provider>
}

export const useSidebar = () => {
  const context = React.useContext(SidebarContext)
  if (!context) {
    throw new Error("useSidebar must be used within SidebarProvider")
  }
  return context
}

const sidebarVariants = cva(
  "group/sidebar flex h-svh flex-col bg-sidebar text-sidebar-foreground transition-[width] duration-200",
  {
    variants: {
      variant: {
        default: "border-r border-sidebar-border",
        floating: "rounded-2xl border border-sidebar-border shadow-sm",
      },
    },
    defaultVariants: {
      variant: "default",
    },
  },
)

export const Sidebar = React.forwardRef<
  HTMLDivElement,
  React.ComponentProps<"div"> & VariantProps<typeof sidebarVariants>
>(({ className, variant, ...props }, ref) => {
  const { open, openMobile, isMobile, setOpenMobile } = useSidebar()
  const state = open ? "expanded" : "collapsed"

  if (isMobile) {
    if (!openMobile) return null
    return (
      <div className="fixed inset-0 z-50 flex bg-black/20 p-3" onClick={() => setOpenMobile(false)}>
        <div
          className={cn(sidebarVariants({ variant }), "w-[18rem]", className)}
          data-state={state}
          data-collapsible={open ? "" : "icon"}
          onClick={(event) => event.stopPropagation()}
          ref={ref}
          {...props}
        />
      </div>
    )
  }

  return (
    <div
      ref={ref}
      data-state={state}
      data-collapsible={open ? "" : "icon"}
      className={cn(
        sidebarVariants({ variant }),
        open ? "w-[18rem]" : "w-[4.5rem]",
        className,
      )}
      {...props}
    />
  )
})

Sidebar.displayName = "Sidebar"

export const SidebarHeader = React.forwardRef<HTMLDivElement, React.ComponentProps<"div">>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={cn("flex items-center gap-3 px-4 py-3", className)} {...props} />
  ),
)

SidebarHeader.displayName = "SidebarHeader"

export const SidebarContent = React.forwardRef<HTMLDivElement, React.ComponentProps<"div">>(
  ({ className, ...props }, ref) => (
    <div
      ref={ref}
      className={cn("flex min-h-0 flex-1 flex-col gap-4 overflow-auto px-2", className)}
      {...props}
    />
  ),
)

SidebarContent.displayName = "SidebarContent"

export const SidebarFooter = React.forwardRef<HTMLDivElement, React.ComponentProps<"div">>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={cn("mt-auto px-2 pb-4", className)} {...props} />
  ),
)

SidebarFooter.displayName = "SidebarFooter"

export const SidebarInset = React.forwardRef<HTMLDivElement, React.ComponentProps<"div">>(
  ({ className, ...props }, ref) => (
    <div ref={ref} className={cn("flex min-h-svh flex-1 flex-col", className)} {...props} />
  ),
)

SidebarInset.displayName = "SidebarInset"

export const SidebarMenu = React.forwardRef<HTMLUListElement, React.ComponentProps<"ul">>(
  ({ className, ...props }, ref) => (
    <ul ref={ref} className={cn("flex flex-col gap-1", className)} {...props} />
  ),
)

SidebarMenu.displayName = "SidebarMenu"

export const SidebarMenuItem = React.forwardRef<HTMLLIElement, React.ComponentProps<"li">>(
  ({ className, ...props }, ref) => <li ref={ref} className={cn("", className)} {...props} />,
)

SidebarMenuItem.displayName = "SidebarMenuItem"

const sidebarMenuButtonVariants = cva(
  "flex w-full items-center gap-2 rounded-[var(--radius)] px-2.5 py-2 text-[13px] font-medium text-sidebar-foreground/80 transition-colors hover:bg-sidebar-accent hover:text-sidebar-accent-foreground data-[active=true]:bg-sidebar-accent data-[active=true]:text-sidebar-accent-foreground",
  {
    variants: {
      size: {
        default: "",
        sm: "py-1.5 text-[12px]",
        lg: "py-2.5 text-sm",
      },
    },
    defaultVariants: {
      size: "default",
    },
  },
)

type SidebarMenuButtonProps = React.ButtonHTMLAttributes<HTMLButtonElement> &
  VariantProps<typeof sidebarMenuButtonVariants> & {
    asChild?: boolean
    isActive?: boolean
  }

export const SidebarMenuButton = React.forwardRef<HTMLButtonElement, SidebarMenuButtonProps>(
  ({ asChild, className, size, isActive, ...props }, ref) => {
    const Comp = asChild ? Slot : "button"
    return (
      <Comp
        ref={ref}
        data-active={isActive ? "true" : "false"}
        className={cn(sidebarMenuButtonVariants({ size }), className)}
        {...props}
      />
    )
  },
)

SidebarMenuButton.displayName = "SidebarMenuButton"

export const SidebarTrigger = React.forwardRef<HTMLButtonElement, React.ButtonHTMLAttributes<HTMLButtonElement>>(
  ({ className, ...props }, ref) => {
    const { toggleSidebar } = useSidebar()
    return (
      <button
        ref={ref}
        type="button"
        onClick={toggleSidebar}
        className={cn(
          "inline-flex h-8 w-8 items-center justify-center rounded-[var(--radius)] border border-sidebar-border bg-sidebar text-sidebar-foreground/70 hover:text-sidebar-foreground",
          className,
        )}
        {...props}
      >      
        <span className="text-sm">|||</span>
      </button>
    )
  },
)

SidebarTrigger.displayName = "SidebarTrigger"
