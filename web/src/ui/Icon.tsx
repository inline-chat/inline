import * as stylex from "@stylexjs/stylex"

export type IconName =
  | "archive"
  | "arrowUp"
  | "at"
  | "back"
  | "bell"
  | "bubble"
  | "check"
  | "chevronDown"
  | "envelope"
  | "eye"
  | "forward"
  | "gear"
  | "home"
  | "link"
  | "members"
  | "more"
  | "newThread"
  | "numbers"
  | "person"
  | "phone"
  | "pin"
  | "plus"
  | "search"
  | "sliders"
  | "ticket"
  | "xmark"

const paths: Record<IconName, string> = {
  archive: "M4 7h16v14H4V7Zm-1-4h18v4H3V3Zm6 8h6",
  arrowUp: "M12 19V5m0 0-6 6m6-6 6 6",
  at: "M16 8.5v5a2.5 2.5 0 0 0 5 0V12a9 9 0 1 0-3.1 6.8M16 12a4 4 0 1 1-8 0 4 4 0 0 1 8 0Z",
  back: "m15 18-6-6 6-6",
  bell: "M18 8a6 6 0 0 0-12 0c0 7-3 7-3 9h18c0-2-3-2-3-9M10 21h4",
  bubble: "M21 12a8 8 0 0 1-8 8H5l-2 2v-8a8 8 0 1 1 18-2Z",
  check: "m5 12 4 4L19 6",
  chevronDown: "m7 10 5 5 5-5",
  envelope: "M4 5h16v14H4V5Zm0 1 8 7 8-7",
  eye: "M2.5 12s3.5-6 9.5-6 9.5 6 9.5 6-3.5 6-9.5 6-9.5-6-9.5-6Zm9.5 3a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z",
  forward: "m9 18 6-6-6-6",
  gear:
    "M12 15.5a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7ZM19.4 15a1.7 1.7 0 0 0 .3 1.9l.1.1-2.8 2.8-.1-.1a1.7 1.7 0 0 0-1.9-.3 1.7 1.7 0 0 0-1 1.5V21h-4v-.1a1.7 1.7 0 0 0-1-1.5 1.7 1.7 0 0 0-1.9.3l-.1.1L4.2 17l.1-.1a1.7 1.7 0 0 0 .3-1.9 1.7 1.7 0 0 0-1.5-1H3v-4h.1a1.7 1.7 0 0 0 1.5-1 1.7 1.7 0 0 0-.3-1.9L4.2 7 7 4.2l.1.1a1.7 1.7 0 0 0 1.9.3 1.7 1.7 0 0 0 1-1.5V3h4v.1a1.7 1.7 0 0 0 1 1.5 1.7 1.7 0 0 0 1.9-.3l.1-.1L19.8 7l-.1.1a1.7 1.7 0 0 0-.3 1.9 1.7 1.7 0 0 0 1.5 1h.1v4h-.1a1.7 1.7 0 0 0-1.5 1Z",
  home: "m3 11 9-8 9 8v10h-6v-6H9v6H3V11Z",
  link: "M10 13a5 5 0 0 0 7.1.1l2-2a5 5 0 0 0-7.1-7.1l-1.1 1.1M14 11a5 5 0 0 0-7.1-.1l-2 2A5 5 0 0 0 12 20l1.1-1.1",
  members: "M16 21v-2a4 4 0 0 0-4-4H6a4 4 0 0 0-4 4v2M9 11a4 4 0 1 0 0-8 4 4 0 0 0 0 8Zm13 10v-2a4 4 0 0 0-3-3.87M16 3.13a4 4 0 0 1 0 7.75",
  more: "M5 12h.01M12 12h.01M19 12h.01",
  newThread: "M14 5h5v5M13 6H6a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h10a2 2 0 0 0 2-2v-7M21 3l-9 9-3 1 1-3 9-9 2 2Z",
  numbers: "M10 3 8 21M16 3l-2 18M4 9h16M3 15h16",
  person: "M20 21a8 8 0 0 0-16 0M12 13a5 5 0 1 0 0-10 5 5 0 0 0 0 10Z",
  phone: "M22 16.9v3a2 2 0 0 1-2.2 2 19.8 19.8 0 0 1-8.6-3.1 19.5 19.5 0 0 1-6-6A19.8 19.8 0 0 1 2.1 4.2 2 2 0 0 1 4.1 2h3a2 2 0 0 1 2 1.7c.1 1 .4 2 .7 2.9a2 2 0 0 1-.5 2.1L8 10a16 16 0 0 0 6 6l1.3-1.3a2 2 0 0 1 2.1-.5c.9.3 1.9.6 2.9.7a2 2 0 0 1 1.7 2Z",
  pin: "M12 17v5M5 3h14l-2 5v4l2 2H5l2-2V8L5 3Z",
  plus: "M12 5v14M5 12h14",
  search: "m21 21-4.3-4.3M19 11a8 8 0 1 1-16 0 8 8 0 0 1 16 0Z",
  sliders: "M4 21v-7m0-4V3m8 18v-9m0-4V3m8 18v-5m0-4V3M1 14h6M9 8h6m2 8h6",
  ticket: "M2 9a3 3 0 0 0 0 6v4h20v-4a3 3 0 0 0 0-6V9a3 3 0 0 0 0-6V5H2v4Z",
  xmark: "M6 6l12 12M18 6 6 18",
}

export function Icon({ name, size = 16 }: { name: IconName; size?: number }) {
  return (
    <svg
      aria-hidden="true"
      viewBox="0 0 24 24"
      width={size}
      height={size}
      fill="none"
      stroke="currentColor"
      strokeWidth="1.8"
      strokeLinecap="round"
      strokeLinejoin="round"
      {...stylex.props(styles.icon)}
    >
      <path d={paths[name]} />
    </svg>
  )
}

const styles = stylex.create({
  icon: {
    display: "block",
    flexShrink: 0,
  },
})
