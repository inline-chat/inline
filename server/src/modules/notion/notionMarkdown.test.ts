import { describe, expect, test } from "bun:test"
import { APIErrorCode, APIResponseError } from "@notionhq/client"
import { getDatabases, resolveSelectedNotionParent, selectActiveDataSource } from "./notion"

describe("selectActiveDataSource", () => {
  test("accepts a saved data source id directly", () => {
    const result = selectActiveDataSource(
      "ds_2",
      "db_1",
      [
        { id: "ds_1", name: "Inbox" },
        { id: "ds_2", name: "Tasks" },
      ],
    )

    expect(result.id).toBe("ds_2")
    expect(result.name).toBe("Tasks")
  })

  test("maps a legacy database id to the only available data source", () => {
    const result = selectActiveDataSource("db_1", "db_1", [{ id: "ds_1", name: "Tasks" }])

    expect(result.id).toBe("ds_1")
  })

  test("rejects legacy database ids when multiple data sources exist", () => {
    expect(() =>
      selectActiveDataSource(
        "db_1",
        "db_1",
        [
          { id: "ds_1", name: "Tasks" },
          { id: "ds_2", name: "Bugs" },
        ],
      ),
    ).toThrow("Multiple data sources found")
  })
})

describe("getDatabases", () => {
  test("returns human-readable source titles for multi-source databases", async () => {
    const notion = {
      search: async () => ({
        results: [
          {
            object: "data_source",
            id: "ds_1",
            title: [{ plain_text: "Inbox" }],
            parent: { database_id: "db_1" },
            icon: { type: "emoji", emoji: "📥" },
            properties: {},
          },
          {
            object: "data_source",
            id: "ds_2",
            title: [{ plain_text: "Bugs" }],
            parent: { database_id: "db_1" },
            icon: { type: "emoji", emoji: "🐞" },
            properties: {},
          },
        ],
      }),
      dataSources: {
        retrieve: async () => {
          throw new Error("should not retrieve full data sources")
        },
      },
      databases: {
        retrieve: async () => ({
          id: "db_1",
          title: [{ plain_text: "Engineering" }],
          icon: { type: "emoji", emoji: "🛠️" },
          properties: {},
          data_sources: [
            { id: "ds_1", name: "Inbox" },
            { id: "ds_2", name: "Bugs" },
          ],
        }),
      },
    } as any

    const result = await getDatabases(54, 50, notion)

    expect(result).toEqual([
      { id: "ds_1", title: "Engineering / Inbox", icon: "📥" },
      { id: "ds_2", title: "Engineering / Bugs", icon: "🐞" },
    ])
  })

  test("skips stale search results and still returns valid sources", async () => {
    const notion = {
      search: async () => ({
        results: [
          {
            object: "data_source",
            id: "ds_stale",
          },
          {
            object: "data_source",
            id: "ds_live",
            title: [{ plain_text: "Tasks" }],
            parent: { database_id: "db_1" },
            icon: { type: "emoji", emoji: "✅" },
            properties: {},
          },
        ],
      }),
      dataSources: {
        retrieve: async ({ data_source_id }: { data_source_id: string }) => {
          if (data_source_id === "ds_stale") {
            throw new Error("source missing")
          }

          throw new Error(`unexpected data source lookup: ${data_source_id}`)
        },
      },
      databases: {
        retrieve: async ({ database_id }: { database_id: string }) => {
          if (database_id !== "db_1") {
            throw new Error(`unexpected database lookup: ${database_id}`)
          }

          return {
            id: "db_1",
            title: [{ plain_text: "Engineering" }],
            icon: { type: "emoji", emoji: "🛠️" },
            properties: {},
            data_sources: [{ id: "ds_live", name: "Tasks" }],
          }
        },
      },
    } as any

    const result = await getDatabases(54, 50, notion)

    expect(result).toEqual([{ id: "ds_live", title: "Tasks", icon: "✅" }])
  })
})

describe("resolveSelectedNotionParent", () => {
  test("does not require database retrieval when saved parent is already a data source id", async () => {
    const notion = {
      dataSources: {
        retrieve: async ({ data_source_id }: { data_source_id: string }) => {
          if (data_source_id !== "ds_live") {
            throw new Error(`unexpected data source lookup: ${data_source_id}`)
          }

          return {
            id: "ds_live",
            title: [{ plain_text: "Tasks" }],
            parent: { database_id: "db_live" },
            icon: { type: "emoji", emoji: "✅" },
            properties: {},
          }
        },
      },
      databases: {
        retrieve: async () => {
          throw new Error("database lookup should not happen for direct data source ids")
        },
      },
    } as any

    const resolved = await resolveSelectedNotionParent(54, "ds_live", notion)

    expect(resolved.dataSourceId).toBe("ds_live")
    expect(resolved.databaseId).toBe("db_live")
    expect(resolved.wasLegacyDatabaseSelection).toBe(false)
  })

  test("accepts full database responses from the new API shape when resolving legacy database ids", async () => {
    const notion = {
      dataSources: {
        retrieve: async ({ data_source_id }: { data_source_id: string }) => {
          if (data_source_id === "db_legacy") {
            throw new APIResponseError({
              code: APIErrorCode.ObjectNotFound,
              status: 404,
              message: "Could not find data source with ID",
              headers: {},
              rawBodyText: "",
              additional_data: undefined,
              request_id: undefined,
            })
          }
          if (data_source_id !== "ds_live") {
            throw new Error(`unexpected data source lookup: ${data_source_id}`)
          }

          return {
            id: "ds_live",
            title: [{ plain_text: "Tasks" }],
            parent: { database_id: "db_live" },
            icon: { type: "emoji", emoji: "✅" },
            properties: {},
          }
        },
      },
      databases: {
        retrieve: async ({ database_id }: { database_id: string }) => {
          if (database_id !== "db_legacy") {
            throw new Error(`unexpected database lookup: ${database_id}`)
          }

          return {
            object: "database",
            id: "db_legacy",
            title: [{ plain_text: "Engineering" }],
            description: [],
            parent: { type: "page_id", page_id: "parent" },
            is_inline: false,
            in_trash: false,
            is_locked: false,
            created_time: "2026-01-01T00:00:00.000Z",
            last_edited_time: "2026-01-01T00:00:00.000Z",
            data_sources: [{ id: "ds_live", name: "Tasks" }],
            icon: null,
            cover: null,
            url: "https://notion.so/db_legacy",
            public_url: null,
          }
        },
      },
    } as any

    const resolved = await resolveSelectedNotionParent(54, "db_legacy", notion)

    expect(resolved.dataSourceId).toBe("ds_live")
    expect(resolved.databaseId).toBe("db_legacy")
    expect(resolved.wasLegacyDatabaseSelection).toBe(true)
  })
})
