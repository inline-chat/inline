/** Icons for the window chrome. Inline SVG with `currentColor`; decorative (the button carries the name). */

export function SidebarIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" fill="none" aria-hidden="true" focusable="false">
      <rect x="1.75" y="2.75" width="12.5" height="10.5" rx="2" stroke="currentColor" strokeWidth="1.3" />
      <path d="M6 3v10" stroke="currentColor" strokeWidth="1.3" />
    </svg>
  )
}

export function UpdateIcon() {
  return (
    <svg width="14" height="14" viewBox="0 0 16 16" fill="none" aria-hidden="true" focusable="false">
      <path d="M8 2.5v8M4.5 7 8 10.5 11.5 7M3 13.5h10" stroke="currentColor" strokeWidth="1.4" strokeLinecap="round" strokeLinejoin="round" />
    </svg>
  )
}

/** The composer's emoji button (a smiling face), the same glyph as the emoji feature's own button. */
export function EmojiIcon() {
  return (
    <svg width="16" height="16" viewBox="0 0 16 16" aria-hidden="true" focusable="false">
      <circle cx="8" cy="8" r="6.25" fill="none" stroke="currentColor" strokeWidth="1.3" />
      <path d="M5.4 9.6c.6.9 1.5 1.4 2.6 1.4s2-.5 2.6-1.4" fill="none" stroke="currentColor" strokeWidth="1.3" strokeLinecap="round" />
      <circle cx="6" cy="6.6" r=".9" fill="currentColor" />
      <circle cx="10" cy="6.6" r=".9" fill="currentColor" />
    </svg>
  )
}
