/** Settings page icons: 16px line drawings in `currentColor`, decorative (the title names the page). */

import type { ReactNode } from "react"
import type { SettingsIcon } from "./catalog"

function Glyph(props: { children: ReactNode }) {
  return (
    <svg
      aria-hidden="true"
      width="16"
      height="16"
      viewBox="0 0 16 16"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.3"
      strokeLinecap="round"
      strokeLinejoin="round"
    >
      {props.children}
    </svg>
  )
}

const paths: Record<SettingsIcon, ReactNode> = {
  account: (
    <>
      <circle cx="8" cy="5.5" r="2.5" />
      <path d="M3 13.5c.6-2.4 2.6-3.8 5-3.8s4.4 1.4 5 3.8" />
    </>
  ),
  general: (
    <>
      <circle cx="8" cy="8" r="2.2" />
      <path d="M8 1.8v1.6M8 12.6v1.6M1.8 8h1.6M12.6 8h1.6M3.6 3.6l1.1 1.1M11.3 11.3l1.1 1.1M3.6 12.4l1.1-1.1M11.3 4.7l1.1-1.1" />
    </>
  ),
  appearance: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 2a6 6 0 0 0 0 12z" fill="currentColor" stroke="none" />
    </>
  ),
  notifications: (
    <>
      <path d="M4 11V7.5a4 4 0 0 1 8 0V11l1 1.2H3z" />
      <path d="M6.6 14a1.5 1.5 0 0 0 2.8 0" />
    </>
  ),
  data: (
    <>
      <ellipse cx="8" cy="4" rx="5" ry="2" />
      <path d="M3 4v8c0 1.1 2.2 2 5 2s5-.9 5-2V4M3 8c0 1.1 2.2 2 5 2s5-.9 5-2" />
    </>
  ),
  shortcuts: (
    <>
      <rect x="1.8" y="4" width="12.4" height="8" rx="1.5" />
      <path d="M4.5 6.5h.01M7 6.5h.01M9.5 6.5h.01M12 6.5h-.01M5 9.5h6" />
    </>
  ),
  about: (
    <>
      <circle cx="8" cy="8" r="6" />
      <path d="M8 7.2V11M8 5h.01" />
    </>
  ),
}

export function PageIcon(props: { icon: SettingsIcon }) {
  return <Glyph>{paths[props.icon]}</Glyph>
}

export function BackIcon() {
  return (
    <Glyph>
      <path d="M10 3.5 5.5 8l4.5 4.5" />
    </Glyph>
  )
}
