type IconProps = {
  size?: number
  strokeWidth?: number
  className?: string
}

function baseProps({ size = 18, strokeWidth = 1.8, className }: IconProps) {
  return {
    width: size,
    height: size,
    viewBox: "0 0 24 24",
    fill: "none",
    stroke: "currentColor",
    strokeWidth,
    strokeLinecap: "round" as const,
    strokeLinejoin: "round" as const,
    className,
  }
}

// These are Lucide-style SVG paths (lucide.dev), embedded locally to avoid extra deps.
export function SunIcon(props: IconProps) {
  const p = baseProps(props)
  return (
    <svg {...p}>
      <circle cx="12" cy="12" r="4" />
      <path d="M12 2v2" />
      <path d="M12 20v2" />
      <path d="m4.93 4.93 1.41 1.41" />
      <path d="m17.66 17.66 1.41 1.41" />
      <path d="M2 12h2" />
      <path d="M20 12h2" />
      <path d="m6.34 17.66-1.41 1.41" />
      <path d="m19.07 4.93-1.41 1.41" />
    </svg>
  )
}

export function MoonIcon(props: IconProps) {
  const p = baseProps(props)
  return (
    <svg {...p}>
      <path d="M12 3a7.5 7.5 0 1 0 9 9 9 9 0 0 1-9-9Z" />
    </svg>
  )
}

export function CopyIcon(props: IconProps) {
  const p = baseProps(props)
  return (
    <svg {...p}>
      <rect x="9" y="9" width="13" height="13" rx="2" ry="2" />
      <path d="M5 15H4a2 2 0 0 1-2-2V4a2 2 0 0 1 2-2h9a2 2 0 0 1 2 2v1" />
    </svg>
  )
}

export function CheckIcon(props: IconProps) {
  const p = baseProps(props)
  return (
    <svg {...p}>
      <path d="M20 6 9 17l-5-5" />
    </svg>
  )
}

