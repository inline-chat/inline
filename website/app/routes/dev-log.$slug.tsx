import { json } from "@remix-run/node"
import { useLoaderData } from "@remix-run/react"
import * as stylex from "@stylexjs/stylex"
import type { LoaderFunctionArgs } from "@remix-run/node"

export async function loader({ params }: LoaderFunctionArgs) {
  const { slug } = params

  // This would be replaced with actual markdown file reading in production
  const post = {
    title: "Initial Release",
    content: "Today we're excited to announce...",
    date: "2024-03-20",
  }

  if (!post) {
    throw new Response("Not Found", { status: 404 })
  }

  return json({ post })
}

export default function DevLogPost() {
  const { post } = useLoaderData<typeof loader>()

  return (
    <article {...stylex.props(styles.container)}>
      <h1 {...stylex.props(styles.title)}>{post.title}</h1>
      <time {...stylex.props(styles.date)}>{post.date}</time>
      <div {...stylex.props(styles.content)}>{post.content}</div>
    </article>
  )
}

const styles = stylex.create({
  container: {
    maxWidth: "800px",
    margin: "0 auto",
    padding: "40px 20px",
  },
  title: {
    fontSize: "40px",
    fontWeight: "700",
    marginBottom: "16px",
    color: {
      default: "#000",
      "@media (prefers-color-scheme: dark)": "#fff",
    },
  },
  date: {
    fontSize: "16px",
    color: {
      default: "#666",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.6)",
    },
    display: "block",
    marginBottom: "40px",
  },
  content: {
    fontSize: "18px",
    lineHeight: "1.6",
    color: {
      default: "#333",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.9)",
    },
  },
})
