import { db } from "@in/server/db"
import { IntegrationsModel } from "@in/server/db/models/integrations"
import { integrations, users } from "@in/server/db/schema"
import { isDev } from "@in/server/env"
import { Log } from "@in/server/utils/log"
import { isNotionObjectNotFoundError, NOTION_SETUP_ERROR_MESSAGES } from "./errors"
import { Client } from "@notionhq/client"
import type {
  CreatePageParameters,
  DataSourceObjectResponse,
  DatabaseObjectResponse,
  PartialDataSourceObjectResponse,
  PartialDatabaseObjectResponse,
  SearchResponse,
} from "@notionhq/client/build/src/api-endpoints"
import { and, eq } from "drizzle-orm"

const logDevTelemetry = (message: string, metadata: Record<string, unknown>) => {
  if (isDev) {
    Log.shared.info(message, metadata)
  }
}

const errorTelemetry = (error: unknown) => ({
  errorName: error instanceof Error ? error.name : "UnknownError",
  errorMessage: error instanceof Error ? error.message : String(error),
})

export type ResolvedNotionParent = {
  databaseId: string
  dataSource: DataSourceObjectResponse
  dataSourceId: string
  wasLegacyDatabaseSelection: boolean
}

type DataSourceRef = {
  id: string
  name: string
}

/**
 * Simplified selectable parent containing id, title, and icon.
 * The id is a data source id in the latest Notion API.
 */
interface SimplifiedDatabase {
  id: string
  title: string
  icon: string | null
}

export async function getNotionClient(spaceId: number): Promise<{ client: Client; databaseId: string | null }> {
  const { accessToken, databaseId } = await IntegrationsModel.getAuthTokenWithSpaceId(spaceId, "notion")

  return {
    client: new Client({
      auth: accessToken,
    }),
    databaseId,
  }
}

export function selectActiveDataSource(
  savedParentId: string,
  databaseId: string,
  dataSources: DataSourceRef[],
): DataSourceRef {
  const directMatch = dataSources.find((dataSource) => dataSource.id === savedParentId)
  if (directMatch) {
    return directMatch
  }

  if (savedParentId === databaseId) {
    if (dataSources.length === 1) {
      return dataSources[0]!
    }

    throw new Error(NOTION_SETUP_ERROR_MESSAGES.legacyDatabaseSelectionAmbiguous)
  }

  throw new Error(NOTION_SETUP_ERROR_MESSAGES.parentNotFound)
}

export async function resolveSelectedNotionParent(
  spaceId: number,
  savedParentId: string,
  notion: Client,
): Promise<ResolvedNotionParent> {
  const directDataSource = await tryGetDataSource(savedParentId, notion)
  if (directDataSource) {
    const databaseId = getDatabaseIdFromDataSource(directDataSource)
    return {
      databaseId,
      dataSource: directDataSource,
      dataSourceId: directDataSource.id,
      wasLegacyDatabaseSelection: false,
    }
  }

  const database = await retrieveDatabaseOrThrowParentNotFound(savedParentId, notion)
  const selectedDataSource = selectActiveDataSource(
    savedParentId,
    database.id,
    database.data_sources.map((dataSource) => ({
      id: dataSource.id,
      name: dataSource.name,
    })),
  )

  logDevTelemetry("Resolved legacy Notion database selection to data source", {
    spaceId,
    savedParentId,
    databaseId: database.id,
    dataSourceId: selectedDataSource.id,
    dataSourceCount: database.data_sources.length,
  })

  const dataSource = assertFullDataSource(await notion.dataSources.retrieve({ data_source_id: selectedDataSource.id }))
  return {
    databaseId: database.id,
    dataSource,
    dataSourceId: dataSource.id,
    wasLegacyDatabaseSelection: true,
  }
}

export async function persistCanonicalNotionParentId(
  spaceId: number,
  savedParentId: string,
  canonicalDataSourceId: string,
): Promise<void> {
  if (!savedParentId || savedParentId === canonicalDataSourceId) {
    return
  }

  await db
    .update(integrations)
    .set({ notionDatabaseId: canonicalDataSourceId })
    .where(and(eq(integrations.spaceId, spaceId), eq(integrations.provider, "notion")))
}

