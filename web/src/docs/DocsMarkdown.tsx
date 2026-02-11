import Markdown from "react-markdown"
import remarkGfm from "remark-gfm"
import { Link } from "@tanstack/react-router"
import type { ReactNode } from "react"
import { useEffect, useRef, useState } from "react"
import { CheckIcon, CopyIcon } from "~/docs/lucide"

type DocsMarkdownProps = {
  markdown: string
  className?: string
}

type Slugger = {
  slug: (text: string) => string
}

function createSlugger(): Slugger {
  const used = new Map<string, number>()

  const slugify = (text: string) => {
    const base = text
      .trim()
      .toLowerCase()
      .replace(/['"]/g, "")
      .replace(/[^a-z0-9]+/g, "-")
      .replace(/^-+|-+$/g, "")

    const safe = base.length > 0 ? base : "section"
    const count = used.get(safe) ?? 0
    used.set(safe, count + 1)
    return count === 0 ? safe : `${safe}-${count + 1}`
  }

  return { slug: slugify }
}

function nodeText(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") return ""
  if (typeof node === "string" || typeof node === "number") return String(node)
  if (Array.isArray(node)) return node.map(nodeText).join("")
  // @ts-expect-error - react-markdown passes ReactElements; we only care about their children.
  return nodeText(node.props?.children)
}

function isExternalHref(href: string) {
  return /^(https?:)?\/\//i.test(href) || href.startsWith("mailto:") || href.startsWith("tel:")
}

function PreWithCopy({ children, ...props }: { children?: ReactNode; [key: string]: unknown }) {
  const [copied, setCopied] = useState(false)

  const codeText = nodeText(children).replace(/\n$/, "")

  return (
    <div className="docs-codeblock">
      <button
        type="button"
        className="docs-codeblock-copy"
        aria-label="Copy code"
        onClick={async () => {
          try {
            await navigator.clipboard.writeText(codeText)
            setCopied(true)
            setTimeout(() => setCopied(false), 900)
          } catch {
            // If clipboard is unavailable, fail silently.
          }
        }}
      >
        {copied ? <CheckIcon size={16} /> : <CopyIcon size={16} />}
      </button>
      {/* eslint-disable-next-line react/jsx-props-no-spreading */}
      <pre {...props}>{children}</pre>
    </div>
  )
}

export function DocsMarkdown({ markdown, className }: DocsMarkdownProps) {
  const slugger = createSlugger()
  const [copiedEmail, setCopiedEmail] = useState<string | null>(null)
  const copiedEmailTimeout = useRef<number | null>(null)

  useEffect(() => {
    return () => {
      if (copiedEmailTimeout.current !== null) {
        window.clearTimeout(copiedEmailTimeout.current)
      }
    }
  }, [])

  const heading =
    (Tag: "h1" | "h2" | "h3" | "h4") =>
    // eslint-disable-next-line react/display-name
    ({ children }: { children?: ReactNode }) => {
      const text = nodeText(children)
      const id = slugger.slug(text)
      return (
        <Tag id={id} className="docs-heading">
          <a className="docs-heading-link" href={`#${id}`}>
            {children}
          </a>
        </Tag>
      )
    }

  return (
    <Markdown
      remarkPlugins={[remarkGfm]}
      className={className}
      components={{
        h1: heading("h1"),
        h2: heading("h2"),
        h3: heading("h3"),
        h4: heading("h4"),
        a: ({ href, children, ...props }) => {
          const safeHref = href ?? ""

          if (safeHref.startsWith("mailto:")) {
            const email = decodeURIComponent(safeHref.slice("mailto:".length).split("?")[0] ?? "")
            const isCopied = copiedEmail === email

            return (
              <button
                type="button"
                className="docs-email-copy"
                data-copied={isCopied ? "true" : undefined}
                onClick={async () => {
                  if (!email) return
                  try {
                    await navigator.clipboard.writeText(email)
                    setCopiedEmail(email)
                    if (copiedEmailTimeout.current !== null) {
                      window.clearTimeout(copiedEmailTimeout.current)
                    }
                    copiedEmailTimeout.current = window.setTimeout(() => {
                      setCopiedEmail(null)
                    }, 900)
                  } catch {
                    // If clipboard is unavailable, fail silently.
                  }
                }}
              >
                {children}
                {isCopied ? " copied" : ""}
              </button>
            )
          }

          if (!safeHref || safeHref.startsWith("#") || isExternalHref(safeHref)) {
            return (
              <a href={href} {...props}>
                {children}
              </a>
            )
          }

          if (safeHref.startsWith("/")) {
            return (
              <Link to={safeHref} {...props}>
                {children}
              </Link>
            )
          }

          // Fallback: treat as external/relative URL handled by the browser.
          return (
            <a href={href} {...props}>
              {children}
            </a>
          )
        },
        img: ({ src, alt, ...props }) => {
          // eslint-disable-next-line jsx-a11y/alt-text
          return <img src={src} alt={alt ?? ""} loading="lazy" {...props} />
        },
        pre: ({ children, ...props }) => <PreWithCopy {...props}>{children}</PreWithCopy>,
      }}
    >
      {markdown}
    </Markdown>
  )
}
