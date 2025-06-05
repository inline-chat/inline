import { db } from "@in/server/db"
import { IntegrationsModel } from "@in/server/db/models/integrations"
import { integrations, users } from "@in/server/db/schema"
import { Log } from "@in/server/utils/log"
import { Client } from "@notionhq/client"
import type {
  DatabaseObjectResponse,
  SearchResponse,
  CreatePageParameters,
} from "@notionhq/client/build/src/api-endpoints"
import { and, eq } from "drizzle-orm"

export async function getNotionClient(spaceId: number): Promise<{ client: Client; databaseId: string | null }> {
  const { accessToken, databaseId } = await IntegrationsModel.getAuthTokenWithSpaceId(spaceId, "notion")

  return {
    client: new Client({
      auth: accessToken,
    }),
    databaseId,
  }
}

/**
 * Simplified database object containing id, title, and icon
 */
interface SimplifiedDatabase {
  id: string
  title: string
  icon: string | null
}

/**
 * Helper function to extract simplified database information
 * @param {DatabaseObjectResponse} db - The database object response from Notion API
 * @returns {SimplifiedDatabase} A simplified database object containing id, title, and icon
 */
function extract(db: DatabaseObjectResponse): SimplifiedDatabase {
  const title = db.title.map((t) => t.plain_text).join("")
  const icon = db.icon?.type === "emoji" ? db.icon.emoji : null
  return { id: db.id, title, icon }
}

/**
 * Get all databases from Notion for a given space
 * @param {number} spaceId - The ID of the space who connected to the integration
 * @param {number} [pageSize=50] - The number of databases to return
 * @returns {Promise<SimplifiedDatabase[]>} A promise that resolves to an array of simplified database objects
 */
export async function getDatabases(spaceId: number, pageSize = 50, notion: Client): Promise<SimplifiedDatabase[]> {
  const response: SearchResponse = await notion.search({
    filter: { property: "object", value: "database" },
    sort: { direction: "descending", timestamp: "last_edited_time" },
    page_size: pageSize,
  })

  return response.results.filter((r) => r.object === "database").map((r) => extract(r as DatabaseObjectResponse))
}

// get active database data
export async function getActiveDatabaseData(spaceId: number, databaseId: string, notion: Client) {
  const database = await notion.databases.retrieve({ database_id: databaseId })
  Log.shared.info("🔍 Database", { database })
  console.log("🔍 Database", database)

  return database
}

// get all notion users
export async function getNotionUsers(spaceId: number, notion: Client) {
  const users = await notion.users.list({
    page_size: 100,
  })

  console.log("🔍 Users", users)
  Log.shared.info("🔍 Users", { users })

  return users
}

export async function newNotionPage(
  spaceId: number,
  databaseId: string,
  properties: CreatePageParameters["properties"],
  client: Client,
  children?: CreatePageParameters["children"],
) {
  const pageData: CreatePageParameters = {
    parent: { database_id: databaseId },
    properties,
  }

  if (children) {
    pageData.children = children
  }

  const page = await client.pages.create(pageData)

  console.log("🔍 Page", page)
  return page
}

export async function getCurrentNotionUser(spaceId: number, currentUserId: number, notion: Client) {
  const notionUsers = await notion.users.list({
    page_size: 100,
  })

  let [dbUser] = await db.select().from(users).where(eq(users.id, currentUserId))
  if (!dbUser) {
    console.error("Could not find current user in database", { currentUserId })
    throw new Error("Could not find current user in database")
  }

  const notionUser = notionUsers.results.find((u) => u.type === "person" && u.person?.email === dbUser.email)

  if (!notionUser) {
    console.error("Could not find current user in Notion", { currentUserId })
    throw new Error("Could not find current user in Notion")
  }

  return notionUser
}

/**
 * Get a sample of pages from a Notion database to understand the tone and format
 * @param {number} spaceId - The ID of the space who connected to the integration
 * @param {number} [limit=10] - Maximum number of pages to retrieve
 * @returns {Promise<any[]>} Array of sample pages with their properties and content
 */
export async function getSampleDatabasePages(spaceId: number, databaseId: string, limit = 10, notion: Client) {
  try {
    const response = await notion.databases.query({
      database_id: databaseId,
      page_size: limit,
      sorts: [
        {
          timestamp: "last_edited_time",
          direction: "descending",
        },
      ],
    })

    // Fetch page content (blocks) for each page
    const pagesWithContent = await Promise.all(
      response.results.map(async (page) => {
        try {
          // Get the page blocks (content)
          const blocks = await notion.blocks.children.list({
            block_id: page.id,
            page_size: 50, // Limit blocks to avoid too much content
          })

          return {
            ...page,
            content: blocks.results,
          }
        } catch (error) {
          Log.shared.warn("Failed to retrieve blocks for page", {
            pageId: page.id,
            error: error instanceof Error ? error.message : String(error),
          })
          // Return page without content if blocks fetch fails
          return {
            ...page,
            content: [],
          }
        }
      }),
    )

    Log.shared.info("Retrieved sample pages with content", {
      count: pagesWithContent.length,
      databaseId,
    })

    return pagesWithContent
  } catch (error) {
    Log.shared.error("Failed to retrieve sample pages", {
      spaceId,
      error: error instanceof Error ? error.message : String(error),
    })
    return []
  }
}

export interface NotionUser {
  id: string
  name: string
  email: string
}

export function formatNotionUsers(notionUsers: any): NotionUser[] {
  const users: NotionUser[] = []

  for (const user of notionUsers.results) {
    let email = undefined
    if (user.type === "person" && user.person?.email) {
      email = user.person.email
    }

    users.push({
      id: user.id,
      name: user.name,
      email: email,
    })
  }

  return users
}
