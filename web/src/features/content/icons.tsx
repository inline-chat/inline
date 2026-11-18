/**
 * Small glyphs for message content, drawn as inline SVG elements (never HTML
 * strings). They take the current text color and are hidden from assistive
 * technology; the control around them carries the name.
 */

import type { FileIcon } from "@inline/chat-ui"
import type { ReactNode } from "react"

const Svg = (props: { size?: number; children: ReactNode; viewBox?: string }) => (
  <svg
    width={props.size ?? 16}
    height={props.size ?? 16}
    viewBox={props.viewBox ?? "0 0 16 16"}
    fill="none"
    stroke="currentColor"
    strokeWidth="1.5"
    strokeLinecap="round"
    strokeLinejoin="round"
    aria-hidden="true"
    focusable="false"
  >
    {props.children}
  </svg>
)

export const PlayIcon = (props: { size?: number }) => (
  <Svg size={props.size}>
    <path d="M5 3.2v9.6L12.6 8z" fill="currentColor" stroke="none" />
  </Svg>
)

export const PauseIcon = (props: { size?: number }) => (
  <Svg size={props.size}>
    <path d="M4.5 3h2.2v10H4.5zM9.3 3h2.2v10H9.3z" fill="currentColor" stroke="none" />
  </Svg>
)

export const DownloadIcon = () => (
  <Svg>
    <path d="M8 2.5v8M4.8 7.6 8 10.8l3.2-3.2M3 13.2h10" />
  </Svg>
)

export const RetryIcon = () => (
  <Svg>
    <path d="M12.8 8a4.8 4.8 0 1 1-1.5-3.5M12.8 2.6v2.9H9.9" />
  </Svg>
)

export const CancelIcon = (props: { size?: number }) => (
  <Svg size={props.size}>
    <path d="M4.5 4.5l7 7M11.5 4.5l-7 7" />
  </Svg>
)

export const CopyIcon = () => (
  <Svg>
    <rect x="5.5" y="5.5" width="8" height="8" rx="1.6" />
    <path d="M10.5 5.5V3.9c0-.8-.6-1.4-1.4-1.4H3.9c-.8 0-1.4.6-1.4 1.4v5.2c0 .8.6 1.4 1.4 1.4h1.6" />
  </Svg>
)

export const CheckIcon = (props: { size?: number }) => (
  <Svg size={props.size}>
    <path d="m3.5 8.5 3 3 6-7" />
  </Svg>
)

export const ChevronIcon = () => (
  <Svg size={12} viewBox="0 0 12 12">
    <path d="m4.5 2.5 3.5 3.5-3.5 3.5" />
  </Svg>
)

export const ExternalIcon = () => (
  <Svg size={12} viewBox="0 0 12 12">
    <path d="M4.5 2.5h5v5M9.5 2.5 3 9" />
  </Svg>
)

export const ImageOffIcon = () => (
  <Svg size={20}>
    <rect x="2" y="3" width="12" height="10" rx="1.6" />
    <path d="m2.5 11 3.2-3.2 2.4 2.4 1.6-1.6 3.8 3.4M2 2l12 12" />
  </Svg>
)

export const WarningIcon = (props: { size?: number }) => (
  <Svg size={props.size ?? 12}>
    <path d="M8 2.2 14.3 13.3H1.7z" />
    <path d="M8 6.5v3M8 11.5v.1" />
  </Svg>
)

export const StopIcon = (props: { size?: number }) => (
  <Svg size={props.size ?? 12}>
    <circle cx="8" cy="8" r="5.8" />
    <path d="m4 12 8-8" />
  </Svg>
)

export const ClockIcon = (props: { size?: number }) => (
  <Svg size={props.size ?? 12}>
    <circle cx="8" cy="8" r="5.8" />
    <path d="M8 4.8V8l2.2 1.4" />
  </Svg>
)

export const CircleIcon = (props: { size?: number; filled?: boolean }) => (
  <Svg size={props.size ?? 12}>
    <circle cx="8" cy="8" r="5.5" fill={props.filled ? "currentColor" : "none"} />
  </Svg>
)

const filePaths: Record<FileIcon, ReactNode> = {
  pdf: <path d="M5 9.5h1.2a1 1 0 0 0 0-2H5v4M8.5 7.5v4h.8a2 2 0 0 0 0-4zM12 11.5v-4h1.6M12 9.5h1.2" strokeWidth="1.1" />,
  image: (
    <>
      <circle cx="6" cy="6.2" r="1.1" />
      <path d="m3.5 12 3.2-3 2 2 1.6-1.4L13 12" />
    </>
  ),
  video: <path d="M6.5 6v4.2L10 8.1z" fill="currentColor" stroke="none" />,
  audio: <path d="M6.5 11V5.5l4-1V10M6.5 11a1.2 1.2 0 1 1-2.4 0 1.2 1.2 0 0 1 2.4 0zM10.5 10a1.2 1.2 0 1 1-2.4 0 1.2 1.2 0 0 1 2.4 0z" />,
  archive: <path d="M8 3v1.2M8 5.4v1.2M8 7.8V9M7 10.2h2v2H7z" />,
  code: <path d="M6.2 5.8 4 8l2.2 2.2M9.8 5.8 12 8l-2.2 2.2" />,
  text: <path d="M5 5.5h6M5 8h6M5 10.5h4" />,
  spreadsheet: <path d="M4.5 5h7v6.5h-7zM4.5 7.2h7M4.5 9.4h7M7.2 5v6.5" />,
  presentation: <path d="M4 5h8v5H4zM8 10v2M6.5 12h3" />,
  document: <path d="M5 5.5h6M5 8h6M5 10.5h6" />,
}

/** The glyph inside a document row's circle. */
export const FileKindIcon = (props: { icon: FileIcon }) => <Svg size={18}>{filePaths[props.icon]}</Svg>
