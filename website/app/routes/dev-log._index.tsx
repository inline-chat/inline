import { json } from "@remix-run/node"
import { useLoaderData } from "@remix-run/react"
import * as stylex from "@stylexjs/stylex"

export async function loader() {
  // This would be replaced with actual file system operations in production
  const posts = [
    {
      title: "Initial Release",
      slug: "initial-release",
      date: "2024-03-20",
    },
    {
      title: "Adding Real-time Chat",
      slug: "adding-real-time-chat",
      date: "2024-03-19",
    },
  ]

  return json({ posts })
}

export default function DevLog() {
  const { posts } = useLoaderData<typeof loader>()

  return (
    <div {...stylex.props(styles.container)}>
      <h1 {...stylex.props(styles.title)}>Dev Log</h1>
      <ul {...stylex.props(styles.list)}>
        {posts.map((post) => (
          <li key={post.slug} {...stylex.props(styles.listItem)}>
            <a href={`/dev-log/${post.slug}`} {...stylex.props(styles.link)}>
              <h2 {...stylex.props(styles.postTitle)}>{post.title}</h2>
              <time {...stylex.props(styles.date)}>{post.date}</time>
            </a>
          </li>
        ))}
      </ul>
    </div>
  )
}

const styles = stylex.create({
  container: {
    maxWidth: "650px",
    margin: "0 auto",
    padding: "40px 20px",
  },
  title: {
    fontSize: "32px",
    fontWeight: "700",
    marginBottom: "40px",
    color: {
      default: "#000",
      "@media (prefers-color-scheme: dark)": "#fff",
    },
  },
  list: {
    listStyle: "none",
    padding: 0,
    margin: 0,
  },
  listItem: {
    borderBottom: {
      default: "1px solid #eee",
      "@media (prefers-color-scheme: dark)": "1px solid rgba(255,255,255,0.1)",
    },
  },
  link: {
    display: "block",
    padding: "20px 0",
    textDecoration: "none",
  },
  postTitle: {
    fontSize: "24px",
    fontWeight: "600",
    marginBottom: "8px",
    color: {
      default: "#000",
      "@media (prefers-color-scheme: dark)": "#fff",
    },
  },
  date: {
    fontSize: "14px",
    color: {
      default: "#666",
      "@media (prefers-color-scheme: dark)": "rgba(255,255,255,0.6)",
    },
  },
})
