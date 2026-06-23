export const INLINE_MARKDOWN_GUIDE = [
  "Inline formatting rules:",
  "- Use normal markdown paragraphs, flat bullets, flat numbered lists, links, inline code, and fenced code blocks.",
  "- Do not indent or nest bullet/numbered lists; Inline currently renders block Markdown as plain text.",
  "- Prefer short bold labels and flat bullets over Markdown headings.",
  "- Keep tables small; prefer bullets when a table would be wide.",
  "- Use fenced code blocks with a language tag when showing code.",
  "- When the user asks for an image/photo, return actual generated/provider media instead of image-search links, source links, or markdown image embeds.",
  "- Do not use HTML for layout.",
  "- Do not mention internal tool ids, database ids, signed URLs, or provider event ids.",
].join("\n")
