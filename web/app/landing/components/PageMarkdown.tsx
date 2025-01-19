import Markdown from "react-markdown"
import remarkGfm from "remark-gfm"

interface PageMarkdownProps {
  children: string
  className?: string
}

export function PageMarkdown({ children, className }: PageMarkdownProps) {
  return (
    <Markdown remarkPlugins={[remarkGfm]} className={className}>
      {children}
    </Markdown>
  )
}
