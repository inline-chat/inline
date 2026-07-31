import Markdown from "react-markdown"
import remarkGfm from "remark-gfm"
import { Link } from "@tanstack/react-router"
import hljs from "highlight.js/lib/core"
import bash from "highlight.js/lib/languages/bash"
import javascript from "highlight.js/lib/languages/javascript"
import json from "highlight.js/lib/languages/json"
import plaintext from "highlight.js/lib/languages/plaintext"
import rust from "highlight.js/lib/languages/rust"
import toml from "highlight.js/lib/languages/ini"
import typescript from "highlight.js/lib/languages/typescript"
import xml from "highlight.js/lib/languages/xml"
import yaml from "highlight.js/lib/languages/yaml"
import { Children, isValidElement, type ReactNode } from "react"
import { useEffect, useId, useRef, useState } from "react"
import { CheckIcon, CopyIcon } from "~/docs/lucide"
import { emailFallback, emailParts } from "~/lib/email"

hljs.registerLanguage("bash", bash)
hljs.registerLanguage("javascript", javascript)
hljs.registerLanguage("json", json)
hljs.registerLanguage("plaintext", plaintext)
hljs.registerLanguage("rust", rust)
hljs.registerLanguage("toml", toml)
hljs.registerLanguage("typescript", typescript)
hljs.registerLanguage("xml", xml)
hljs.registerLanguage("yaml", yaml)

type DocsMarkdownProps = {
  markdown: string
  className?: string
  renderVideoLinks?: boolean
}

type Slugger = {
  slug: (text: string) => string
}

type TocItem = {
  id: string
  level: 2 | 3
  text: string
}

type MarkdownNode = {
  type: string
  depth?: number
  value?: string
  children?: MarkdownNode[]
  data?: {
    hName?: string
    hProperties?: Record<string, string>
  }
}

const LANGUAGE_ALIASES: Record<string, string> = {
  html: "xml",
  js: "javascript",
  jsx: "javascript",
  sh: "bash",
  shell: "bash",
  text: "plaintext",
  ts: "typescript",
  tsx: "typescript",
  yml: "yaml",
}

const LANGUAGE_LABELS: Record<string, string> = {
  bash: "Terminal",
  javascript: "JavaScript",
  json: "JSON",
  plaintext: "Text",
  rust: "Rust",
  toml: "TOML",
  typescript: "TypeScript",
  xml: "HTML",
  yaml: "YAML",
}

function remarkCodeTabs() {
  return (tree: MarkdownNode) => {
    const children = tree.children
    if (!children) return

    for (let index = 0; index < children.length; index += 1) {
      const labels: string[] = []
      const codeNodes: MarkdownNode[] = []
      let cursor = index

      while (
        children[cursor]?.type === "heading" &&
        children[cursor]?.depth === 4 &&
        children[cursor + 1]?.type === "code"
      ) {
        const heading = children[cursor]
        labels.push(nodeTextFromMarkdown(heading))
        codeNodes.push(children[cursor + 1])
        cursor += 2
      }

      if (codeNodes.length < 2) continue

      children.splice(index, cursor - index, {
        type: "blockquote",
        children: codeNodes,
        data: {
          hName: "div",
          hProperties: {
            className: "docs-code-tabs",
            "data-labels": JSON.stringify(labels),
          },
        },
      })
    }
  }
}

