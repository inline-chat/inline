export type LegalNavGroup = {
  title: string
  items: Array<{
    title: string
    to: string
  }>
}

export const LEGAL_NAV: LegalNavGroup[] = [
  {
    title: "Legal",
    items: [
      { title: "Overview", to: "/legal" },
      { title: "Privacy", to: "/legal/privacy" },
      { title: "Terms", to: "/legal/terms" },
      { title: "Acceptable Use", to: "/legal/aup" },
      { title: "Subprocessors", to: "/legal/subprocessors" },
      { title: "DPA", to: "/legal/dpa" },
    ],
  },
]