export async function getDatabases(spaceId: number, pageSize = 50, notion: Client): Promise<SimplifiedDatabase[]> {
  const response: SearchResponse = await notion.search({
    filter: { property: "object", value: "data_source" },
    sort: { direction: "descending", timestamp: "last_edited_time" },
    page_size: pageSize,
  })

  const dataSources = (
    await Promise.all(
    response.results
      .filter((result): result is DataSourceObjectResponse | PartialDataSourceObjectResponse => result.object === "data_source")
      .map(async (result) => {
        try {
          if (isFullDataSource(result)) {
            return result
          }

          return assertFullDataSource(await notion.dataSources.retrieve({ data_source_id: result.id }))
        } catch (error) {
          Log.shared.warn("Skipping unavailable Notion data source while loading picker options", {
            spaceId,
            dataSourceId: result.id,
            ...errorTelemetry(error),
          })
          return null
        }
      }),
    )
  ).filter((dataSource): dataSource is DataSourceObjectResponse => dataSource !== null)

  const databaseIds = Array.from(new Set(dataSources.map((dataSource) => getDatabaseIdFromDataSource(dataSource))))
  const databases = (
    await Promise.all(
    databaseIds.map(async (databaseId) => {
      try {
        const database = assertFullDatabase(await notion.databases.retrieve({ database_id: databaseId }))
        return [databaseId, database] as const
      } catch (error) {
        Log.shared.warn("Skipping unavailable Notion database metadata while loading picker options", {
          spaceId,
          databaseId,
          ...errorTelemetry(error),
        })
        return null
      }
    }),
    )
  ).filter((entry): entry is readonly [string, DatabaseObjectResponse] => entry !== null)

  const databaseById = new Map(databases)
  const dataSourceCountByDatabaseId = dataSources.reduce<Record<string, number>>((acc, dataSource) => {
    const databaseId = getDatabaseIdFromDataSource(dataSource)
    acc[databaseId] = (acc[databaseId] ?? 0) + 1
    return acc
  }, {})

  return dataSources.map((dataSource) => {
    const databaseId = getDatabaseIdFromDataSource(dataSource)
    const database = databaseById.get(databaseId)

    return {
      id: dataSource.id,
      title: buildSelectableTitle(dataSource, database, dataSourceCountByDatabaseId[databaseId] ?? 1),
      icon: extractIcon(dataSource.icon) ?? extractIcon(database?.icon ?? null),
    }
  })
}

export async function getActiveDatabaseData(spaceId: number, dataSourceId: string, notion: Client) {
  const dataSource = assertFullDataSource(await notion.dataSources.retrieve({ data_source_id: dataSourceId }))

  const properties =
    "properties" in dataSource && dataSource.properties && typeof dataSource.properties === "object"
      ? dataSource.properties
      : undefined

  logDevTelemetry("Loaded Notion data source metadata", {
    spaceId,
    dataSourceId: dataSource.id,
    propertyCount: properties ? Object.keys(properties).length : 0,
  })

  return dataSource
}

export async function getNotionUsers(spaceId: number, notion: Client) {
  const users = await notion.users.list({
    page_size: 100,
  })

  logDevTelemetry("Loaded Notion users", {
    spaceId,
    usersCount: Array.isArray(users.results) ? users.results.length : 0,
  })

  return users
}

export async function newNotionPage(
  spaceId: number,
  dataSourceId: string,
  properties: CreatePageParameters["properties"],
  client: Client,
  markdown?: string | null,
  icon?: CreatePageParameters["icon"],
) {
  logDevTelemetry("Creating Notion page", {
    spaceId,
    dataSourceId,
    propertyCount: Object.keys(properties ?? {}).length,
    markdownLength: markdown?.length ?? 0,
    hasIcon: Boolean(icon),
  })

  const pageData: CreatePageParameters = {
    parent: { data_source_id: dataSourceId },
    properties,
  }

  if (markdown && markdown.trim().length > 0) {
    pageData.markdown = markdown
  }

  if (icon) {
    pageData.icon = icon
  }

  const page = await client.pages.create(pageData)
  logDevTelemetry("Created Notion page", {
    spaceId,
    dataSourceId,
    hasPageId: Boolean(page.id),
  })
  return page
}

export async function getCurrentNotionUser(spaceId: number, currentUserId: number, notion: Client) {
  const notionUsers = await notion.users.list({
    page_size: 100,
  })

  let [dbUser] = await db.select().from(users).where(eq(users.id, currentUserId))
  if (!dbUser) {
    Log.shared.error("Could not find current user in database", { currentUserId, spaceId })
    throw new Error("Could not find current user in database")
  }

  const notionUser = notionUsers.results.find((u) => u.type === "person" && u.person?.email === dbUser.email)

  if (!notionUser) {
    Log.shared.error("Could not find current user in Notion", { currentUserId, spaceId })
    throw new Error("Could not find current user in Notion")
  }

  return notionUser
}