function nodeTextFromMarkdown(node: MarkdownNode): string {
  if (typeof node.value === "string") return node.value
  return node.children?.map(nodeTextFromMarkdown).join("") ?? ""
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

function extractToc(markdown: string): TocItem[] {
  const slugger = createSlugger()
  const items: TocItem[] = []
  let inFence = false

  for (const line of markdown.split("\n")) {
    if (/^\s*```/.test(line)) {
      inFence = !inFence
      continue
    }

    if (inFence) continue

    const match = /^(#{1,4})\s+(.+?)\s*#*\s*$/.exec(line)
    if (!match) continue

    const level = match[1].length
    const text = match[2].replace(/\[([^\]]+)\]\([^)]+\)/g, "$1").replace(/`([^`]+)`/g, "$1").trim()
    const id = slugger.slug(text)

    if (level === 2 || level === 3) {
      items.push({ id, level, text })
    }
  }

  return items
}

function nodeText(node: ReactNode): string {
  if (node === null || node === undefined || typeof node === "boolean") return ""
  if (typeof node === "string" || typeof node === "number") return String(node)
  if (Array.isArray(node)) return node.map(nodeText).join("")
  // @ts-expect-error - react-markdown passes ReactElements; we only care about their children.
  return nodeText(node.props?.children)
}

function hastText(node: unknown): string {
  if (!node || typeof node !== "object") return ""
  const candidate = node as { value?: unknown; children?: unknown[] }
  if (typeof candidate.value === "string") return candidate.value
  return candidate.children?.map(hastText).join("") ?? ""
}

function codeLanguage(node: unknown): string {
  if (!node || typeof node !== "object") return "plaintext"
  const children = (node as { children?: Array<{ properties?: { className?: unknown } }> }).children
  const className = children?.[0]?.properties?.className
  const classes = Array.isArray(className) ? className : typeof className === "string" ? className.split(" ") : []
  const languageClass = classes.find((value) => typeof value === "string" && value.startsWith("language-"))
  const requested = typeof languageClass === "string" ? languageClass.slice("language-".length) : "plaintext"
  return LANGUAGE_ALIASES[requested] ?? requested
}

function isExternalHref(href: string) {
  return /^(https?:)?\/\//i.test(href) || href.startsWith("mailto:") || href.startsWith("tel:")
}

function isVideoHref(href: string) {
  return /\.mp4(?:[?#].*)?$/i.test(href)
}

function PreWithCopy({ children, code, language, ...props }: { children?: ReactNode; code: string; language: string }) {
  const [copied, setCopied] = useState(false)
  const codeText = code.replace(/\n$/, "")
  const label = LANGUAGE_LABELS[language] ?? language.toUpperCase()

  return (
    <div className="docs-codeblock">
      <div className="docs-codeblock-language">{label}</div>
      <button
        type="button"
        className="docs-codeblock-copy"
        aria-label={copied ? "Code copied" : "Copy code"}
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
        <span aria-live="polite">{copied ? "Copied" : "Copy"}</span>
      </button>
      <pre {...props}>{children}</pre>
    </div>
  )
}

function CodeTabs({ children, labelsJson }: { children?: ReactNode; labelsJson: string }) {
  const [selected, setSelected] = useState(0)
  const id = useId().replace(/:/g, "")
  const panels = Children.toArray(children).filter(isValidElement)
  const labels = (() => {
    try {
      const value = JSON.parse(labelsJson)
      return Array.isArray(value) && value.every((label) => typeof label === "string") ? value : []
    } catch {
      return []
    }
  })()

  if (labels.length !== panels.length || labels.length < 2) return <>{children}</>

  const active = Math.min(selected, panels.length - 1)
  const selectTab = (index: number) => {
    const next = (index + panels.length) % panels.length
    setSelected(next)
    requestAnimationFrame(() => document.getElementById(`${id}-tab-${next}`)?.focus())
  }

  return (
    <div className="docs-code-tabs">
      <div className="docs-code-tabs-list" role="tablist" aria-label="Installation options">
        {labels.map((label, index) => (
          <button
            key={`${label}-${index}`}
            id={`${id}-tab-${index}`}
            type="button"
            role="tab"
            aria-selected={active === index}
            aria-controls={`${id}-panel-${index}`}
            tabIndex={active === index ? 0 : -1}
            onClick={() => setSelected(index)}
            onKeyDown={(event) => {
              if (event.key === "ArrowRight") selectTab(active + 1)
              else if (event.key === "ArrowLeft") selectTab(active - 1)
              else if (event.key === "Home") selectTab(0)
              else if (event.key === "End") selectTab(panels.length - 1)
              else return
              event.preventDefault()
            }}
          >
            {label}
          </button>
        ))}
      </div>
      <div
        id={`${id}-panel-${active}`}
        className="docs-code-tabs-panel"
        role="tabpanel"
        aria-labelledby={`${id}-tab-${active}`}
      >
        {panels[active]}
      </div>
    </div>
  )
}

export function DocsMarkdown({ markdown, className, renderVideoLinks = false }: DocsMarkdownProps) {
  const slugger = createSlugger()
  const toc = extractToc(markdown)
  const showToc = toc.length >= 5 && markdown.split("\n").length >= 45
  const [copiedEmail, setCopiedEmail] = useState<string | null>(null)
  const [hydrated, setHydrated] = useState(false)
  const copiedEmailTimeout = useRef<number | null>(null)

  useEffect(() => {
    setHydrated(true)

    return () => {
      if (copiedEmailTimeout.current !== null) {
        window.clearTimeout(copiedEmailTimeout.current)
      }
    }
  }, [])

  const heading =
    (Tag: "h1" | "h2" | "h3" | "h4") =>
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

  const content = (
    <Markdown
      remarkPlugins={[remarkGfm, remarkCodeTabs]}
      className={className}
      components={{
        h1: heading("h1"),
        h2: heading("h2"),
        h3: heading("h3"),
        h4: heading("h4"),
        a: ({ href, children, node: _node, ...props }) => {
          const safeHref = href ?? ""

          if (safeHref.startsWith("mailto:")) {
            const email = decodeURIComponent(safeHref.slice("mailto:".length).split("?")[0] ?? "")
            const isCopied = copiedEmail === email
            const label = email ? (hydrated ? email : emailFallback(emailParts(email))) : nodeText(children)

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
                {label}
                {isCopied ? " copied" : ""}
              </button>
            )
          }

          if (renderVideoLinks && isVideoHref(safeHref)) {
            return (
              <video
                className="docs-changelog-video"
                src={safeHref}
                aria-label={nodeText(children) || "Changelog video"}
                autoPlay
                controls
                loop
                muted
                playsInline
                preload="metadata"
              >
                <a href={safeHref}>{children}</a>
              </video>
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
        img: ({ src, alt, node: _node, ...props }) => {
          return <img src={src} alt={alt ?? ""} loading="lazy" {...props} />
        },
        code: ({ children, className, node: _node, ...props }) => {
          const languageClass = className?.match(/language-([\w-]+)/)?.[1]
          if (!languageClass) {
            return (
              <code className={className} {...props}>
                {children}
              </code>
            )
          }

          const requested = LANGUAGE_ALIASES[languageClass] ?? languageClass
          const language = hljs.getLanguage(requested) ? requested : "plaintext"
          const highlighted = hljs.highlight(nodeText(children).replace(/\n$/, ""), {
            language,
            ignoreIllegals: true,
          }).value

          return <code className={`${className} hljs`} dangerouslySetInnerHTML={{ __html: highlighted }} {...props} />
        },
        div: ({ children, node: _node, className, ...props }) => {
          if (className === "docs-code-tabs") {
            const dataProps = props as typeof props & { "data-labels"?: unknown }
            const labelsJson = typeof dataProps["data-labels"] === "string" ? dataProps["data-labels"] : "[]"
            return <CodeTabs labelsJson={labelsJson}>{children}</CodeTabs>
          }
          return (
            <div className={className} {...props}>
              {children}
            </div>
          )
        },
        pre: ({ children, node, ...props }) => {
          const language = codeLanguage(node)
          return (
            <PreWithCopy {...props} code={hastText(node)} language={language}>
              {children}
            </PreWithCopy>
          )
        },
      }}
    >
      {markdown}
    </Markdown>
  )

  if (!showToc) return content

  return (
    <div className="docs-markdown-with-toc">
      {content}
      <nav className="docs-page-toc" aria-label="On this page">
        <div className="docs-page-toc-title">On this page</div>
        {toc.map((item) => (
          <a key={item.id} href={`#${item.id}`} className="docs-page-toc-link" data-level={item.level}>
            {item.text}
          </a>
        ))}
      </nav>
    </div>
  )
}
