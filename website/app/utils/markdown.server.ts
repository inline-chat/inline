import path from "path"
import fs from "fs/promises"
import matter from "gray-matter"
import { marked } from "marked"

const POSTS_PATH = path.join(process.cwd(), "content", "dev-log")

export async function getAllPosts() {
  try {
    const files = await fs.readdir(POSTS_PATH)
    const posts = await Promise.all(
      files
        .filter((file) => file.endsWith(".md"))
        .map(async (file) => {
          const content = await fs.readFile(path.join(POSTS_PATH, file), "utf-8")
          const { data, content: markdown } = matter(content)
          return {
            slug: file.replace(/\.md$/, ""),
            title: data.title,
            date: data.date,
            content: marked(markdown),
          }
        }),
    )

    return posts.sort((a, b) => new Date(b.date).getTime() - new Date(a.date).getTime())
  } catch (error) {
    console.error("Error reading posts:", error)
    return []
  }
}

export async function getPost(slug: string) {
  try {
    const content = await fs.readFile(path.join(POSTS_PATH, `${slug}.md`), "utf-8")
    const { data, content: markdown } = matter(content)
    return {
      title: data.title,
      date: data.date,
      content: marked(markdown),
    }
  } catch {
    return null
  }
}