export async function getSampleDatabasePages(spaceId: number, dataSourceId: string, limit = 10, notion: Client) {
  try {
    const response = await notion.dataSources.query({
      data_source_id: dataSourceId,
      page_size: limit,
      sorts: [
        {
          timestamp: "last_edited_time",
          direction: "descending",
        },
      ],
    })

    const pagesWithMarkdown = await Promise.all(
      response.results.map(async (page) => {
        try {
          const markdown = await notion.pages.retrieveMarkdown({
            page_id: page.id,
          })

          return {
            ...page,
            markdown: markdown.markdown,
          }
        } catch (error) {
          Log.shared.warn("Failed to retrieve page markdown for sample page", {
            pageId: page.id,
            error: error instanceof Error ? error.message : String(error),
          })

          return {
            ...page,
            markdown: "",
          }
        }
      }),
    )

    logDevTelemetry("Retrieved sample pages with markdown", {
      spaceId,
      count: pagesWithMarkdown.length,
      dataSourceId,
    })

    return pagesWithMarkdown
  } catch (error) {
    Log.shared.error("Failed to retrieve sample pages", {
      spaceId,
      ...errorTelemetry(error),
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
  const results = notionUsers?.results
  if (!Array.isArray(results)) return users

  for (const user of results) {
    if (user?.type === "bot") continue

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

function buildSelectableTitle(
  dataSource: DataSourceObjectResponse,
  database: DatabaseObjectResponse | undefined,
  dataSourceCount: number,
): string {
  const dataSourceTitle = plainTextFromRichText(dataSource.title).trim()
  const databaseTitle = plainTextFromRichText(database?.title ?? []).trim()

  if (dataSourceCount > 1 && databaseTitle && dataSourceTitle) {
    return `${databaseTitle} / ${dataSourceTitle}`
  }

  return dataSourceTitle || databaseTitle || "Untitled Notion source"
}

function plainTextFromRichText(items: Array<{ plain_text?: string }> | undefined): string {
  return (items ?? []).map((item) => item.plain_text ?? "").join("")
}

function getDatabaseIdFromDataSource(dataSource: DataSourceObjectResponse): string {
  return dataSource.parent.database_id
}

function extractIcon(icon: { type?: string; emoji?: string } | null | undefined): string | null {
  if (icon?.type === "emoji" && typeof icon.emoji === "string") {
    return icon.emoji
  }

  return null
}

async function tryGetDataSource(dataSourceId: string, notion: Client): Promise<DataSourceObjectResponse | null> {
  try {
    return assertFullDataSource(await notion.dataSources.retrieve({ data_source_id: dataSourceId }))
  } catch (error) {
    if (isNotionObjectNotFoundError(error)) {
      return null
    }

    throw error
  }
}

async function retrieveDatabaseOrThrowParentNotFound(databaseId: string, notion: Client): Promise<DatabaseObjectResponse> {
  try {
    return assertFullDatabase(await notion.databases.retrieve({ database_id: databaseId }))
  } catch (error) {
    if (!isNotionObjectNotFoundError(error)) {
      throw error
    }

    throw new Error(NOTION_SETUP_ERROR_MESSAGES.parentNotFound)
  }
}

function assertFullDatabase(database: DatabaseObjectResponse | PartialDatabaseObjectResponse): DatabaseObjectResponse {
  if ("data_sources" in database && "title" in database) {
    return database
  }

  throw new Error(NOTION_SETUP_ERROR_MESSAGES.parentNotFound)
}

function assertFullDataSource(
  dataSource: DataSourceObjectResponse | PartialDataSourceObjectResponse,
): DataSourceObjectResponse {
  if ("properties" in dataSource && "title" in dataSource && "parent" in dataSource) {
    return dataSource
  }

  throw new Error(NOTION_SETUP_ERROR_MESSAGES.parentNotFound)
}

function isFullDataSource(dataSource: DataSourceObjectResponse | PartialDataSourceObjectResponse): dataSource is DataSourceObjectResponse {
  return "title" in dataSource && "parent" in dataSource && "icon" in dataSource
}
